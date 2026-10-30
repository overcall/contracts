// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AccessRegistry} from "../access/AccessRegistry.sol";
import {AssetRegistry} from "../assets/AssetRegistry.sol";
import {Vault} from "../vault/Vault.sol";
import {OverToken} from "../mocks/OverToken.sol";
import {MockVerifierProxy} from "../mocks/MockVerifierProxy.sol";
import {DataStreamsReports} from "../libs/DataStreamsReports.sol";
import {ChannelGame} from "./ChannelGame.sol";
import {GameState} from "./GameState.sol";
import {GameLogic} from "./GameLogic.sol";

import {ChannelGameTestBase} from "./ChannelGameTestBase.sol";

contract ChannelGameTest is ChannelGameTestBase {
  // ----------------- request -----------------

  function test_OpenPositionCollectsDepositAndReservesCeiling() public {
    uint256 pid = _openDefault(GameState.Side.Survive, PLAYER);
    GameState.Position memory p = game.getPosition(pid);
    assertEq(uint8(p.status), uint8(GameState.PositionStatus.Requested));
    // opening fee: max(1% of 100, 0.5) = 1 → stake 99
    assertEq(p.stake, 99e18);
    assertEq(vault.heldDeposits(), 100e18);
    // reserve at the cap: 99 × 49 = 4851
    assertEq(vault.reservedTotal(), 4851e18);
    assertTrue(vault.solvent());
  }

  function test_OpenRejectsBadQuoteSigner() public {
    (ChannelGame.VolatilityQuote memory q,) = _quote(0.0007e18);
    (uint8 v, bytes32 r0, bytes32 s0) = vm.sign(0xDEAD, keccak256("x"));
    ChannelGame.OpenRequest memory r;
    r.newChannel = ChannelGame.NewChannel(BTC, 0, uint64(block.timestamp + 4 hours), 0, 0.02e18, 0, true, PLAYER);
    r.side = GameState.Side.Survive;
    r.deposit = 100e18;
    r.owner = PLAYER;
    r.quote = q;
    r.quoteSignature = abi.encodePacked(r0, s0, v);
    vm.prank(PLAYER);
    vm.expectRevert();
    game.openPosition(r);
  }

  function test_OpenRejectsGeometryOutsideSigmaBounds() public {
    // height 0.02 at σ 0.02 → 1 σ < the 4 σ minimum
    (ChannelGame.VolatilityQuote memory q, bytes memory sig) = _quote(0.02e18);
    ChannelGame.OpenRequest memory r;
    r.newChannel = ChannelGame.NewChannel(BTC, 0, uint64(block.timestamp + 4 hours), 0, 0.02e18, 0, true, PLAYER);
    r.side = GameState.Side.Survive;
    r.deposit = 100e18;
    r.owner = PLAYER;
    r.quote = q;
    r.quoteSignature = sig;
    vm.prank(PLAYER);
    vm.expectRevert(abi.encodeWithSelector(ChannelGame.BadGeometry.selector, "height"));
    game.openPosition(r);
  }

  function test_GuardianPausesIntake() public {
    vm.prank(GUARDIAN);
    game.setPaused(true);
    (ChannelGame.VolatilityQuote memory q, bytes memory sig) = _quote(0.0007e18);
    ChannelGame.OpenRequest memory r;
    r.newChannel = ChannelGame.NewChannel(BTC, 0, uint64(block.timestamp + 4 hours), 0, 0.02e18, 0, true, PLAYER);
    r.deposit = 100e18;
    r.owner = PLAYER;
    r.quote = q;
    r.quoteSignature = sig;
    vm.prank(PLAYER);
    vm.expectRevert(ChannelGame.GamePaused.selector);
    game.openPosition(r);
  }

  // ----------------- binding -----------------

  function test_BindAnchorsChannelAndSetsMultiplier() public {
    uint256 pid = _openDefault(GameState.Side.Survive, PLAYER);
    _bind(pid, 80_000e18, 0.5e18); // P = 0.5, δ = 0.02 → M = 0.98/0.5 = 1.96
    GameState.Position memory p = game.getPosition(pid);
    assertEq(uint8(p.status), uint8(GameState.PositionStatus.Active));
    assertEq(p.entryPrice, 80_000e18);
    assertEq(p.multiplierWad, 1.96e18);
    // reserve trued up to the reward: 99 × 0.96 = 95.04
    assertEq(vault.reservedTotal(), 95.04e18);
    GameState.Channel memory c = game.getChannel(p.channelId);
    assertTrue(c.anchored);
    assertEq(c.centerPrice, 80_000e18);
  }

  function test_BindStoresHighMultiplierWithoutTruncation() public {
    // P = 0.03 → M = 0.98/0.03 ≈ ×32.67 > uint64 max (regression: uint64 truncation)
    uint256 pid = _openDefault(GameState.Side.Survive, PLAYER);
    _bind(pid, 80_000e18, 0.03e18);
    GameState.Position memory p = game.getPosition(pid);
    uint256 m = (0.98e18 * 1e18) / uint256(0.03e18);
    assertEq(p.multiplierWad, m);
    assertEq(vault.reservedTotal(), (99e18 * (m - 1e18)) / 1e18);
  }

  function test_BindSkipsZeroPriceWithoutAnchoring() public {
    uint256 pid = _openDefault(GameState.Side.Survive, PLAYER);
    _bind(pid, 0, 0.5e18); // price 0 — skip "price", the anchor is not set
    GameState.Position memory p = game.getPosition(pid);
    assertEq(uint8(p.status), uint8(GameState.PositionStatus.Requested));
    assertFalse(game.getChannel(p.channelId).anchored);
    _bind(pid, 80_000e18, 0.5e18); // a normal report then binds it
    assertEq(uint8(game.getPosition(pid).status), uint8(GameState.PositionStatus.Active));
  }

  function test_CreateChannelRejectsInsaneGeometry() public {
    ChannelGame.NewChannel memory n =
      ChannelGame.NewChannel(BTC, 0, uint64(block.timestamp + 4 hours), 0, 0.02e18, type(int128).min, true, PLAYER);
    vm.prank(PLAYER); // negating int128.min no longer panics — rejected at creation instead
    vm.expectRevert(abi.encodeWithSelector(ChannelGame.BadGeometry.selector, "slope"));
    game.createChannel(n);

    n.slopeWadPerSec = 0;
    n.heightWad = 0;
    vm.prank(PLAYER);
    vm.expectRevert(abi.encodeWithSelector(ChannelGame.BadGeometry.selector, "height"));
    game.createChannel(n);
  }

  /// @dev Drawn channels (a fixed center and start) are not offered (audit 2026-10-19, H-03): the
  ///      operator never prices them, so a request on one waited until it could be bound on a known outcome.
  function test_DrawnChannelsAreRejected() public {
    ChannelGame.NewChannel memory n = ChannelGame.NewChannel(
      BTC, uint64(block.timestamp), uint64(block.timestamp + 4 hours), 80_000e18, 0.02e18, 0, false, PLAYER
    );
    vm.prank(PLAYER);
    vm.expectRevert(abi.encodeWithSelector(ChannelGame.BadGeometry.selector, "drawn"));
    game.createChannel(n);

    (ChannelGame.VolatilityQuote memory q, bytes memory sig) = _quote(0.0007e18);
    ChannelGame.OpenRequest memory r;
    r.newChannel = n;
    r.side = GameState.Side.Survive;
    r.deposit = 100e18;
    r.owner = PLAYER;
    r.quote = q;
    r.quoteSignature = sig;
    vm.prank(PLAYER);
    vm.expectRevert(abi.encodeWithSelector(ChannelGame.BadGeometry.selector, "drawn"));
    game.openPosition(r);
  }

  function test_UnpauseOnlyAdmin() public {
    vm.prank(GUARDIAN);
    game.setPaused(true);
    vm.prank(GUARDIAN);
    vm.expectRevert(ChannelGame.NotGuardianOrAdmin.selector);
    game.setPaused(false);
    vm.prank(ADMIN);
    game.setPaused(false);
    assertFalse(game.paused());
  }

  function test_RequestCloseRejectedOnBreachedChannel() public {
    uint256 pid = _openDefault(GameState.Side.Survive, PLAYER);
    _bind(pid, 80_000e18, 0.5e18);
    uint256 chId = game.getPosition(pid).channelId;
    _breachEntry(chId, 81_000e18, uint32(block.timestamp + 10));
    vm.prank(PLAYER);
    vm.expectRevert(abi.encodeWithSelector(ChannelGame.ChannelClosedForEntries.selector, chId));
    game.requestClose(pid);
  }

  function test_BindSkipsClosedMarketReport() public {
    bytes32 feedV8 = bytes32((uint256(0x0008) << 240) | 99);
    vm.prank(ADMIN);
    assets.registerAsset(feedV8, _config());
    (ChannelGame.VolatilityQuote memory q, bytes memory sig) = _quoteFor(feedV8, 0.0007e18);
    ChannelGame.OpenRequest memory r;
    r.newChannel = ChannelGame.NewChannel(feedV8, 0, uint64(block.timestamp + 4 hours), 0, 0.02e18, 0, true, PLAYER);
    r.side = GameState.Side.Survive;
    r.deposit = 100e18;
    r.owner = PLAYER;
    r.quote = q;
    r.quoteSignature = sig;
    vm.prank(PLAYER);
    uint256 pid = game.openPosition(r);

    uint64 ts = game.getPosition(pid).requestTs;
    bytes[] memory reports = new bytes[](1);
    bytes32[3] memory ctx;
    reports[0] = abi.encode(
      ctx,
      abi.encode(DataStreamsReports.ReportV8(feedV8, uint32(ts) - 1, uint32(ts) + 1, 0, 0, 0, 0, 80_000e18, 5))
    );
    GameState.BatchEntry[] memory entries = new GameState.BatchEntry[](1);
    entries[0] = GameState.BatchEntry(GameState.EntryKind.Bind, pid, 0, 0.5e18, 0.02e18);
    vm.prank(operator);
    game.processBatch(reports, entries); // marketStatus 5 (Closed) — skip "market"
    assertEq(uint8(game.getPosition(pid).status), uint8(GameState.PositionStatus.Requested));
  }

  function test_SettleSkipsCloseRequestedWithoutBreachBeforeRequest() public {
    // a close request is irreversible (ADR-0012): settling by outcome instead of the close price is not allowed
    uint256 pid = _openDefault(GameState.Side.Survive, PLAYER);
    _bind(pid, 80_000e18, 0.5e18);
    vm.prank(PLAYER);
    game.requestClose(pid);
    vm.warp(game.getChannel(game.getPosition(pid).channelId).endTs + 1);
    _settleEntry(pid); // must be skipped with reason "close-pending"
    assertEq(uint8(game.getPosition(pid).status), uint8(GameState.PositionStatus.CloseRequested));
  }

  function test_UserFloorCancelsBindBelowIt() public {
    (ChannelGame.VolatilityQuote memory q, bytes memory sig) = _quote(0.0007e18);
    ChannelGame.OpenRequest memory r;
    r.newChannel = ChannelGame.NewChannel(BTC, 0, uint64(block.timestamp + 4 hours), 0, 0.02e18, 0, true, PLAYER);
    r.side = GameState.Side.Survive;
    r.deposit = 100e18;
    r.owner = PLAYER;
    r.minMultiplierWad = 2.5e18; // the player demands a minimum of ×2.5
    r.quote = q;
    r.quoteSignature = sig;
    vm.prank(PLAYER);
    uint256 pid = game.openPosition(r);
    assertEq(game.getPosition(pid).minMultiplierWad, 2.5e18); // snapshot = max(1.01, 2.5)

    uint256 before = token.balanceOf(PLAYER);
    _bind(pid, 80_000e18, 0.5e18); // M = 1.96 < floor 2.5 → cancelled with refund
    assertEq(uint8(game.getPosition(pid).status), uint8(GameState.PositionStatus.Cancelled));
    assertEq(token.balanceOf(PLAYER) - before, 99.5e18);
  }

  function test_UserFloorSatisfiedBinds() public {
    (ChannelGame.VolatilityQuote memory q, bytes memory sig) = _quote(0.0007e18);
    ChannelGame.OpenRequest memory r;
    r.newChannel = ChannelGame.NewChannel(BTC, 0, uint64(block.timestamp + 4 hours), 0, 0.02e18, 0, true, PLAYER);
    r.side = GameState.Side.Survive;
    r.deposit = 100e18;
    r.owner = PLAYER;
    r.minMultiplierWad = 2.5e18;
    r.quote = q;
    r.quoteSignature = sig;
    vm.prank(PLAYER);
    uint256 pid = game.openPosition(r);
    _bind(pid, 80_000e18, 0.3e18); // M = 0.98/0.3 ≈ 3.27 ≥ 2.5 → binds
    assertEq(uint8(game.getPosition(pid).status), uint8(GameState.PositionStatus.Active));
  }

  function test_FloorAboveCeilingReverts() public {
    (ChannelGame.VolatilityQuote memory q, bytes memory sig) = _quote(0.0007e18);
    ChannelGame.OpenRequest memory r;
    r.newChannel = ChannelGame.NewChannel(BTC, 0, uint64(block.timestamp + 4 hours), 0, 0.02e18, 0, true, PLAYER);
    r.side = GameState.Side.Survive;
    r.deposit = 100e18;
    r.owner = PLAYER;
    r.minMultiplierWad = 51e18; // above the ×50 cap — the position could never bind
    r.quote = q;
    r.quoteSignature = sig;
    vm.prank(PLAYER);
    vm.expectRevert(abi.encodeWithSelector(ChannelGame.MultiplierFloorTooHigh.selector, uint128(51e18), uint128(50e18)));
    game.openPosition(r);
  }

  function test_BindSkipsDeltaOutOfRange() public {
    uint256 pid = _openDefault(GameState.Side.Survive, PLAYER);
    _bindD(pid, 80_000e18, 0.5e18, 0.5e18); // δ ≥ 0.5 → skip "delta", the request remains
    assertEq(uint8(game.getPosition(pid).status), uint8(GameState.PositionStatus.Requested));
    _bindD(pid, 80_000e18, 0.5e18, 0.1e18); // a valid δ then binds it: M = 0.9/0.5 = 1.8
    GameState.Position memory p = game.getPosition(pid);
    assertEq(uint8(p.status), uint8(GameState.PositionStatus.Active));
    assertEq(p.multiplierWad, 1.8e18);
  }

  function test_BindEmitsDelta() public {
    uint256 pid = _openDefault(GameState.Side.Survive, PLAYER);
    GameState.Position memory p0 = game.getPosition(pid);
    bytes[] memory reports = new bytes[](1);
    reports[0] = _report(80_000e18, uint32(p0.requestTs) - 1, uint32(p0.requestTs) + 1);
    GameState.BatchEntry[] memory entries = new GameState.BatchEntry[](1);
    entries[0] = GameState.BatchEntry(GameState.EntryKind.Bind, pid, 0, 0.5e18, 0.02e18);
    vm.expectEmit(true, false, false, true);
    emit GameLogic.PositionBound(pid, 80_000e18, 0.5e18, 0.02e18, 1.96e18, 95.04e18);
    vm.prank(operator);
    game.processBatch(reports, entries);
  }

  function test_FloorCutsInflatedDelta() public {
    (ChannelGame.VolatilityQuote memory q, bytes memory sig) = _quote(0.0007e18);
    ChannelGame.OpenRequest memory r;
    r.newChannel = ChannelGame.NewChannel(BTC, 0, uint64(block.timestamp + 4 hours), 0, 0.02e18, 0, true, PLAYER);
    r.side = GameState.Side.Survive;
    r.deposit = 100e18;
    r.owner = PLAYER;
    r.minMultiplierWad = 1.8e18; // the player computed from the public map, δ ≈ 0.02 → M ≈ 1.96
    r.quote = q;
    r.quoteSignature = sig;
    vm.prank(PLAYER);
    uint256 pid = game.openPosition(r);
    uint256 before = token.balanceOf(PLAYER);
    _bindD(pid, 80_000e18, 0.5e18, 0.3e18); // inflated δ: M = 0.7/0.5 = 1.4 < floor → cancelled
    assertEq(uint8(game.getPosition(pid).status), uint8(GameState.PositionStatus.Cancelled));
    assertEq(token.balanceOf(PLAYER) - before, 99.5e18);
  }

  function test_BindUsesSnapshotCeilingAfterConfigRaise() public {
    uint256 pid = _openDefault(GameState.Side.Survive, PLAYER);
    AssetRegistry.AssetConfig memory cfg = _config();
    cfg.ceilingWad = 100e18;
    vm.prank(ADMIN);
    assets.configureAsset(BTC, cfg);
    _bind(pid, 80_000e18, 0.01e18); // M = 0.98/0.01 = 98 → capped at the snapshot 50, not the new 100
    assertEq(game.getPosition(pid).multiplierWad, 50e18);
  }

  function test_RequestCloseAfterExpiryReverts() public {
    uint256 pid = _openDefault(GameState.Side.Survive, PLAYER);
    _bind(pid, 80_000e18, 0.5e18);
    uint256 chId = game.getPosition(pid).channelId;
    vm.warp(uint256(game.getChannel(chId).endTs) + 1);
    vm.prank(PLAYER);
    vm.expectRevert(abi.encodeWithSelector(ChannelGame.ChannelExpired.selector, chId));
    game.requestClose(pid);
  }

  function test_RefundStaleOnlyOwner() public {
    uint256 pid = _openDefault(GameState.Side.Survive, PLAYER);
    vm.warp(uint256(game.getChannel(game.getPosition(pid).channelId).endTs) + 7 days + 1);
    vm.prank(PLAYER2);
    vm.expectRevert(abi.encodeWithSelector(GameLogic.NotPositionOwner.selector, pid));
    game.refundStale(pid);
    vm.prank(PLAYER);
    game.refundStale(pid);
    assertEq(uint8(game.getPosition(pid).status), uint8(GameState.PositionStatus.Refunded));
  }

  function test_BindCancelsRequestOlderThanAnchor() public {
    uint256 pidA = _openDefault(GameState.Side.Survive, PLAYER);
    uint256 chId = game.getPosition(pidA).channelId;
    vm.warp(block.timestamp + 100);
    (ChannelGame.VolatilityQuote memory q, bytes memory sig) = _quote(0.0007e18);
    ChannelGame.OpenRequest memory r;
    r.channelId = chId;
    r.side = GameState.Side.Survive;
    r.deposit = 100e18;
    r.owner = PLAYER2;
    r.quote = q;
    r.quoteSignature = sig;
    vm.prank(PLAYER2);
    uint256 pidB = game.openPosition(r);
    _bind(pidB, 80_000e18, 0.5e18); // anchored by the later B: startTs = B.requestTs
    _bind(pidA, 80_000e18, 0.5e18); // A predates the start — cancelled with refund, not a batch panic
    assertEq(uint8(game.getPosition(pidA).status), uint8(GameState.PositionStatus.Cancelled));
    assertEq(uint8(game.getPosition(pidB).status), uint8(GameState.PositionStatus.Active));
  }

  function test_BindCancelsWhenEntryOutsideChannel() public {
    // a channel anchored at 80000 by its first bind; a later entry at a price outside bounds →
    // cancelled, refund deposit − fixed fee
    uint256 first = _openDefault(GameState.Side.Survive, PLAYER2);
    _bind(first, 80_000e18, 0.5e18);
    (ChannelGame.VolatilityQuote memory q, bytes memory sig) = _quote(0.0007e18);
    ChannelGame.OpenRequest memory r;
    r.channelId = game.getPosition(first).channelId;
    r.side = GameState.Side.Survive;
    r.deposit = 100e18;
    r.owner = PLAYER;
    r.quote = q;
    r.quoteSignature = sig;
    vm.warp(block.timestamp + 60);
    vm.prank(PLAYER);
    uint256 pid = game.openPosition(r);

    uint256 before = token.balanceOf(PLAYER);
    _bind(pid, 81_000e18, 0.5e18); // above the upper bound of 80800
    GameState.Position memory p = game.getPosition(pid);
    assertEq(uint8(p.status), uint8(GameState.PositionStatus.Cancelled));
    assertEq(token.balanceOf(PLAYER) - before, 99.5e18); // deposit − fixed fee 0.5
    assertEq(vault.reservedTotal(), game.getPosition(first).reserved); // only the first position's reserve
    assertTrue(vault.solvent());
  }

  // ----------------- outcomes -----------------

  function test_SurviveSideWinsOnExpiry() public {
    uint256 pid = _openDefault(GameState.Side.Survive, PLAYER);
    _bind(pid, 80_000e18, 0.5e18); // M = 1.96
    GameState.Position memory p0 = game.getPosition(pid);

    vm.warp(uint256(p0.requestTs) + 4 hours + 1);
    uint256 before = token.balanceOf(PLAYER);
    _settleEntry(pid);

    // reward 99×0.96 = 95.04; fee 10% = 9.504; to the player: 99 + 95.04 − 9.504 = 184.536
    assertEq(token.balanceOf(PLAYER) - before, 184.536e18);
    // the player owns the channel: no royalty on their own position (2026-09-24)
    assertEq(vault.royaltyOf(address(game), game.getPosition(pid).channelId), 0);
    // revenue: openFee 1 + the whole fee 9.504 = 10.504
    assertEq(vault.revenue(), 10.504e18);
    assertEq(vault.reservedTotal(), 0);
    assertTrue(vault.solvent());
    assertEq(uint8(game.getPosition(pid).status), uint8(GameState.PositionStatus.Settled));
  }

  function test_SurviveSideLosesOnBreach_BreachSideWins() public {
    uint256 pidS = _openDefault(GameState.Side.Survive, PLAYER);
    _bind(pidS, 80_000e18, 0.5e18);
    GameState.Position memory ps = game.getPosition(pidS);
    uint256 channelId = ps.channelId;

    // a second position in the same channel, "breaches" side
    (ChannelGame.VolatilityQuote memory q, bytes memory sig) = _quote(0.0007e18);
    ChannelGame.OpenRequest memory r;
    r.channelId = channelId;
    r.side = GameState.Side.Breach;
    r.deposit = 100e18;
    r.owner = PLAYER2;
    r.quote = q;
    r.quoteSignature = sig;
    vm.warp(block.timestamp + 60);
    vm.prank(PLAYER2);
    uint256 pidB = game.openPosition(r);
    _bind(pidB, 80_100e18, 0.6e18); // survival P 0.6 → "breaches" side: M = 0.98/0.4 = 2.45

    // breach an hour later
    uint32 breachTs = uint32(block.timestamp + 1 hours);
    _breachEntry(channelId, 80_900e18, breachTs); // above the upper bound of 80800
    assertEq(game.getChannel(channelId).breachedAt, breachTs);

    uint256 beforeS = token.balanceOf(PLAYER);
    uint256 beforeB = token.balanceOf(PLAYER2);
    _settleEntry(pidS);
    _settleEntry(pidB);

    // "survives" liquidated: deposit to revenue, player gets 0
    assertEq(token.balanceOf(PLAYER), beforeS);
    assertEq(uint8(game.getPosition(pidS).status), uint8(GameState.PositionStatus.Liquidated));
    // "breaches" won: 99 + 99×1.45×0.9 = 99 + 129.195... reward 143.55, fee 14.355
    // to the player: 99 + 143.55 − 14.355 = 228.195
    assertEq(token.balanceOf(PLAYER2) - beforeB, 228.195e18);
    assertTrue(vault.solvent());
  }

  function test_LateEntryAfterBreachIsRefunded() public {
    uint256 pidS = _openDefault(GameState.Side.Survive, PLAYER);
    _bind(pidS, 80_000e18, 0.5e18);
    uint256 channelId = game.getPosition(pidS).channelId;

    // a second request AFTER the breach moment (the breach isn't marked on-chain yet)
    vm.warp(block.timestamp + 2 hours);
    (ChannelGame.VolatilityQuote memory q, bytes memory sig) = _quote(0.0007e18);
    ChannelGame.OpenRequest memory r;
    r.channelId = channelId;
    r.side = GameState.Side.Survive;
    r.deposit = 100e18;
    r.owner = PLAYER2;
    r.quote = q;
    r.quoteSignature = sig;
    vm.prank(PLAYER2);
    uint256 pidLate = game.openPosition(r);

    // breach an hour before the request
    _breachEntry(channelId, 80_900e18, uint32(block.timestamp - 1 hours));

    // the operator binds the late request — the contract cancels it with a refund of deposit − fixed fee
    uint256 before = token.balanceOf(PLAYER2);
    _bind(pidLate, 80_000e18, 0.5e18);
    assertEq(uint8(game.getPosition(pidLate).status), uint8(GameState.PositionStatus.Cancelled));
    assertEq(token.balanceOf(PLAYER2) - before, 99.5e18);
    assertTrue(vault.solvent());
  }

  // ----------------- refund after the settlement window -----------------

  function test_RefundStaleByOwnerAfterWindow() public {
    uint256 pid = _openDefault(GameState.Side.Survive, PLAYER);
    _bind(pid, 80_000e18, 0.5e18);
    GameState.Position memory p = game.getPosition(pid);
    uint64 endTs = game.getChannel(p.channelId).endTs;

    vm.prank(PLAYER);
    vm.expectRevert();
    game.refundStale(pid); // the window hasn't expired yet

    vm.warp(uint256(endTs) + 7 days + 1);
    uint256 before = token.balanceOf(PLAYER);
    vm.prank(PLAYER); // only the position owner (ADR-0002, note)
    game.refundStale(pid);
    assertEq(token.balanceOf(PLAYER) - before, 99.5e18);
    assertEq(uint8(game.getPosition(pid).status), uint8(GameState.PositionStatus.Refunded));
    assertTrue(vault.solvent());
  }

  // ----------------- royalty and transferability (ADR-0018) -----------------

  function test_RoyaltyClaimAndTransferLock() public {
    uint256 pid = _openDefault(GameState.Side.Survive, PLAYER);
    _bind(pid, 80_000e18, 0.5e18);
    GameState.Position memory p = game.getPosition(pid);
    uint256 channelId = p.channelId;

    // a live channel is transferable
    vm.prank(PLAYER);
    game.transferFrom(PLAYER, PLAYER2, channelId);

    vm.warp(uint256(game.getChannel(channelId).endTs) + 1);
    _settleEntry(pid);

    // claim by a non-owner — rejected
    uint256[] memory ids = new uint256[](1);
    ids[0] = channelId;
    vm.prank(PLAYER);
    vm.expectRevert(abi.encodeWithSelector(ChannelGame.NotChannelOwner.selector, channelId));
    game.claimRoyalties(ids);

    // the owner claims what accrued
    uint256 before = token.balanceOf(PLAYER2);
    vm.prank(PLAYER2);
    game.claimRoyalties(ids);
    assertEq(token.balanceOf(PLAYER2) - before, 1.4256e18);

    // after the claim the token is non-transferable
    vm.prank(PLAYER2);
    vm.expectRevert(abi.encodeWithSelector(ChannelGame.TransferLocked.selector, channelId));
    game.transferFrom(PLAYER2, PLAYER, channelId);

    // a repeat claim — rejected
    vm.prank(PLAYER2);
    vm.expectRevert(abi.encodeWithSelector(ChannelGame.ChannelNotClaimable.selector, channelId));
    game.claimRoyalties(ids);
  }

  /// @dev Royalty accrues on other players' wins only; the owner's own position pays the full fee.
  function test_RoyaltyOnlyOnOtherPlayersPositions() public {
    uint256 pidA = _openDefault(GameState.Side.Survive, PLAYER); // PLAYER owns the channel
    _bind(pidA, 80_000e18, 0.5e18);
    uint256 channelId = game.getPosition(pidA).channelId;
    uint256 pidB = _joinBreachSide(channelId); // PLAYER2, M = 2.45

    // breach: PLAYER2 wins, the owner's own position is liquidated
    _breachEntry(channelId, 80_900e18, uint32(block.timestamp + 10 minutes));
    _settleEntry(pidB);
    _settleEntry(pidA);

    // PLAYER2: stake 99, reward 99 × 1.45 = 143.55, fee 10% = 14.355, royalty 15% = 2.15325
    assertEq(vault.royaltyOf(address(game), channelId), 2.15325e18);
    assertTrue(vault.solvent());
  }

  function test_ClosedChannelWithoutRoyaltyIsLocked() public {
    uint256 pid = _openDefault(GameState.Side.Survive, PLAYER);
    _bind(pid, 80_000e18, 0.5e18);
    uint256 channelId = game.getPosition(pid).channelId;
    // breach → position liquidated, no royalty
    _breachEntry(channelId, 80_900e18, uint32(block.timestamp + 10 minutes));
    _settleEntry(pid);
    assertEq(vault.royaltyOf(address(game), channelId), 0);
    vm.prank(PLAYER);
    vm.expectRevert(abi.encodeWithSelector(ChannelGame.TransferLocked.selector, channelId));
    game.transferFrom(PLAYER, PLAYER2, channelId);
  }

  // ----------------- access -----------------

  function test_OnlyOperatorRunsBatch() public {
    bytes[] memory reports = new bytes[](0);
    GameState.BatchEntry[] memory entries = new GameState.BatchEntry[](0);
    vm.prank(PLAYER);
    vm.expectRevert(ChannelGame.NotOperator.selector);
    game.processBatch(reports, entries);
  }

  // ----------------- close request at a price outside the channel (ADR-0012/0015) -----------------

  function test_SettleCloseOutsideChannelRecordsBreachAndLiquidatesSurvive() public {
    uint256 pid = _openDefault(GameState.Side.Survive, PLAYER);
    _bind(pid, 80_000e18, 0.5e18);
    uint256 channelId = game.getPosition(pid).channelId;
    vm.warp(block.timestamp + 1 hours);
    vm.prank(PLAYER);
    game.requestClose(pid);
    uint64 closeTs = game.getPosition(pid).closeRequestTs;

    uint256 before = token.balanceOf(PLAYER);
    vm.expectEmit(true, false, false, true, address(game));
    emit GameLogic.ChannelBreached(channelId, closeTs, 80_900e18);
    _settleCloseEntry(pid, 80_900e18, 0.01e18); // above the upper bound of 80800

    assertEq(game.getChannel(channelId).breachedAt, closeTs);
    assertEq(uint8(game.getPosition(pid).status), uint8(GameState.PositionStatus.Liquidated));
    assertEq(token.balanceOf(PLAYER), before);
    assertTrue(vault.solvent());
  }

  function test_SettleCloseOutsideChannelPaysBreachSide() public {
    uint256 pidS = _openDefault(GameState.Side.Survive, PLAYER);
    _bind(pidS, 80_000e18, 0.5e18);
    uint256 channelId = game.getPosition(pidS).channelId;
    uint256 pidB = _joinBreachSide(channelId);
    vm.warp(block.timestamp + 1 hours);
    vm.prank(PLAYER2);
    game.requestClose(pidB);

    uint256 before = token.balanceOf(PLAYER2);
    _settleCloseEntry(pidB, 80_900e18, 0.99e18);

    // the same money as a Breach + Settle by outcome (see test_SurviveSideLosesOnBreach_BreachSideWins)
    assertEq(uint8(game.getPosition(pidB).status), uint8(GameState.PositionStatus.Settled));
    assertEq(token.balanceOf(PLAYER2) - before, 228.195e18);
    // the survive side is settled by the same breach afterwards
    _settleEntry(pidS);
    assertEq(uint8(game.getPosition(pidS).status), uint8(GameState.PositionStatus.Liquidated));
    assertTrue(vault.solvent());
  }

  function test_SettleCloseMovesBreachRecordedLaterBackToTheRequest() public {
    uint256 pid = _openDefault(GameState.Side.Survive, PLAYER);
    _bind(pid, 80_000e18, 0.5e18);
    uint256 channelId = game.getPosition(pid).channelId;
    vm.warp(block.timestamp + 1 hours);
    vm.prank(PLAYER);
    game.requestClose(pid);
    uint64 closeTs = game.getPosition(pid).closeRequestTs;

    // the operator noticed the touch ten minutes after the request (the incident of 2026-09-17)
    _breachEntry(channelId, 80_900e18, uint32(closeTs) + 10 minutes);
    assertEq(game.getChannel(channelId).breachedAt, closeTs + 10 minutes);
    _settleEntry(pid); // "close-pending": the breach is after the request
    assertEq(uint8(game.getPosition(pid).status), uint8(GameState.PositionStatus.CloseRequested));

    _settleCloseEntry(pid, 80_900e18, 0.01e18);
    assertEq(game.getChannel(channelId).breachedAt, closeTs);
    assertEq(uint8(game.getPosition(pid).status), uint8(GameState.PositionStatus.Liquidated));
    assertTrue(vault.solvent());
  }

  function test_SettleCloseThenLaterBreachInOneBatchKeepsTheEarlierTouch() public {
    uint256 pid = _openDefault(GameState.Side.Survive, PLAYER);
    _bind(pid, 80_000e18, 0.5e18);
    uint256 channelId = game.getPosition(pid).channelId;
    vm.warp(block.timestamp + 1 hours);
    vm.prank(PLAYER);
    game.requestClose(pid);
    uint64 closeTs = game.getPosition(pid).closeRequestTs;

    bytes[] memory reports = new bytes[](2);
    reports[0] = _report(80_900e18, uint32(closeTs) - 1, uint32(closeTs) + 1);
    reports[1] = _report(80_900e18, uint32(closeTs) + 10 minutes, uint32(closeTs) + 10 minutes);
    GameState.BatchEntry[] memory entries = new GameState.BatchEntry[](2);
    entries[0] = GameState.BatchEntry(GameState.EntryKind.SettleClose, pid, 0, 0.01e18, 0);
    entries[1] = GameState.BatchEntry(GameState.EntryKind.Breach, channelId, 1, 0, 0);
    vm.prank(operator);
    game.processBatch(reports, entries); // the second entry is skipped as "already"

    assertEq(game.getChannel(channelId).breachedAt, closeTs);
    assertEq(uint8(game.getPosition(pid).status), uint8(GameState.PositionStatus.Liquidated));
  }

  function test_MarkBreachMovesEarlierOnAnEarlierProof() public {
    uint256 pid = _openDefault(GameState.Side.Survive, PLAYER);
    _bind(pid, 80_000e18, 0.5e18);
    uint256 channelId = game.getPosition(pid).channelId;
    uint32 later = uint32(block.timestamp + 2 hours);
    uint32 earlier = uint32(block.timestamp + 1 hours);

    _breachEntry(channelId, 80_900e18, later);
    assertEq(game.getChannel(channelId).breachedAt, later);
    _breachEntry(channelId, 80_900e18, earlier);
    assertEq(game.getChannel(channelId).breachedAt, earlier);
    _breachEntry(channelId, 80_900e18, later); // "already": not later than the recorded touch
    assertEq(game.getChannel(channelId).breachedAt, earlier);
  }

  function test_SettleCloseInsideChannelStillClosesByTheFormula() public {
    uint256 pid = _openDefault(GameState.Side.Survive, PLAYER);
    _bind(pid, 80_000e18, 0.5e18);
    uint256 channelId = game.getPosition(pid).channelId;
    vm.warp(block.timestamp + 1 hours);
    vm.prank(PLAYER);
    game.requestClose(pid);

    uint256 before = token.balanceOf(PLAYER);
    _settleCloseEntry(pid, 80_000e18, 0.5e18);

    assertEq(game.getChannel(channelId).breachedAt, 0);
    assertEq(uint8(game.getPosition(pid).status), uint8(GameState.PositionStatus.Settled));
    uint256 payout = token.balanceOf(PLAYER) - before;
    assertGt(payout, 0);
    assertLt(payout, 99e18); // an early close below the working amount
    assertTrue(vault.solvent());
  }

  function test_SettleCloseOutsideChannelInTheEntrySecondRefunds() public {
    // close requested in the same second as the entry: the touch coincides with requestTs → late-entry refund
    uint256 pid = _openDefault(GameState.Side.Survive, PLAYER);
    _bind(pid, 80_000e18, 0.5e18);
    vm.prank(PLAYER);
    game.requestClose(pid);
    assertEq(game.getPosition(pid).closeRequestTs, game.getPosition(pid).requestTs);

    uint256 before = token.balanceOf(PLAYER);
    _settleCloseEntry(pid, 80_900e18, 0.01e18);

    assertEq(uint8(game.getPosition(pid).status), uint8(GameState.PositionStatus.Refunded));
    assertEq(token.balanceOf(PLAYER) - before, 99.5e18);
    assertTrue(vault.solvent());
  }
}
