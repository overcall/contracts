// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {GameState as S} from "./GameState.sol";
import {ChannelGame} from "./ChannelGame.sol";
import {AssetRegistry} from "../assets/AssetRegistry.sol";
import {Vault} from "../vault/Vault.sol";

/**
 * @title GameEntry
 * @notice Channel creation and request acceptance (ADR-0003/0004/0011/0013/0018/0021) — an external
 *         library, delegatecalled by ChannelGame, kept out of the contract for size. The contract
 *         keeps what needs its own identity: the EIP-712 quote check and the ERC-721 mint.
 */
library GameEntry {
  uint256 internal constant WAD = 1e18;
  uint16 internal constant BPS = 10_000;

  /// @dev Sanity caps on geometry: guarantee that _boundsAt never overflows
  ///      for any created channel — a panic would take down the whole batch (ADR-0007). The center
  ///      always comes from a verified report now (drawn channels are refused).
  uint128 private constant MAX_HEIGHT_WAD = 1e20; // 100× the center
  int256 private constant MAX_SLOPE_WAD_PER_SEC = 1e18; // 100% of the center per second

  event ChannelCreated(
    uint256 indexed channelId, bytes32 indexed feedId, address indexed owner, uint64 startTs, uint64 endTs,
    int192 centerPrice, uint128 heightWad, int128 slopeWadPerSec, bool priceOnOpen, uint16 royaltyBps
  );
  event PositionRequested(
    uint256 indexed positionId, uint256 indexed channelId, address indexed owner, uint8 side, uint128 deposit,
    uint128 stake, uint64 requestTs, uint256 sigmaWad, uint32 modelVersion
  );
  event PositionCurrency(uint256 indexed positionId, uint8 indexed currencyId);

  error ChannelClosedForEntries(uint256 channelId);
  error AssetNotAccepting(bytes32 feedId);
  error BadGeometry(string what);
  error BadDeposit(uint128 deposit);
  error MultiplierFloorTooHigh(uint128 floorWad, uint128 ceilingWad);
  error UnknownCurrency(uint8 currencyId);
  error CurrencyNotAccepted(bytes32 feedId, uint8 currencyId);
  error BadOwner(address owner);

  // ----------------- Channels (ADR-0018) -----------------

  /// @notice Writes the channel record and charges the creation fee in `currencyId`; the caller mints.
  function createChannel(ChannelGame.NewChannel calldata p, address payer, uint8 currencyId)
    external
    returns (uint256 channelId)
  {
    S.GameStorage storage $ = S.s();
    AssetRegistry.AssetConfig memory cfg = $.assets.getConfig(p.feedId);
    _validateNewChannel($, p, cfg);
    uint128 fee = _terms($, p.feedId, currencyId).channelCreationFee;
    if (fee != 0) {
      Vault vault = S.vaultOf($, currencyId);
      vault.collectDeposit(payer, fee);
      vault.settle(fee, 0, address(0), 0, fee, 0, 0, 0);
    }
    channelId = $.nextChannelId++;
    uint64 startTs = p.priceOnOpen ? 0 : p.startTs;
    int192 centerPrice = p.priceOnOpen ? int192(0) : p.centerPrice;
    // struct assignment: guarantees a single write per slot
    $.channels[channelId] = S.Channel({
      feedId: p.feedId,
      creator: p.channelOwner,
      startTs: startTs,
      endTs: p.endTs,
      centerPrice: centerPrice,
      heightWad: p.heightWad,
      slopeWadPerSec: p.slopeWadPerSec,
      priceOnOpen: p.priceOnOpen,
      anchored: false,
      breachedAt: 0,
      royaltyBps: cfg.royaltyBps,
      royaltyClaimed: false,
      openPositions: 0,
      totalPositions: 0,
      claimedOthers: 0,
      survivedAt: 0
    });
    emit ChannelCreated(
      channelId, p.feedId, p.channelOwner, startTs, p.endTs, centerPrice, p.heightWad, p.slopeWadPerSec,
      p.priceOnOpen, cfg.royaltyBps
    );
  }

  function _validateNewChannel(S.GameStorage storage $, ChannelGame.NewChannel calldata p, AssetRegistry.AssetConfig memory cfg)
    private
    view
  {
    if (!$.assets.acceptsExpiry(p.feedId, p.endTs)) revert AssetNotAccepting(p.feedId);
    // a channel without a position used to take any endTs (up to 2^64): its ChannelCreated froze
    // the backend mirror (audit 2026-10-19, N-1 / L-30). Entries check the duration again.
    if (p.endTs <= block.timestamp || p.endTs - block.timestamp > cfg.maxDurationSec) revert BadGeometry("duration");
    if (p.heightWad == 0 || p.heightWad > MAX_HEIGHT_WAD) revert BadGeometry("height");
    int256 slope = int256(p.slopeWadPerSec);
    if (slope > MAX_SLOPE_WAD_PER_SEC || slope < -MAX_SLOPE_WAD_PER_SEC) revert BadGeometry("slope");
    // drawn channels (a fixed center and start) are not offered: the operator never priced them and a
    // request on one could be bound after its outcome was known (audit 2026-10-19, H-03 / M-10)
    if (!p.priceOnOpen) revert BadGeometry("drawn");
  }

  /// @dev The asset's terms in a currency; the currency must be live and accepting (ADR-0021/0022).
  function _terms(S.GameStorage storage $, bytes32 feedId, uint8 currencyId)
    private
    view
    returns (AssetRegistry.CurrencyTerms memory)
  {
    if (currencyId >= $.currencyCount) revert UnknownCurrency(currencyId);
    if ($.currencies[currencyId].drawdownBps == 0 || !$.assets.acceptsCurrency(feedId, currencyId)) {
      revert CurrencyNotAccepted(feedId, currencyId);
    }
    return $.assets.getCurrencyTerms(feedId, currencyId);
  }

  // ----------------- Request (ADR-0003/0011/0016) -----------------

  /// @notice Accepts a request on an existing, quote-verified channel: deposit into the currency's
  ///         vault, reserve at the currency's cap, snapshots into the position.
  function open(ChannelGame.OpenRequest calldata r, uint256 channelId, uint8 currencyId)
    external
    returns (uint256 positionId)
  {
    S.GameStorage storage $ = S.s();
    S.Channel storage c = $.channels[channelId];
    if (c.breachedAt != 0) revert ChannelClosedForEntries(channelId);

    AssetRegistry.AssetConfig memory cfg = $.assets.getConfig(c.feedId);
    AssetRegistry.CurrencyTerms memory terms = _terms($, c.feedId, currencyId);
    if (!$.assets.acceptsExpiry(c.feedId, c.endTs)) revert AssetNotAccepting(c.feedId);
    _validateEntry(c, cfg, r.quote.sigmaWad);
    if (r.deposit < terms.minDeposit || r.deposit > terms.maxDeposit) revert BadDeposit(r.deposit);

    // opening fee: max(percentage, fixed) — ADR-0013
    uint256 openFeePct = (uint256(r.deposit) * cfg.openFeeBps) / BPS;
    uint128 openFee = uint128(openFeePct > terms.openFeeFixed ? openFeePct : terms.openFeeFixed);
    if (openFee >= r.deposit) revert BadDeposit(r.deposit);
    uint128 stake = r.deposit - openFee;

    // deposit taken from the caller (ADR-0011); reserve at the currency's cap (ADR-0004/0021)
    Vault vault = S.vaultOf($, currencyId);
    vault.collectDeposit(msg.sender, r.deposit);
    uint256 maxRewardFull = (uint256(stake) * (terms.ceilingWad - WAD)) / WAD;
    if (maxRewardFull > type(uint128).max) revert BadDeposit(r.deposit);
    uint128 maxReward = uint128(maxRewardFull);
    vault.reserve(maxReward);

    positionId = $.nextPositionId++;
    address positionOwner = r.owner == address(0) ? msg.sender : r.owner;
    // payouts to these would be stranded for good: the vault itself, its token, the game (audit 2026-10-09)
    if (positionOwner == address(vault) || positionOwner == $.currencyTokens[currencyId] || positionOwner == address(this)) {
      revert BadOwner(positionOwner);
    }
    // player's floor (slippage protection and a bound against an unfair P): snapshot = max(config, floor)
    uint128 floorWad = r.minMultiplierWad > cfg.minMultiplierWad ? r.minMultiplierWad : cfg.minMultiplierWad;
    if (floorWad > terms.ceilingWad) revert MultiplierFloorTooHigh(floorWad, terms.ceilingWad);
    // struct assignment: a single write per slot (packing — GameState.Position)
    $.positions[positionId] = S.Position({
      status: S.PositionStatus.Requested,
      side: r.side,
      owner: positionOwner,
      requestTs: uint48(block.timestamp),
      channelId: channelId,
      entryPrice: 0,
      closeRequestTs: 0,
      deposit: r.deposit,
      stake: stake,
      openFeeFixed: terms.openFeeFixed,
      reserved: maxReward,
      multiplierWad: 0, // the multiplier appears at binding; δ arrives in the batch entry (ADR-0019)
      ceilingWad: terms.ceilingWad,
      minMultiplierWad: floorWad,
      sigmaWad: uint64(r.quote.sigmaWad),
      pWad: 0,
      profitFeeBps: cfg.profitFeeBps,
      earlyClosePenaltyBps: cfg.earlyClosePenaltyBps,
      currencyId: currencyId,
      royaltyEligible: false
    });

    c.openPositions += 1;
    c.totalPositions += 1;

    emit PositionRequested(
      positionId, channelId, positionOwner, uint8(r.side), r.deposit, stake, uint64(block.timestamp),
      r.quote.sigmaWad, r.quote.modelVersion
    );
    emit PositionCurrency(positionId, currencyId);
  }

  /// @dev Request timing and geometry in units of the quote's σ — before the deposit is debited.
  function _validateEntry(S.Channel storage c, AssetRegistry.AssetConfig memory cfg, uint256 sigmaWad)
    private
    view
  {
    // a drawn channel hasn't started yet — bounds are undefined (_boundsAt: t − startTs)
    if (!c.priceOnOpen && block.timestamp < c.startTs) revert BadGeometry("not-started");
    // remaining time must stay within the configuration's bounds — for every request (ARCHITECTURE)
    if (block.timestamp >= c.endTs) revert BadGeometry("duration");
    uint64 remaining = c.endTs - uint64(block.timestamp);
    if (remaining < cfg.minDurationSec || remaining > cfg.maxDurationSec) revert BadGeometry("duration");
    uint256 heightSigma = (uint256(c.heightWad) * WAD) / sigmaWad;
    if (heightSigma < cfg.minHeightSigmaWad || heightSigma > cfg.maxHeightSigmaWad) revert BadGeometry("height");
    int256 slopeSigned = int256(c.slopeWadPerSec);
    uint256 slopeAbs = uint256(slopeSigned < 0 ? -slopeSigned : slopeSigned) * 60;
    if ((slopeAbs * WAD) / sigmaWad > cfg.maxSlopeSigmaPerMinWad) revert BadGeometry("slope");
  }
}
