// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {GameState as S} from "./GameState.sol";
import {Vault} from "../vault/Vault.sol";
import {AssetRegistry} from "../assets/AssetRegistry.sol";
import {DataStreamsReports} from "../libs/DataStreamsReports.sol";

/**
 * @title GameLogic
 * @notice The operator batch engine (binding, breaches, settlements) — an external library
 *         to stay under the contract size limit. Called via delegatecall: storage and the
 *         event-emitting address belong to the game proxy. Rules — ADR-0003/0007/0012/0013/0015/0019.
 *
 *         v3 (ADR-0021/0022): a position's money goes to the vault of its currency; a lost
 *         working amount goes into capital; every currency has a drawdown allowance (a token
 *         bucket, a share of the vault's capital) that rewards drain and losses and time refill;
 *         a reward the allowance cannot cover — or any reward while the game is paused — is
 *         deferred: the working amount is paid, the reward stays reserved until the admin
 *         approves or rejects it.
 */
library GameLogic {
  uint256 internal constant WAD = 1e18;
  uint16 internal constant BPS = 10_000;
  uint256 internal constant P_EPSILON = 1e13; // ε model-v1 in WAD
  uint256 internal constant MAX_DELTA_WAD = 0.5e18; // δ < 50%, otherwise (1−δ) devalues the price
  /// @dev Report lag when the admin has not set one (audit 2026-10-19, M-06).
  uint256 internal constant DEFAULT_MAX_REPORT_LAG = 30;
  /// @dev A close that no report could price is void this long after expiry; the position then settles
  ///      by the channel's outcome instead of waiting for refundStale (audit 2026-10-19, M-05).
  uint256 internal constant CLOSE_FALLBACK_DELAY = 1 hours;

  event PositionBound(uint256 indexed positionId, int192 entryPrice, uint64 pWad, uint64 deltaWad, uint128 multiplierWad, uint128 reserved);
  event ChannelAnchored(uint256 indexed channelId, int192 centerPrice, uint64 startTs);
  event ChannelBreached(uint256 indexed channelId, uint64 breachedAt, int192 price);
  event ChannelSurvived(uint256 indexed channelId, uint64 survivedAt);
  event PositionSettled(uint256 indexed positionId, uint8 outcome, uint256 payout);
  event PositionCancelled(uint256 indexed positionId);
  event PositionRefunded(uint256 indexed positionId, uint256 refund);
  // v3 — ADR-0022. `PausedSet` mirrors the game's own event so a trip reads like a hand pause plus a reason.
  event RewardDeferred(
    uint256 indexed positionId, uint8 indexed currencyId, uint256 reward, bool royaltyEligible, uint64 pNowWad,
    int192 closePrice, uint32 closeObservedAt
  );
  event AllowanceExhausted(uint8 indexed currencyId, uint256 indexed positionId, uint256 reward, uint256 remainder);
  event PausedSet(bool paused);
  event RewardApproved(uint256 indexed positionId, uint256 toPlayer, uint256 toRevenue, uint256 toRoyalty);
  event RewardRejected(uint256 indexed positionId, bytes reason);
  event AllowanceRefilled(uint8 indexed currencyId, uint256 capacity);

  error NotPositionOwner(uint256 positionId);
  error RefundUnavailable(uint256 positionId, S.PositionStatus status);
  error SettlementWindowOpen(uint256 positionId, uint256 availableAt);
  error NotAdmin();
  error UnknownCurrency(uint8 currencyId);

  // ----------------- Entry points (external, delegatecall) -----------------

  function applyEntry(S.BatchEntry calldata e, DataStreamsReports.Decoded[] memory reports)
    external
    returns (bytes memory reason)
  {
    S.GameStorage storage $ = S.s();
    if (e.kind == S.EntryKind.MarkSurvived) return _markSurvived($, e.id);
    if (e.kind != S.EntryKind.Settle && e.reportIndex >= reports.length) return "report";
    if (e.kind == S.EntryKind.Breach) return _markBreach($, e.id, reports[e.reportIndex]);
    if (e.kind == S.EntryKind.Bind) return _bind($, e.id, reports[e.reportIndex], e.pWad, e.deltaWad);
    if (e.kind == S.EntryKind.Settle) return _settle($, e.id);
    if (e.kind == S.EntryKind.SettleClose) return _settleClose($, e.id, reports[e.reportIndex], e.pWad);
    return "kind";
  }

  /// @notice Refund by the position owner once the settlement window has elapsed (ADR-0002).
  function refundStale(uint256 positionId) external {
    S.GameStorage storage $ = S.s();
    S.Position storage p = $.positions[positionId];
    if (msg.sender != p.owner) revert NotPositionOwner(positionId);
    if (
      p.status != S.PositionStatus.Requested && p.status != S.PositionStatus.Active
        && p.status != S.PositionStatus.CloseRequested
    ) revert RefundUnavailable(positionId, p.status);
    S.Channel storage c = $.channels[p.channelId];
    uint256 availableAt = uint256(c.endTs) + $.settlementWindow;
    if (block.timestamp <= availableAt) revert SettlementWindowOpen(positionId, availableAt);
    _refund($, positionId, S.PositionStatus.Refunded);
    emit PositionRefunded(positionId, uint256(p.deposit) - p.openFeeFixed);
  }

  /**
   * @notice Admin decision on deferred rewards (ADR-0022). Approval re-derives the outcome from the
   *         channel first — an earlier touch proven after the deferral can make a "breaches" win dead at
   *         entry, and the reward is then rejected instead ("survives" wins are final once attested).
   *         Approved rewards do not drain the allowance.
   */
  function approveRewards(uint256[] calldata positionIds) external {
    S.GameStorage storage $ = S.s();
    if (!$.access.isAdmin(msg.sender)) revert NotAdmin();
    for (uint256 i = 0; i < positionIds.length; i++) {
      uint256 id = positionIds[i];
      S.Position storage p = $.positions[id];
      if (p.status != S.PositionStatus.RewardDeferred) continue;
      S.Channel storage c = $.channels[p.channelId];
      if (!_stillWon(p, c)) {
        _resolveDeferred($, id, S.PositionStatus.RewardRejected);
        emit RewardRejected(id, "outcome");
        continue;
      }
      uint256 reward = p.reserved;
      uint256 fee = (reward * p.profitFeeBps) / BPS;
      uint256 toRoyalty = p.royaltyEligible ? (fee * c.royaltyBps) / BPS : 0;
      uint256 toPlayer = reward - fee;
      uint256 toRevenue = fee - toRoyalty;
      Vault vault = S.vaultOf($, p.currencyId);
      _resolveDeferred($, id, S.PositionStatus.Settled);
      vault.settle(0, reward, p.owner, toPlayer, toRevenue, p.channelId, toRoyalty, 0);
      emit RewardApproved(id, toPlayer, toRevenue, toRoyalty);
    }
  }

  /// @notice Admin refusal of deferred rewards: the reserve returns to free capital, the player keeps
  ///         the working amount already paid. Final.
  function rejectRewards(uint256[] calldata positionIds) external {
    S.GameStorage storage $ = S.s();
    if (!$.access.isAdmin(msg.sender)) revert NotAdmin();
    for (uint256 i = 0; i < positionIds.length; i++) {
      uint256 id = positionIds[i];
      if ($.positions[id].status != S.PositionStatus.RewardDeferred) continue;
      _resolveDeferred($, id, S.PositionStatus.RewardRejected);
      emit RewardRejected(id, "admin");
    }
  }

  /// @notice Explicit refill of a currency's drawdown allowance (ADR-0022): never implicit, always evented.
  function refillAllowance(uint8 currencyId) external {
    S.GameStorage storage $ = S.s();
    if (!$.access.isAdmin(msg.sender)) revert NotAdmin();
    if (currencyId >= $.currencyCount) revert UnknownCurrency(currencyId);
    S.CurrencyState storage cs = $.currencies[currencyId];
    uint256 capacity = _capacity($, currencyId, cs);
    cs.bucketRemainder = uint128(capacity);
    cs.bucketUpdatedAt = uint48(block.timestamp);
    emit AllowanceRefilled(currencyId, capacity);
  }

  /// @notice What the allowance would let a reward take right now (view for the operator and UI).
  function allowanceRemaining(uint8 currencyId) external view returns (uint256 remainder, uint256 capacity) {
    S.GameStorage storage $ = S.s();
    S.CurrencyState storage cs = $.currencies[currencyId];
    capacity = _capacity($, currencyId, cs);
    remainder = _remainder(cs, capacity);
  }

  // ----------------- Batch entries -----------------

  /// @dev Binding (ADR-0003/0019): the report covers the request timestamp; P comes from the operator.
  function _bind(S.GameStorage storage $, uint256 positionId, DataStreamsReports.Decoded memory rep, uint64 pWad, uint64 deltaWad)
    private
    returns (bytes memory)
  {
    S.Position storage p = $.positions[positionId];
    if (p.status != S.PositionStatus.Requested) return "status";
    S.Channel storage c = $.channels[p.channelId];
    // the outcome is already fixed — past the settlement window, or attested as survived: a bind now
    // would price a known result at the request's odds (audit 2026-10-19, H-03). Refund instead; the
    // report is not read, though the entry still needs one in the batch (applyEntry checks the index).
    if (block.timestamp > uint256(c.endTs) + $.settlementWindow || c.survivedAt != 0) {
      _refund($, positionId, S.PositionStatus.Cancelled);
      emit PositionCancelled(positionId);
      return "";
    }
    if (rep.feedId != c.feedId) return "feed";
    if (!(rep.validFromTimestamp <= p.requestTs && p.requestTs <= rep.observationsTimestamp)) return "coverage";
    if (uint256(rep.observationsTimestamp) - p.requestTs > _maxReportLag($)) return "lag";
    // a report for a closed/unknown market (RWA schemas) or a non-positive price is not a valid entry price
    if (rep.marketStatus == 0 || rep.marketStatus == 5) return "market";
    if (rep.price <= 0) return "price";
    if (deltaWad >= MAX_DELTA_WAD) return "delta";
    if (pWad <= P_EPSILON || pWad >= WAD - P_EPSILON) return "p-bounds";

    // channel is dead by the time of the request → cancel with refund (ADR-0015)
    if (c.breachedAt != 0 && c.breachedAt <= p.requestTs) {
      _refund($, positionId, S.PositionStatus.Cancelled);
      emit PositionCancelled(positionId);
      return "";
    }

    // anchor a "from entry price" channel on the first binding
    if (!c.anchored) {
      if (c.priceOnOpen) {
        c.centerPrice = rep.price;
        c.startTs = p.requestTs;
        emit ChannelAnchored(p.channelId, rep.price, p.requestTs);
      }
      c.anchored = true;
    }

    // request predates the start of the channel's life (anchor set by a later binding) — cancel with refund
    if (p.requestTs < c.startTs) {
      _refund($, positionId, S.PositionStatus.Cancelled);
      emit PositionCancelled(positionId);
      return "";
    }

    // the entry price must be inside the channel (ADR-0015)
    (int256 lower, int256 upper) = _boundsAt(c, p.requestTs);
    if (int256(rep.price) <= lower || int256(rep.price) >= upper) {
      _refund($, positionId, S.PositionStatus.Cancelled);
      emit PositionCancelled(positionId);
      return "";
    }

    uint256 mult = _multiplier(pWad, p.side, deltaWad, p.ceilingWad);
    if (mult < p.minMultiplierWad) {
      _refund($, positionId, S.PositionStatus.Cancelled);
      emit PositionCancelled(positionId);
      return "";
    }

    // the reserve is trued up to the full reward (cash model, ADR-0013)
    uint256 reward = (uint256(p.stake) * (mult - WAD)) / WAD;
    S.vaultOf($, p.currencyId).release(p.reserved - reward);
    p.reserved = uint128(reward);

    p.entryPrice = rep.price;
    p.pWad = pWad;
    p.multiplierWad = uint128(mult);
    p.status = S.PositionStatus.Active;
    emit PositionBound(positionId, rep.price, pWad, deltaWad, uint128(mult), uint128(reward));
    return "";
  }

  /// @dev Channel breach (ADR-0015): a touch = a breach, time must fall within the channel's life.
  ///      Refused once the settlement window has passed (ADR-0022): an approved outcome cannot be reopened.
  function _markBreach(S.GameStorage storage $, uint256 channelId, DataStreamsReports.Decoded memory rep)
    private
    returns (bytes memory)
  {
    S.Channel storage c = $.channels[channelId];
    if (c.endTs == 0) return "channel";
    if (block.timestamp > uint256(c.endTs) + $.settlementWindow) return "late";
    if (c.survivedAt != 0) return "survived"; // the operator attested the outcome: final
    // an earlier proven touch moves the breach back: breachedAt is the EARLIEST proven touch (ADR-0015)
    if (c.breachedAt != 0 && c.breachedAt <= rep.observationsTimestamp) return "already";
    if (rep.feedId != c.feedId) return "feed";
    if (rep.marketStatus == 0 || rep.marketStatus == 5) return "market";
    if (rep.price <= 0) return "price";
    if (c.priceOnOpen && !c.anchored) return "not-anchored";
    if (rep.observationsTimestamp <= c.startTs || rep.observationsTimestamp > c.endTs) return "time";
    (int256 lower, int256 upper) = _boundsAt(c, rep.observationsTimestamp);
    if (int256(rep.price) > lower && int256(rep.price) < upper) return "inside";
    c.breachedAt = rep.observationsTimestamp;
    emit ChannelBreached(channelId, rep.observationsTimestamp, rep.price);
    return "";
  }

  /// @dev The operator's attestation that an ended channel was never breached (audit 2026-10-19): the
  ///      only way a channel survives. Sent once the breach scan covers endTs; final — no breach proof
  ///      is accepted after it. Refused while a breach is on record or once the window has passed.
  function _markSurvived(S.GameStorage storage $, uint256 channelId) private returns (bytes memory) {
    S.Channel storage c = $.channels[channelId];
    if (c.endTs == 0) return "channel";
    if (c.breachedAt != 0) return "breached";
    if (c.survivedAt != 0) return "already";
    if (block.timestamp <= c.endTs) return "not-final";
    if (block.timestamp > uint256(c.endTs) + $.settlementWindow) return "late";
    c.survivedAt = uint64(block.timestamp);
    emit ChannelSurvived(channelId, uint64(block.timestamp));
    return "";
  }

  /// @dev Report lag bound (audit 2026-10-19, M-06): admin-set, 30 s until set.
  function _maxReportLag(S.GameStorage storage $) private view returns (uint256) {
    return $.maxReportLagSec == 0 ? DEFAULT_MAX_REPORT_LAG : $.maxReportLagSec;
  }

  /// @dev Settlement by the channel's outcome (expiry/breach); a late entry gets a refund.
  function _settle(S.GameStorage storage $, uint256 positionId) private returns (bytes memory) {
    S.Position storage p = $.positions[positionId];
    if (p.status != S.PositionStatus.Active && p.status != S.PositionStatus.CloseRequested) return "status";
    S.Channel storage c = $.channels[p.channelId];

    bool breached = c.breachedAt != 0;
    if (breached && c.breachedAt <= p.requestTs) {
      _refund($, positionId, S.PositionStatus.Refunded);
      emit PositionRefunded(positionId, uint256(p.deposit) - p.openFeeFixed);
      return "";
    }
    // a channel only "survives" by the operator's attestation (MarkSurvived), never by the clock alone
    // (audit 2026-10-19: a missing proof used to settle as survived at endTs + 1)
    bool decided = breached || c.survivedAt != 0;
    // nobody attested within the settlement window: the outcome can never be decided now, so the
    // operator refunds like refundStale does instead of locking the reserve until each owner calls it
    if (!decided && block.timestamp > uint256(c.endTs) + $.settlementWindow) {
      _refund($, positionId, S.PositionStatus.Refunded);
      emit PositionRefunded(positionId, uint256(p.deposit) - p.openFeeFixed);
      return "";
    }
    // close was requested and not subsumed by a breach before the request — only via SettleClose (ADR-0012: the request is irreversible)
    if (p.status == S.PositionStatus.CloseRequested && !(breached && c.breachedAt <= p.closeRequestTs)) {
      // a close no report could price is void once the outcome is known and the fallback delay has
      // passed: settle by the outcome instead of a near-full refundStale (audit 2026-10-19, M-05)
      if (!decided || block.timestamp <= uint256(c.endTs) + CLOSE_FALLBACK_DELAY) return "close-pending";
      p.status = S.PositionStatus.Active;
      p.closeRequestTs = 0;
    }
    if (!decided) return "not-final";

    bool won = (p.side == S.Side.Survive) ? !breached : breached;
    if (!won) {
      return _finalize($, positionId, 0, breached && p.side == S.Side.Survive ? S.PositionStatus.Liquidated : S.PositionStatus.Settled, 0, 0, 0);
    }
    uint256 reward = (uint256(p.stake) * (p.multiplierWad - WAD)) / WAD; // == p.reserved
    return _finalize($, positionId, uint256(p.stake) + reward, S.PositionStatus.Settled, 0, 0, 0);
  }

  /// @dev Early close (ADR-0012): V = stake·M·P_win·(1−penalty); entry σ, P_now from the operator.
  function _settleClose(S.GameStorage storage $, uint256 positionId, DataStreamsReports.Decoded memory rep, uint64 pNowWad)
    private
    returns (bytes memory)
  {
    S.Position storage p = $.positions[positionId];
    if (p.status != S.PositionStatus.CloseRequested) return "status";
    S.Channel storage c = $.channels[p.channelId];
    if (rep.feedId != c.feedId) return "feed";
    if (!(rep.validFromTimestamp <= p.closeRequestTs && p.closeRequestTs <= rep.observationsTimestamp)) {
      return "coverage";
    }
    if (uint256(rep.observationsTimestamp) - p.closeRequestTs > _maxReportLag($)) return "lag";
    if (rep.marketStatus == 0 || rep.marketStatus == 5) return "market";
    if (rep.price <= 0) return "price";
    if (c.breachedAt != 0 && c.breachedAt <= p.closeRequestTs) return _settle($, positionId);
    (int256 lower, int256 upper) = _boundsAt(c, p.closeRequestTs);
    if (int256(rep.price) <= lower || int256(rep.price) >= upper) {
      // the close report is proof of a touch at the request moment (ADR-0012/0015): record it as the
      // earliest proven touch and settle by outcome. Skipping here instead ("is-breach") left the
      // position stuck: Settle answered "close-pending" and a later breach could never move earlier.
      // same finality rule as _markBreach (ADR-0022): no new breach once the settlement window has passed
      if (block.timestamp > uint256(c.endTs) + $.settlementWindow) return "late";
      // same lifetime rule as _markBreach (audit 2026-10-19, M-06): a price observed after expiry
      // never back-dates a breach; and an attested survival is final
      if (rep.observationsTimestamp > c.endTs) return "time";
      if (c.survivedAt != 0) return "survived";
      c.breachedAt = p.closeRequestTs;
      emit ChannelBreached(p.channelId, p.closeRequestTs, rep.price);
      return _settle($, positionId);
    }
    if (pNowWad <= P_EPSILON || pNowWad >= WAD - P_EPSILON) return "p-bounds";

    uint256 winP = p.side == S.Side.Survive ? pNowWad : WAD - pNowWad;
    uint256 v = (uint256(p.stake) * p.multiplierWad) / WAD;
    v = (v * winP) / WAD;
    uint256 payout = (v * (BPS - p.earlyClosePenaltyBps)) / BPS;
    uint256 maxPayout = uint256(p.stake) + p.reserved;
    if (payout > maxPayout) payout = maxPayout;
    return _finalize($, positionId, payout, S.PositionStatus.Settled, pNowWad, rep.price, rep.observationsTimestamp);
  }

  // ----------------- Money -----------------

  /**
   * @dev Splits a position's money. `grossPayout` — stake + reward BEFORE the profit fee (0 on a
   *      loss). The closing fee and royalty are computed here (ADR-0013/0018). Legs (ADR-0022):
   *      loss → the working amount to capital; early close below the working amount → the shortfall
   *      to capital; win → the reward from capital, or deferred when the game is paused or the
   *      currency's allowance cannot cover it.
   */
  function _finalize(
    S.GameStorage storage $,
    uint256 positionId,
    uint256 grossPayout,
    S.PositionStatus finalStatus,
    uint64 pNowWad,
    int192 closePrice,
    uint32 closeObservedAt
  ) private returns (bytes memory) {
    S.Position storage p = $.positions[positionId];
    S.Channel storage c = $.channels[p.channelId];
    Vault vault = S.vaultOf($, p.currencyId);

    if (grossPayout > p.stake) {
      uint256 reward = grossPayout - p.stake;
      // No royalty on the channel owner's own position (ADR-0018, 2026-09-24). `address(this)` is the
      // game proxy — the library runs by delegatecall — so this reads the channel token's current owner.
      bool eligible = p.owner != IERC721(address(this)).ownerOf(p.channelId);

      if (!_tryDrain($, p.currencyId, positionId, reward)) {
        // deferral: the working amount now, the reward stays reserved (exactly `reward`)
        vault.release(p.reserved - reward);
        p.reserved = uint128(reward);
        p.royaltyEligible = eligible;
        p.status = S.PositionStatus.RewardDeferred;
        $.deferredCount += 1;
        vault.settle(p.deposit, 0, p.owner, p.stake, uint256(p.deposit) - p.stake, 0, 0, 0);
        // v2 indexers only know PositionSettled: the position leaves Active here, with the working amount paid
        // (outcome = RewardDeferred). Approval/rejection emit their own events, never a second PositionSettled.
        emit PositionSettled(positionId, uint8(S.PositionStatus.RewardDeferred), p.stake);
        emit RewardDeferred(positionId, p.currencyId, reward, eligible, pNowWad, closePrice, closeObservedAt);
        return "";
      }

      uint256 fee = (reward * p.profitFeeBps) / BPS;
      uint256 toRoyalty = eligible ? (fee * c.royaltyBps) / BPS : 0;
      uint256 toRevenue = (uint256(p.deposit) - p.stake) + (fee - toRoyalty);
      uint256 toPlayer = grossPayout - fee;
      vault.release(p.reserved);
      p.reserved = 0;
      p.status = finalStatus;
      c.openPositions -= 1;
      vault.settle(p.deposit, reward, p.owner, toPlayer, toRevenue, p.channelId, toRoyalty, 0);
      emit PositionSettled(positionId, uint8(finalStatus), toPlayer);
      return "";
    }

    // loss, or an early close at or below the working amount: what the player does not get back
    // is the house's win and goes to capital; the opening fee goes to revenue
    uint256 toCapital = uint256(p.stake) - grossPayout;
    uint256 openFee = uint256(p.deposit) - p.stake;
    vault.release(p.reserved);
    p.reserved = 0;
    p.status = finalStatus;
    c.openPositions -= 1;
    vault.settle(p.deposit, 0, p.owner, grossPayout, openFee, 0, 0, toCapital);
    if (toCapital != 0) _refill($, p.currencyId, toCapital);
    emit PositionSettled(positionId, uint8(finalStatus), grossPayout);
    return "";
  }

  /// @dev Refund without settling an outcome: deposit − fixed fee (ADR-0002/0013).
  function _refund(S.GameStorage storage $, uint256 positionId, S.PositionStatus finalStatus) private {
    S.Position storage p = $.positions[positionId];
    S.Channel storage c = $.channels[p.channelId];
    Vault vault = S.vaultOf($, p.currencyId);
    uint256 refund = uint256(p.deposit) - p.openFeeFixed;
    vault.release(p.reserved);
    p.reserved = 0;
    p.status = finalStatus;
    c.openPositions -= 1;
    vault.settle(p.deposit, 0, p.owner, refund, p.openFeeFixed, 0, 0, 0);
  }

  /// @dev Closes a deferred position either way: the reserve is released, the channel's open count drops.
  function _resolveDeferred(S.GameStorage storage $, uint256 positionId, S.PositionStatus finalStatus) private {
    S.Position storage p = $.positions[positionId];
    S.vaultOf($, p.currencyId).release(p.reserved);
    p.reserved = 0;
    p.status = finalStatus;
    $.channels[p.channelId].openPositions -= 1;
    $.deferredCount -= 1;
  }

  /// @dev Whether a deferred win is still a win given everything proven since (ADR-0022, audit M-7).
  ///      A "breaches" win cannot be undone; a "survives" win is lost by any breach inside the channel's
  ///      life (expiry settlement) or before the close request (early close).
  function _stillWon(S.Position storage p, S.Channel storage c) private view returns (bool) {
    // a breach proven at or before the request: the channel was dead at entry — settlement would refund (ADR-0015)
    if (c.breachedAt != 0 && c.breachedAt <= p.requestTs) return false;
    if (p.side == S.Side.Breach) return true;
    // no breach on record. A post-audit expiry win is only deferred after the attestation, which also
    // ends breach proofs, so the attestation is not re-checked here: rewards deferred before the
    // 2026-10-19 upgrade (survivedAt == 0) must stay approvable
    if (c.breachedAt == 0) return true;
    if (p.closeRequestTs == 0) return false;
    return c.breachedAt > p.closeRequestTs;
  }

  // ----------------- Drawdown allowance (ADR-0022) -----------------

  /// @dev Capacity = share × the vault's current capital.
  function _capacity(S.GameStorage storage $, uint8 currencyId, S.CurrencyState storage cs) private view returns (uint256) {
    return (S.vaultOf($, currencyId).capital() * cs.drawdownBps) / BPS;
  }

  /// @dev Remainder after the time refill, never above capacity; an untouched bucket is full.
  function _remainder(S.CurrencyState storage cs, uint256 capacity) private view returns (uint256) {
    if (cs.bucketUpdatedAt == 0) return capacity;
    uint256 r = uint256(cs.bucketRemainder) + (capacity * (block.timestamp - cs.bucketUpdatedAt)) / S.DRAWDOWN_REFILL_PERIOD;
    return r > capacity ? capacity : r;
  }

  /// @dev Takes `reward` out of the allowance. Returns false — and pauses the game on the first such
  ///      settlement — when it cannot: the game is paused, the share is zero, or the bucket is short.
  function _tryDrain(S.GameStorage storage $, uint8 currencyId, uint256 positionId, uint256 reward) private returns (bool) {
    if ($.paused) return false;
    S.CurrencyState storage cs = $.currencies[currencyId];
    if (cs.drawdownBps == 0) return false; // review mode: everything waits, nothing pauses
    uint256 capacity = _capacity($, currencyId, cs);
    uint256 r = _remainder(cs, capacity);
    if (reward > r) {
      $.paused = true;
      emit AllowanceExhausted(currencyId, positionId, reward, r);
      emit PausedSet(true);
      return false;
    }
    cs.bucketRemainder = uint128(r - reward);
    cs.bucketUpdatedAt = uint48(block.timestamp);
    return true;
  }

  /// @dev A lost working amount refills the allowance, up to capacity.
  function _refill(S.GameStorage storage $, uint8 currencyId, uint256 amount) private {
    S.CurrencyState storage cs = $.currencies[currencyId];
    if (cs.drawdownBps == 0) return;
    uint256 capacity = _capacity($, currencyId, cs);
    uint256 r = _remainder(cs, capacity) + amount;
    cs.bucketRemainder = uint128(r > capacity ? capacity : r);
    cs.bucketUpdatedAt = uint48(block.timestamp);
  }

  // ----------------- Math -----------------

  /// @dev Channel bounds at moment t (pricing.md), in the report's price units.
  function _boundsAt(S.Channel storage c, uint64 t) private view returns (int256 lower, int256 upper) {
    int256 center = int256(c.centerPrice);
    center += (center * c.slopeWadPerSec * int256(uint256(t - c.startTs))) / int256(WAD);
    int256 half = (int256(c.centerPrice) * int256(uint256(c.heightWad))) / int256(2 * WAD);
    return (center - half, center + half);
  }

  /// @dev Both sides from a single P (ADR-0019): M = (1−δ)/P_win, under the cap.
  function _multiplier(uint64 pWad, S.Side side, uint256 deltaWad, uint256 ceilingWad) private pure returns (uint256) {
    uint256 winP = side == S.Side.Survive ? pWad : WAD - pWad;
    uint256 m = ((WAD - deltaWad) * WAD) / winP;
    return m > ceilingWad ? ceilingWad : m;
  }
}
