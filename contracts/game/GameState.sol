// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {AccessRegistry} from "../access/AccessRegistry.sol";
import {AssetRegistry} from "../assets/AssetRegistry.sol";
import {Vault} from "../vault/Vault.sol";
import {IVerifierProxy} from "../interfaces/IVerifierProxy.sol";

/**
 * @title GameState
 * @notice Types and storage for ChannelGame (ERC-7201), shared between the contract and the
 *         external GameLogic library (delegatecall shares storage and the event-emitting address).
 */
library GameState {
  enum Side {
    Survive, // "survives"
    Breach // "breaches"
  }

  enum PositionStatus {
    None,
    Requested,
    Active,
    CloseRequested,
    Settled,
    Liquidated,
    Refunded,
    Cancelled,
    RewardDeferred, // v3 (ADR-0022): working amount paid, reward waits for the admin
    RewardRejected // v3: the admin refused the reward; the reserve went back to free capital
  }

  enum EntryKind {
    Bind, // binding a request: report + P
    Breach, // marking a channel breach
    Settle, // settling a position by the channel's outcome
    SettleClose, // settling an early close: report + P_now
    MarkSurvived // the operator attests that an ended channel was never breached (audit 2026-10-19)
  }

  /// @notice Channel (ADR-0018). Geometry is relative (pricing.md), center is absolute.
  struct Channel {
    bytes32 feedId;
    address creator;
    uint64 startTs;
    uint64 endTs;
    int192 centerPrice; // 0 until the first position is bound, when priceOnOpen
    uint128 heightWad; // share of the center
    int128 slopeWadPerSec; // share of the center per second, signed
    bool priceOnOpen; // center = entry price of the first position
    bool anchored;
    uint64 breachedAt; // 0 = not breached
    uint16 royaltyBps; // snapshot of the royalty share (ADR-0018)
    bool royaltyClaimed; // OVER royalty claimed (ADR-0018); kept a bool so v2 readers of getChannel see the same value
    uint32 openPositions;
    uint32 totalPositions;
    uint8 claimedOthers; // v3 (ADR-0021): bit (currencyId − 1) set when that currency's royalty is claimed; spare bytes of slot 4
    uint64 survivedAt; // 0 = not attested; set by the operator's MarkSurvived after endTs — the only way a channel "survives" (spare bytes of slot 4)
  }

  /// @notice Position/request. Snapshots per ADR-0013 + side and P (ADR-0019).
  /// @dev Fields grouped by storage slot — 7 slots; timestamps are uint48 (good for ~8.9e6 years).
  ///      v3 appends two fields in a new slot 7 (zero for OVER positions, so nearly free to write): the
  ///      struct order is also the ABI order of `getPosition`, and v2 readers must keep decoding it.
  struct Position {
    // slot 0
    PositionStatus status;
    Side side;
    address owner;
    uint48 requestTs;
    uint16 profitFeeBps;
    uint16 earlyClosePenaltyBps;
    // slot 1
    uint256 channelId;
    // slot 2
    int192 entryPrice;
    uint48 closeRequestTs;
    // slot 3
    uint128 deposit;
    uint128 stake;
    // slot 4
    uint128 openFeeFixed;
    uint128 reserved;
    // slot 5
    uint128 multiplierWad; // WAD; 0 until binding, the multiplier (≤ cap snapshot) afterward
    uint128 ceilingWad; // cap snapshot at request time (ADR-0013)
    // slot 6
    uint128 minMultiplierWad; // max(config minimum, player floor) at request time (ADR-0013/0019)
    uint64 sigmaWad; // raw quote σ₁ₘ, WAD (without g(N) — ADR-0016 amended; σ ≤ 1e18)
    uint64 pWad; // P at binding, WAD
    // slot 7 (v3)
    uint8 currencyId; // ADR-0021: 0 = OVER, the vault that was live before v3
    bool royaltyEligible; // ADR-0022: snapshotted when a reward is deferred
  }

  struct BatchEntry {
    EntryKind kind;
    uint256 id; // positionId or channelId (Breach)
    uint32 reportIndex;
    uint64 pWad; // Bind: P; SettleClose: P_now
    uint64 deltaWad; // Bind: spread δ(R, remainder) at binding time; unused for other kinds
  }

  /// @notice Per-currency state (ADR-0021/0022): the drawdown allowance and the claim dust floor.
  struct CurrencyState {
    uint16 drawdownBps; // share of capital the bucket holds; 0 = currency closed for intake, every reward deferred
    uint48 bucketUpdatedAt; // 0 = never touched: the bucket is full
    uint128 bucketRemainder; // allowance left at bucketUpdatedAt, before time refill
    // ADR-0023: false (the default) = a request in this currency needs the operator's entry permit for its
    // owner; true = anyone may open. Never consulted for currency 0 (OVER). Fits the first slot's free bytes.
    bool permitless;
    uint128 dustFloor; // royalty accounts below this are not converted (ADR-0021)
  }

  /// @custom:storage-location erc7201:overcall.game
  struct GameStorage {
    AccessRegistry access;
    AssetRegistry assets;
    Vault vault; // currency 0 (OVER) — the vault that was live before v3
    IVerifierProxy verifier;
    uint64 settlementWindow; // ADR-0002
    bool paused;
    uint256 nextChannelId;
    uint256 nextPositionId;
    mapping(uint256 => Channel) channels;
    mapping(uint256 => Position) positions;
    // ---- v3 (ADR-0021/0022), appended ----
    mapping(uint8 currencyId => Vault) vaults; // currencies ≥ 1; `vaultOf` serves 0 from `vault`
    mapping(uint8 currencyId => address) currencyTokens; // the vault's token, for the claim route
    mapping(uint8 currencyId => CurrencyState) currencies;
    uint8 currencyCount; // ids 0..currencyCount-1 are live
    uint32 deferredCount; // positions in RewardDeferred; unpause needs force while > 0
    address router; // exchange route: Uniswap v2-style router (timelock)
    mapping(uint8 currencyId => address[]) routePaths; // currency token → … → OVER (admin)
    uint8 reentrancy; // claim-with-conversion guard
    string baseURI; // channel NFT metadata: tokenURI = baseURI + channelId (admin; empty = no metadata)
    uint32 maxReportLagSec; // a report observed later than this after the anchored second is refused (admin; 0 = default 30 s)
  }

  uint256 internal constant DRAWDOWN_REFILL_PERIOD = 1 days;

  // keccak256(abi.encode(uint256(keccak256("overcall.game")) - 1)) & ~bytes32(uint256(0xff))
  bytes32 internal constant STORAGE_SLOT = 0x68f00b16375d1bd680d5b93a11c6cd8b83b1cbf10a1b6d3c9e6be5f6cbb95900;

  function s() internal pure returns (GameStorage storage $) {
    bytes32 slot = STORAGE_SLOT;
    assembly {
      $.slot := slot
    }
  }

  /// @dev The vault of a currency (ADR-0021). Currency 0 is the pre-v3 vault.
  function vaultOf(GameStorage storage $, uint8 currencyId) internal view returns (Vault) {
    return currencyId == 0 ? $.vault : $.vaults[currencyId];
  }
}
