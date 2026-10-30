// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Vault} from "../vault/Vault.sol";
import {AssetRegistry} from "../assets/AssetRegistry.sol";
import {FreezableToken} from "../mocks/FreezableToken.sol";
import {MockRouter} from "../mocks/MockRouter.sol";
import {ChannelGame} from "./ChannelGame.sol";
import {GameState} from "./GameState.sol";
import {GameLogic} from "./GameLogic.sol";
import {GameEntry} from "./GameEntry.sol";
import {GameAdmin} from "./GameAdmin.sol";
import {ClaimLogic} from "./ClaimLogic.sol";
import {ChannelGameTestBase} from "./ChannelGameTestBase.sol";

/// @dev v3: drawdown allowance and deferred rewards (ADR-0022), USDG as a second currency and the
///      royalty claim with conversion (ADR-0021). The v2 suite runs unchanged in ChannelGame.t.sol.
contract ChannelGameV3Test is ChannelGameTestBase {
  uint8 constant USDG = 1;

  FreezableToken usdg;
  FreezableToken virt;
  Vault usdgVault;
  MockRouter router;

  function setUp() public override {
    super.setUp();

    usdg = new FreezableToken("Global Dollar", "USDG", 6);
    virt = new FreezableToken("Virtual", "VIRTUAL", 18);
    usdgVault = Vault(
      address(new ERC1967Proxy(address(new Vault()), abi.encodeCall(Vault.initialize, (address(access), address(usdg)))))
    );
    vm.prank(ADMIN);
    usdgVault.setGame(address(game));

    // exchange route: a mock router that pays 1 OVER per 1 USDG (1e6 → 1e18), path USDG → VIRTUAL → OVER
    router = new MockRouter();
    router.setRate(1e12, 1);
    token.transfer(address(router), 1_000_000e18);
    address[] memory path = new address[](3);
    path[0] = address(usdg);
    path[1] = address(virt);
    path[2] = address(token);
    vm.startPrank(TIMELOCK);
    game.setRouter(address(router));
    game.addCurrency(address(usdgVault), 5000, 0, path); // 50 % drawdown share, no dust floor
    vm.stopPrank();

    // USDG launch terms on BTC: 0.5 / 50 / fee 0.05 / cap 10×
    vm.prank(ADMIN);
    assets.setCurrencyTerms(BTC, USDG, AssetRegistry.CurrencyTerms(0.5e6, 50e6, 0.05e6, 0, 10e18));

    // USDG capital 2 500 and player balances
    usdg.mint(ADMIN, 1_000_000e6);
    usdg.mint(PLAYER, 1_000e6);
    usdg.mint(PLAYER2, 1_000e6);
    vm.startPrank(ADMIN);
    usdg.approve(address(usdgVault), type(uint256).max);
    usdgVault.depositCapital(2_500e6);
    vm.stopPrank();
    vm.prank(PLAYER);
    usdg.approve(address(usdgVault), type(uint256).max);
    vm.prank(PLAYER2);
    usdg.approve(address(usdgVault), type(uint256).max);
  }

  // ----------------- helpers -----------------

  /// @dev Like _openDefault, in USDG: ±1 % around the entry price, sideways, 4 hours.
  function _openIn(GameState.Side side, address player, uint128 deposit) internal returns (uint256 positionId) {
    (ChannelGame.VolatilityQuote memory q, bytes memory sig) = _quote(0.0007e18);
    ChannelGame.OpenRequest memory r;
    r.newChannel = ChannelGame.NewChannel(BTC, 0, uint64(block.timestamp + 4 hours), 0, 0.02e18, 0, true, player);
    r.side = side;
    r.deposit = deposit;
    r.owner = player;
    r.quote = q;
    r.quoteSignature = sig;
    (uint64 pd, bytes memory ps) = _permitFor(player, USDG);
    vm.prank(player);
    positionId = game.openPositionIn(r, USDG, pd, ps);
  }

  /// @dev PLAYER2 joins a channel on the "breaches" side in USDG; bound at 80100 with P 0.6 (M = 2.45).
  function _joinBreachSideIn(uint256 channelId, uint128 deposit) internal returns (uint256 pidB) {
    (ChannelGame.VolatilityQuote memory q, bytes memory sig) = _quote(0.0007e18);
    ChannelGame.OpenRequest memory r;
    r.channelId = channelId;
    r.side = GameState.Side.Breach;
    r.deposit = deposit;
    r.owner = PLAYER2;
    r.quote = q;
    r.quoteSignature = sig;
    vm.warp(block.timestamp + 60);
    (uint64 pd, bytes memory ps) = _permitFor(PLAYER2, USDG);
    vm.prank(PLAYER2);
    pidB = game.openPositionIn(r, USDG, pd, ps);
    _bind(pidB, 80_100e18, 0.6e18);
  }

  function _ids(uint256 id) internal pure returns (uint256[] memory ids) {
    ids = new uint256[](1);
    ids[0] = id;
  }

  function _expire(uint256 pid) internal {
    vm.warp(uint256(game.getChannel(game.getPosition(pid).channelId).endTs) + 1);
  }

  // ----------------- v2 compatibility -----------------

  function test_V2OpenPositionIsCurrencyZero() public {
    vm.expectEmit(true, true, false, false, address(game));
    emit GameEntry.PositionCurrency(1, 0);
    uint256 pid = _openDefault(GameState.Side.Survive, PLAYER);
    assertEq(game.getPosition(pid).currencyId, 0);
    (address v0,,,) = game.currencyInfo(0);
    (address v1, address t1,,) = game.currencyInfo(USDG);
    assertEq(v0, address(vault));
    assertEq(v1, address(usdgVault));
    assertEq(t1, address(usdg));
    assertEq(game.currencyCount(), 2);
  }

  // ----------------- drawdown allowance (ADR-0022) -----------------

  function test_WinDrainsAllowance() public {
    // capital 500 000 × 5 % = 25 000 capacity, untouched = full
    (uint256 rem, uint256 cap) = game.allowanceRemaining(0);
    assertEq(cap, 25_000e18);
    assertEq(rem, 25_000e18);

    uint256 pid = _openDefault(GameState.Side.Survive, PLAYER);
    _bind(pid, 80_000e18, 0.5e18); // M = 1.96 → reward 95.04
    _expire(pid);
    _settleEntry(pid);
    assertEq(uint8(game.getPosition(pid).status), uint8(GameState.PositionStatus.Settled));
    (rem,) = game.allowanceRemaining(0);
    assertEq(rem, 25_000e18 - 95.04e18);
    assertFalse(game.paused());
  }

  function test_RewardAboveAllowanceDefersAndPauses_ThenApprove() public {
    uint256 pid = _openDefault(GameState.Side.Survive, PLAYER);
    _bind(pid, 80_000e18, 0.5e18); // reward 95.04
    // shrink the share to 0.01 %: capacity 50 < 95.04
    vm.prank(ADMIN);
    game.setCurrencyParams(0, 1, 0);
    _expire(pid);

    uint256 before = token.balanceOf(PLAYER);
    vm.expectEmit(true, true, false, true, address(game));
    emit GameLogic.AllowanceExhausted(0, pid, 95.04e18, 50e18);
    _settleEntry(pid);

    GameState.Position memory p = game.getPosition(pid);
    assertEq(uint8(p.status), uint8(GameState.PositionStatus.RewardDeferred));
    assertEq(token.balanceOf(PLAYER) - before, 99e18); // the working amount, at once
    assertEq(p.reserved, 95.04e18); // the reward stays reserved
    assertEq(vault.reservedTotal(), 95.04e18);
    assertEq(vault.revenue(), 1e18); // opening fee only
    assertTrue(game.paused());
    assertEq(game.deferredCount(), 1);
    assertEq(game.getChannel(p.channelId).openPositions, 1); // still open for the channel
    assertTrue(vault.solvent());

    // intake is closed; unpausing with an undecided reward needs force
    vm.prank(ADMIN);
    vm.expectRevert(abi.encodeWithSelector(ChannelGame.DeferredPending.selector, uint32(1)));
    game.setPaused(false);
    vm.expectRevert(ChannelGame.GamePaused.selector);
    _openDefault(GameState.Side.Survive, PLAYER2);

    // approval: the normal split from the snapshots, nothing drained from the allowance
    vm.prank(PLAYER);
    vm.expectRevert(GameLogic.NotAdmin.selector);
    game.approveRewards(_ids(pid));
    before = token.balanceOf(PLAYER);
    vm.prank(ADMIN);
    vm.expectEmit(true, false, false, true, address(game));
    emit GameLogic.RewardApproved(pid, 85.536e18, 9.504e18, 0);
    game.approveRewards(_ids(pid));
    assertEq(token.balanceOf(PLAYER) - before, 85.536e18); // 95.04 − 10 % fee
    p = game.getPosition(pid);
    assertEq(uint8(p.status), uint8(GameState.PositionStatus.Settled));
    assertEq(p.reserved, 0);
    assertEq(vault.reservedTotal(), 0);
    assertEq(vault.revenue(), 10.504e18); // own channel: the whole fee is revenue
    assertEq(game.deferredCount(), 0);
    assertEq(game.getChannel(p.channelId).openPositions, 0);
    // approved rewards do not drain the bucket; the capacity itself follows the smaller capital
    (uint256 rem, uint256 cap) = game.allowanceRemaining(0);
    assertEq(cap, (500_000e18 - 95.04e18) / 10_000);
    assertEq(rem, cap);
    assertTrue(vault.solvent());

    vm.prank(ADMIN);
    game.setPaused(false);
    assertFalse(game.paused());
  }

  function test_RejectReturnsReserveToFreeCapital() public {
    uint256 pid = _openDefault(GameState.Side.Survive, PLAYER);
    _bind(pid, 80_000e18, 0.5e18);
    vm.prank(ADMIN);
    game.setCurrencyParams(0, 1, 0);
    _expire(pid);
    _settleEntry(pid);
    assertEq(uint8(game.getPosition(pid).status), uint8(GameState.PositionStatus.RewardDeferred));

    uint256 before = token.balanceOf(PLAYER);
    vm.prank(ADMIN);
    vm.expectEmit(true, false, false, true, address(game));
    emit GameLogic.RewardRejected(pid, "admin");
    game.rejectRewards(_ids(pid));
    assertEq(token.balanceOf(PLAYER), before); // the working amount was already paid; nothing more
    assertEq(uint8(game.getPosition(pid).status), uint8(GameState.PositionStatus.RewardRejected));
    assertEq(game.getPosition(pid).reserved, 0);
    assertEq(vault.freeCapital(), 500_000e18); // the reserve is free capital again
    assertEq(game.deferredCount(), 0);
    assertTrue(vault.solvent());

    // a second decision on the same position is a no-op
    vm.prank(ADMIN);
    game.approveRewards(_ids(pid));
    assertEq(uint8(game.getPosition(pid).status), uint8(GameState.PositionStatus.RewardRejected));
  }

  /// @dev A "survives" win settles only after the operator's attestation, and the attestation is final
  ///      (audit 2026-10-19): a breach proof arriving after the deferral is refused and the win stands.
  function test_BreachProofAfterSurvivalAttestationIsRefusedAndTheDeferredWinStands() public {
    uint256 pid = _openDefault(GameState.Side.Survive, PLAYER);
    _bind(pid, 80_000e18, 0.5e18);
    uint64 requestTs = game.getPosition(pid).requestTs;
    uint256 channelId = game.getPosition(pid).channelId;

    vm.prank(GUARDIAN);
    game.setPaused(true);
    _expire(pid);
    _settleEntry(pid); // attested survived, a win on expiry deferred by the pause
    assertEq(uint8(game.getPosition(pid).status), uint8(GameState.PositionStatus.RewardDeferred));

    vm.expectEmit(true, false, false, true, address(game));
    emit ChannelGame.BatchEntrySkipped(channelId, uint8(GameState.EntryKind.Breach), "survived");
    _breachEntry(channelId, 80_900e18, uint32(requestTs + 1 hours));
    assertEq(game.getChannel(channelId).breachedAt, 0);

    uint256 reward = game.getPosition(pid).reserved;
    uint256 before = token.balanceOf(PLAYER);
    vm.prank(ADMIN);
    game.approveRewards(_ids(pid));
    assertEq(token.balanceOf(PLAYER) - before, reward - reward / 10); // minus the 10 % profit fee
    assertEq(uint8(game.getPosition(pid).status), uint8(GameState.PositionStatus.Settled));
    assertEq(vault.reservedTotal(), 0);
    assertTrue(vault.solvent());
  }

  /// @dev Without the attestation the paused game cannot settle a "survives" position at all, so a
  ///      breach proof that arrives late still decides it: the survive side loses.
  function test_LateBreachProofBeforeAttestationDecidesTheOutcome() public {
    uint256 pid = _openDefault(GameState.Side.Survive, PLAYER);
    _bind(pid, 80_000e18, 0.5e18);
    uint64 requestTs = game.getPosition(pid).requestTs;
    uint256 channelId = game.getPosition(pid).channelId;

    vm.prank(GUARDIAN);
    game.setPaused(true);
    _expire(pid);
    vm.expectEmit(true, false, false, true, address(game));
    emit ChannelGame.BatchEntrySkipped(pid, uint8(GameState.EntryKind.Settle), "not-final");
    _settleOnlyEntry(pid);

    _breachEntry(channelId, 80_900e18, uint32(requestTs + 1 hours));
    uint256 before = token.balanceOf(PLAYER);
    _settleEntry(pid);
    assertEq(token.balanceOf(PLAYER), before);
    assertEq(uint8(game.getPosition(pid).status), uint8(GameState.PositionStatus.Liquidated));
    assertEq(vault.reservedTotal(), 0);
    assertTrue(vault.solvent());
  }

  function test_BreachProofRefusedAfterSettlementWindow() public {
    uint256 pid = _openDefault(GameState.Side.Survive, PLAYER);
    _bind(pid, 80_000e18, 0.5e18);
    uint64 requestTs = game.getPosition(pid).requestTs;
    uint256 channelId = game.getPosition(pid).channelId;
    vm.warp(uint256(game.getChannel(channelId).endTs) + 7 days + 1);
    bytes[] memory reports = new bytes[](1);
    reports[0] = _report(80_900e18, uint32(requestTs + 1 hours), uint32(requestTs + 1 hours));
    GameState.BatchEntry[] memory entries = new GameState.BatchEntry[](1);
    entries[0] = GameState.BatchEntry(GameState.EntryKind.Breach, channelId, 0, 0, 0);
    vm.prank(operator);
    vm.expectEmit(true, false, false, true, address(game));
    emit ChannelGame.BatchEntrySkipped(channelId, uint8(GameState.EntryKind.Breach), "late");
    game.processBatch(reports, entries);
    assertEq(game.getChannel(channelId).breachedAt, 0);
  }

  function test_LossRefillsAllowanceUpToCapacity() public {
    vm.prank(ADMIN);
    game.setCurrencyParams(0, 10, 0); // 0.1 % → capacity 500
    uint256 pidWin = _openDefault(GameState.Side.Survive, PLAYER);
    _bind(pidWin, 80_000e18, 0.5e18);
    _expire(pidWin);
    _settleEntry(pidWin);
    (uint256 rem,) = game.allowanceRemaining(0);
    assertEq(rem, 500e18 - 95.04e18);

    // a loss: the working amount (99) enters capital and refills the bucket, clamped at capacity
    uint256 pidLoss = _openDefault(GameState.Side.Survive, PLAYER2);
    _bind(pidLoss, 80_000e18, 0.5e18);
    uint256 channelId = game.getPosition(pidLoss).channelId;
    _breachEntry(channelId, 80_900e18, uint32(block.timestamp + 10 minutes));
    _settleEntry(pidLoss);
    assertEq(uint8(game.getPosition(pidLoss).status), uint8(GameState.PositionStatus.Liquidated));
    assertEq(vault.capital(), 500_000e18 - 95.04e18 + 99e18);
    assertEq(vault.revenue(), 1e18 + 10.504e18); // two opening fees + the win's profit fee (own channel)
    (rem,) = game.allowanceRemaining(0);
    // capacity now 0.1 % of the new capital; 404.96 + 99 exceeds it → full
    assertEq(rem, (500_000e18 - 95.04e18 + 99e18) / 1000);
    assertTrue(vault.solvent());
  }

  function test_TimeRefillsAllowanceLinearly() public {
    vm.prank(ADMIN);
    game.setCurrencyParams(0, 10, 0); // capacity 500
    uint256 pid = _openDefault(GameState.Side.Survive, PLAYER);
    _bind(pid, 80_000e18, 0.5e18);
    _expire(pid);
    _settleEntry(pid);
    (uint256 rem, uint256 cap) = game.allowanceRemaining(0);
    assertEq(rem, 500e18 - 95.04e18);

    vm.warp(block.timestamp + 2 hours); // 1/12 of the capacity comes back
    (rem, cap) = game.allowanceRemaining(0);
    assertApproxEqAbs(rem, 500e18 - 95.04e18 + cap / 12, 1e6);

    vm.warp(block.timestamp + 1 days); // never above capacity
    (rem, cap) = game.allowanceRemaining(0);
    assertEq(rem, cap);
  }

  function test_ZeroShareDefersWithoutPausingAndClosesIntake() public {
    uint256 pid = _openDefault(GameState.Side.Survive, PLAYER);
    _bind(pid, 80_000e18, 0.5e18);
    vm.prank(ADMIN);
    game.setCurrencyParams(0, 0, 0);

    vm.expectRevert(abi.encodeWithSelector(GameEntry.CurrencyNotAccepted.selector, BTC, uint8(0)));
    _openDefault(GameState.Side.Survive, PLAYER2);

    _expire(pid);
    _settleEntry(pid);
    assertEq(uint8(game.getPosition(pid).status), uint8(GameState.PositionStatus.RewardDeferred));
    assertFalse(game.paused());
    assertEq(game.deferredCount(), 1);
  }

  function test_UnpauseDoesNotRefill_RefillIsExplicit() public {
    vm.prank(ADMIN);
    game.setCurrencyParams(0, 10, 0); // capacity 500
    uint256 pid1 = _openDefault(GameState.Side.Survive, PLAYER);
    _bind(pid1, 80_000e18, 0.5e18);
    _expire(pid1);
    _settleEntry(pid1); // remainder 404.96

    // a long shot: P 0.1 → M 9.8 → reward 871.2 > remainder → trip
    uint256 pid2 = _openDefault(GameState.Side.Survive, PLAYER2);
    _bind(pid2, 80_000e18, 0.1e18);
    _expire(pid2);
    _settleEntry(pid2);
    assertTrue(game.paused());
    assertEq(uint8(game.getPosition(pid2).status), uint8(GameState.PositionStatus.RewardDeferred));
    (uint256 atTrip, uint256 cap) = game.allowanceRemaining(0);
    assertLt(atTrip, cap); // the trip itself drained nothing, but the bucket is not full

    vm.prank(ADMIN);
    game.rejectRewards(_ids(pid2));
    vm.prank(ADMIN);
    game.setPaused(false);
    (uint256 rem,) = game.allowanceRemaining(0);
    assertEq(rem, atTrip); // untouched by the decision and the unpause (same block: no time refill)

    vm.prank(GUARDIAN);
    vm.expectRevert(GameLogic.NotAdmin.selector);
    game.refillAllowance(0);
    vm.prank(ADMIN);
    vm.expectEmit(true, false, false, true, address(game));
    emit GameLogic.AllowanceRefilled(0, cap);
    game.refillAllowance(0);
    (rem,) = game.allowanceRemaining(0);
    assertEq(rem, cap);
  }

  function test_ForceUnpauseIsAdminOnly() public {
    uint256 pid = _openDefault(GameState.Side.Survive, PLAYER);
    _bind(pid, 80_000e18, 0.5e18);
    vm.prank(GUARDIAN);
    game.setPaused(true);
    _expire(pid);
    _settleEntry(pid);
    assertEq(game.deferredCount(), 1);
    vm.prank(GUARDIAN);
    vm.expectRevert(ChannelGame.NotAdmin.selector);
    game.forceUnpause();
    vm.prank(ADMIN);
    game.forceUnpause();
    assertFalse(game.paused());
    assertEq(game.deferredCount(), 1); // the decision is still pending
  }

  function test_EarlyCloseAboveStakeDefersOnlyTheExcess() public {
    uint256 pid = _openDefault(GameState.Side.Survive, PLAYER);
    _bind(pid, 80_000e18, 0.5e18); // M 1.96, reserve 95.04
    vm.warp(block.timestamp + 30 minutes);
    vm.prank(PLAYER);
    game.requestClose(pid);
    vm.prank(GUARDIAN);
    game.setPaused(true);

    // V = 99 × 1.96 × 0.9 × 0.95 = 165.9042 → above the stake by 66.9042
    uint256 before = token.balanceOf(PLAYER);
    _settleCloseEntry(pid, 80_050e18, 0.9e18);
    assertEq(token.balanceOf(PLAYER) - before, 99e18);
    GameState.Position memory p = game.getPosition(pid);
    assertEq(uint8(p.status), uint8(GameState.PositionStatus.RewardDeferred));
    assertEq(p.reserved, 66.9042e18); // the excess reserve was released at settlement
    assertEq(vault.reservedTotal(), 66.9042e18);
    assertTrue(vault.solvent());

    vm.prank(ADMIN);
    game.approveRewards(_ids(pid));
    assertEq(token.balanceOf(PLAYER) - before, 99e18 + 60.21378e18); // 66.9042 − 10 %
    assertEq(vault.reservedTotal(), 0);
  }

  // ----------------- USDG (ADR-0021) -----------------

  function test_OpenPositionInUsdgReservesFromUsdgVault() public {
    vm.expectEmit(true, true, false, false, address(game));
    emit GameEntry.PositionCurrency(1, USDG);
    uint256 pid = _openIn(GameState.Side.Survive, PLAYER, 50e6);
    GameState.Position memory p = game.getPosition(pid);
    assertEq(p.currencyId, USDG);
    assertEq(p.stake, 49.5e6); // fee max(1 % = 0.5, 0.05) = 0.5
    assertEq(p.reserved, 445.5e6); // 49.5 × (10 − 1)
    assertEq(p.ceilingWad, 10e18);
    assertEq(usdgVault.heldDeposits(), 50e6);
    assertEq(usdgVault.reservedTotal(), 445.5e6);
    assertEq(vault.heldDeposits(), 0); // the OVER vault saw nothing
    assertEq(vault.reservedTotal(), 0);
    assertTrue(usdgVault.solvent());
  }

  function test_UsdgTermsGateDepositsAndFloor() public {
    (ChannelGame.VolatilityQuote memory q, bytes memory sig) = _quote(0.0007e18);
    ChannelGame.OpenRequest memory r;
    r.newChannel = ChannelGame.NewChannel(BTC, 0, uint64(block.timestamp + 4 hours), 0, 0.02e18, 0, true, PLAYER);
    r.side = GameState.Side.Survive;
    r.owner = PLAYER;
    r.quote = q;
    r.quoteSignature = sig;
    (uint64 pd, bytes memory ps) = _permitFor(PLAYER, USDG);

    r.deposit = 51e6; // above the USDG maximum
    vm.prank(PLAYER);
    vm.expectRevert(abi.encodeWithSelector(GameEntry.BadDeposit.selector, uint128(51e6)));
    game.openPositionIn(r, USDG, pd, ps);

    r.deposit = 50e6;
    r.minMultiplierWad = 11e18; // floor above the USDG cap
    vm.prank(PLAYER);
    vm.expectRevert(abi.encodeWithSelector(GameEntry.MultiplierFloorTooHigh.selector, uint128(11e18), uint128(10e18)));
    game.openPositionIn(r, USDG, pd, ps);

    r.minMultiplierWad = 0;
    (uint64 pd5, bytes memory ps5) = _permitFor(PLAYER, 5);
    vm.prank(PLAYER);
    vm.expectRevert(abi.encodeWithSelector(GameEntry.UnknownCurrency.selector, uint8(5)));
    game.openPositionIn(r, 5, pd5, ps5);

    // closing the USDG terms closes USDG intake on this asset; OVER is unaffected
    AssetRegistry.CurrencyTerms memory closed;
    vm.prank(ADMIN);
    assets.setCurrencyTerms(BTC, USDG, closed);
    vm.prank(PLAYER);
    vm.expectRevert(abi.encodeWithSelector(GameEntry.CurrencyNotAccepted.selector, BTC, USDG));
    game.openPositionIn(r, USDG, pd, ps);
    _openDefault(GameState.Side.Survive, PLAYER);
  }

  function test_UsdgWinPaysUsdgAndDrainsUsdgAllowance() public {
    uint256 pid = _openIn(GameState.Side.Survive, PLAYER, 50e6);
    _bindD(pid, 80_000e18, 0.5e18, 0.05e18); // M = 0.95 / 0.5 = 1.9 → reward 44.55
    assertEq(game.getPosition(pid).reserved, 44.55e6);
    assertEq(usdgVault.reservedTotal(), 44.55e6);

    _expire(pid);
    uint256 before = usdg.balanceOf(PLAYER);
    _settleEntry(pid);
    assertEq(usdg.balanceOf(PLAYER) - before, 89.595e6); // 49.5 + 44.55 − 4.455
    assertEq(usdgVault.revenue(), 4.955e6); // 0.5 opening + 4.455 profit fee (own channel)
    assertEq(usdgVault.capital(), 2_500e6 - 44.55e6);
    assertEq(usdgVault.reservedTotal(), 0);
    (uint256 rem,) = game.allowanceRemaining(USDG);
    assertEq(rem, 1_250e6 - 44.55e6);
    assertEq(token.balanceOf(address(vault)), 500_000e18); // the OVER vault: untouched
    assertTrue(usdgVault.solvent());
  }

  function test_UsdgLossGoesToUsdgCapital() public {
    uint256 pid = _openIn(GameState.Side.Survive, PLAYER, 50e6);
    _bind(pid, 80_000e18, 0.5e18);
    uint256 channelId = game.getPosition(pid).channelId;
    _breachEntry(channelId, 80_900e18, uint32(block.timestamp + 10 minutes));
    uint256 before = usdg.balanceOf(PLAYER);
    _settleEntry(pid);
    assertEq(uint8(game.getPosition(pid).status), uint8(GameState.PositionStatus.Liquidated));
    assertEq(usdg.balanceOf(PLAYER), before);
    assertEq(usdgVault.capital(), 2_500e6 + 49.5e6);
    assertEq(usdgVault.revenue(), 0.5e6);
    assertTrue(usdgVault.solvent());
  }

  function test_FrozenUsdgWinnerIsOwedAndCollectsLater() public {
    uint256 pid = _openIn(GameState.Side.Survive, PLAYER, 50e6);
    _bindD(pid, 80_000e18, 0.5e18, 0.05e18);
    _expire(pid);
    usdg.freeze(PLAYER);
    uint256 before = usdg.balanceOf(PLAYER);
    _settleEntry(pid); // the batch does not revert
    assertEq(uint8(game.getPosition(pid).status), uint8(GameState.PositionStatus.Settled));
    assertEq(usdg.balanceOf(PLAYER), before);
    assertEq(usdgVault.owedOf(PLAYER), 89.595e6);
    assertTrue(usdgVault.solvent());
    usdg.unfreeze(PLAYER);
    vm.prank(PLAYER);
    usdgVault.withdrawOwed();
    assertEq(usdg.balanceOf(PLAYER) - before, 89.595e6);
  }

  // ----------------- royalty claim with conversion (ADR-0021) -----------------

  /// @dev PLAYER owns a channel; PLAYER2 wins in USDG on the "breaches" side → USDG royalty for PLAYER.
  function _usdgRoyaltyChannel(uint128 deposit) internal returns (uint256 channelId, uint256 royalty) {
    uint256 pidA = _openIn(GameState.Side.Survive, PLAYER, 50e6);
    _bind(pidA, 80_000e18, 0.5e18);
    channelId = game.getPosition(pidA).channelId;
    uint256 pidB = _joinBreachSideIn(channelId, deposit);
    _breachEntry(channelId, 80_900e18, uint32(block.timestamp + 10 minutes));
    _settleEntry(pidB);
    _settleEntry(pidA);
    royalty = usdgVault.royaltyOf(address(game), channelId);
    assertEq(game.getChannel(channelId).openPositions, 0);
  }

  function test_ClaimUsdgRoyaltyIsConvertedToOver() public {
    // PLAYER2: deposit 50 → stake 49.5, M 2.45 → reward 71.775, fee 7.1775, royalty 15 % = 1.076625 USDG
    (uint256 channelId, uint256 royalty) = _usdgRoyaltyChannel(50e6);
    assertEq(royalty, 1.076625e6);
    assertEq(vault.royaltyOf(address(game), channelId), 0); // nothing in OVER

    // a non-owner cannot claim; a too-high minimum output reverts in the route, nothing is marked
    vm.prank(PLAYER2);
    vm.expectRevert(abi.encodeWithSelector(ClaimLogic.NotChannelOwner.selector, channelId));
    game.claimRoyaltiesIn(_ids(channelId), USDG, 0, block.timestamp);
    vm.prank(PLAYER);
    vm.expectRevert(abi.encodeWithSelector(MockRouter.InsufficientOutput.selector, 1.076625e18, 2e18));
    game.claimRoyaltiesIn(_ids(channelId), USDG, 2e18, block.timestamp);
    assertEq(game.getChannel(channelId).claimedOthers, 0);

    uint256 overBefore = token.balanceOf(PLAYER);
    uint256 usdgBefore = usdg.balanceOf(PLAYER);
    vm.prank(PLAYER);
    vm.expectEmit(true, true, false, true, address(game));
    emit ClaimLogic.RoyaltyConverted(PLAYER, USDG, 1.076625e6, 1.076625e18);
    game.claimRoyaltiesIn(_ids(channelId), USDG, 1e18, block.timestamp);
    assertEq(token.balanceOf(PLAYER) - overBefore, 1.076625e18); // OVER arrived, at the mock rate
    assertEq(usdg.balanceOf(PLAYER), usdgBefore); // no USDG
    assertEq(usdg.balanceOf(address(game)), 0); // the game holds nothing afterward
    assertEq(router.lastAmountIn(), 1.076625e6);
    assertEq(router.lastPath(1), address(virt)); // the configured two-hop path was used
    assertEq(game.getChannel(channelId).claimedOthers, 1); // bit 0 = currency 1
    assertFalse(game.getChannel(channelId).royaltyClaimed);
    assertEq(usdgVault.royaltyOf(address(game), channelId), 0);

    // a repeat USDG claim is refused; the OVER claim pays zero and sets its own bit
    vm.prank(PLAYER);
    vm.expectRevert(abi.encodeWithSelector(ClaimLogic.ChannelNotClaimable.selector, channelId));
    game.claimRoyaltiesIn(_ids(channelId), USDG, 0, block.timestamp);
    vm.prank(PLAYER);
    game.claimRoyalties(_ids(channelId));
    assertTrue(game.getChannel(channelId).royaltyClaimed);
    vm.prank(PLAYER);
    vm.expectRevert(abi.encodeWithSelector(ChannelGame.TransferLocked.selector, channelId));
    game.transferFrom(PLAYER, PLAYER2, channelId);
  }

  function test_ChannelStaysTransferableWhileUsdgRoyaltyUnclaimed() public {
    (uint256 channelId,) = _usdgRoyaltyChannel(50e6);
    // OVER account empty and claimed, USDG account still holds value → the token is still an asset
    vm.prank(PLAYER);
    game.claimRoyalties(_ids(channelId));
    vm.prank(PLAYER);
    game.transferFrom(PLAYER, PLAYER2, channelId);
    assertEq(game.ownerOf(channelId), PLAYER2);
    // the buyer claims the USDG royalty
    uint256 before = token.balanceOf(PLAYER2);
    vm.prank(PLAYER2);
    game.claimRoyaltiesIn(_ids(channelId), USDG, 0, block.timestamp);
    assertEq(token.balanceOf(PLAYER2) - before, 1.076625e18);
  }

  function test_DustRoyaltyIsPaidRawNotConverted() public {
    vm.prank(ADMIN);
    game.setCurrencyParams(USDG, 5000, 1e6); // dust floor: 1 USDG
    // PLAYER2 deposit 10 → fee max(0.1, 0.05) = 0.1, stake 9.9, reward 14.355, fee 1.4355, royalty 0.215325
    (uint256 channelId, uint256 royalty) = _usdgRoyaltyChannel(10e6);
    assertEq(royalty, 0.215325e6);
    uint256 usdgBefore = usdg.balanceOf(PLAYER);
    uint256 overBefore = token.balanceOf(PLAYER);
    vm.prank(PLAYER);
    vm.expectEmit(true, true, false, true, address(game));
    emit ClaimLogic.RoyaltyConverted(PLAYER, USDG, 0.215325e6, 0);
    game.claimRoyaltiesIn(_ids(channelId), USDG, 0, block.timestamp);
    assertEq(usdg.balanceOf(PLAYER) - usdgBefore, 0.215325e6);
    assertEq(token.balanceOf(PLAYER), overBefore);
    assertEq(router.lastAmountIn(), 0); // the route was not touched
  }

  function test_DeadRouteBlocksOnlyTheUsdgClaim() public {
    (uint256 channelId,) = _usdgRoyaltyChannel(50e6);
    router.setBroken(true);
    vm.prank(PLAYER);
    vm.expectRevert(MockRouter.Broken.selector);
    game.claimRoyaltiesIn(_ids(channelId), USDG, 0, block.timestamp);
    assertEq(game.getChannel(channelId).claimedOthers, 0);
    assertEq(usdgVault.royaltyOf(address(game), channelId), 1.076625e6); // still waiting in the vault
    vm.prank(PLAYER);
    game.claimRoyalties(_ids(channelId)); // OVER side unaffected
    assertTrue(game.getChannel(channelId).royaltyClaimed);
  }

  // ----------------- audit fixes (2026-10-09) -----------------

  function test_DeferralEmitsPositionSettledForV2Indexers() public {
    uint256 pid = _openDefault(GameState.Side.Survive, PLAYER);
    _bind(pid, 80_000e18, 0.5e18);
    vm.prank(GUARDIAN);
    game.setPaused(true);
    _expire(pid);
    vm.expectEmit(true, false, false, true, address(game));
    emit GameLogic.PositionSettled(pid, uint8(GameState.PositionStatus.RewardDeferred), 99e18);
    _settleEntry(pid);
  }

  function test_ApproveRefusesBreachSideWhenChannelWasDeadAtEntry() public {
    uint256 pidA = _openDefault(GameState.Side.Survive, PLAYER); // anchors the channel at T0
    _bind(pidA, 80_000e18, 0.5e18);
    uint64 t0 = game.getPosition(pidA).requestTs;
    uint256 channelId = game.getPosition(pidA).channelId;
    uint256 pidB = _joinBreachSide(channelId); // "breaches" side, requested at T0 + 60

    _breachEntry(channelId, 80_900e18, uint32(t0 + 600)); // a breach after B's entry: B wins
    vm.prank(GUARDIAN);
    game.setPaused(true);
    _settleEntry(pidB);
    assertEq(uint8(game.getPosition(pidB).status), uint8(GameState.PositionStatus.RewardDeferred));

    // an earlier touch, before B's request, is proven: the channel was dead when B entered
    _breachEntry(channelId, 80_900e18, uint32(t0 + 30));
    assertEq(game.getChannel(channelId).breachedAt, t0 + 30);

    vm.prank(ADMIN);
    vm.expectEmit(true, false, false, true, address(game));
    emit GameLogic.RewardRejected(pidB, "outcome");
    game.approveRewards(_ids(pidB));
    assertEq(uint8(game.getPosition(pidB).status), uint8(GameState.PositionStatus.RewardRejected));
    assertTrue(vault.solvent());
  }

  function test_LateSettleCloseDoesNotMoveTheBreach() public {
    uint256 pid = _openDefault(GameState.Side.Survive, PLAYER);
    _bind(pid, 80_000e18, 0.5e18);
    vm.warp(block.timestamp + 30 minutes);
    vm.prank(PLAYER);
    game.requestClose(pid);
    uint256 channelId = game.getPosition(pid).channelId;
    vm.warp(uint256(game.getChannel(channelId).endTs) + 7 days + 1);

    GameState.Position memory p = game.getPosition(pid);
    bytes[] memory reports = new bytes[](1);
    reports[0] = _report(80_900e18, uint32(p.closeRequestTs) - 1, uint32(p.closeRequestTs) + 1); // outside the channel
    GameState.BatchEntry[] memory entries = new GameState.BatchEntry[](1);
    entries[0] = GameState.BatchEntry(GameState.EntryKind.SettleClose, pid, 0, 0.5e18, 0);
    vm.prank(operator);
    vm.expectEmit(true, false, false, true, address(game));
    emit ChannelGame.BatchEntrySkipped(pid, uint8(GameState.EntryKind.SettleClose), "late");
    game.processBatch(reports, entries);
    assertEq(game.getChannel(channelId).breachedAt, 0);
    assertEq(uint8(game.getPosition(pid).status), uint8(GameState.PositionStatus.CloseRequested));
  }

  function test_InitializeV3IsNotOpenToAnyone() public {
    ChannelGame fresh = ChannelGame(
      address(
        new ERC1967Proxy(
          address(new ChannelGame()),
          abi.encodeCall(ChannelGame.initialize, (address(access), address(assets), address(vault), address(verifier), 7 days))
        )
      )
    );
    vm.prank(PLAYER);
    vm.expectRevert(GameAdmin.NotAdmin.selector);
    fresh.initializeV3(1);
    vm.prank(ADMIN);
    fresh.initializeV3(500);
    assertEq(fresh.currencyCount(), 1);
  }

  function test_AddCurrencyRejectsDuplicateVaultOrToken() public {
    address[] memory path = new address[](2);
    path[0] = address(usdg);
    path[1] = address(token);
    vm.prank(TIMELOCK);
    vm.expectRevert(abi.encodeWithSelector(GameAdmin.BadCurrencyParams.selector, "duplicate"));
    game.addCurrency(address(usdgVault), 5000, 0, path); // the same vault again

    Vault second = Vault(
      address(new ERC1967Proxy(address(new Vault()), abi.encodeCall(Vault.initialize, (address(access), address(usdg)))))
    );
    vm.prank(ADMIN);
    second.setGame(address(game));
    vm.prank(TIMELOCK);
    vm.expectRevert(abi.encodeWithSelector(GameAdmin.BadCurrencyParams.selector, "duplicate"));
    game.addCurrency(address(second), 5000, 0, path); // another vault for the same token
  }

  function test_OpenRejectsOwnersThatWouldStrandPayouts() public {
    (ChannelGame.VolatilityQuote memory q, bytes memory sig) = _quote(0.0007e18);
    ChannelGame.OpenRequest memory r;
    r.newChannel = ChannelGame.NewChannel(BTC, 0, uint64(block.timestamp + 4 hours), 0, 0.02e18, 0, true, PLAYER);
    r.side = GameState.Side.Survive;
    r.deposit = 100e18;
    r.quote = q;
    r.quoteSignature = sig;
    address[3] memory bad = [address(vault), address(token), address(game)];
    for (uint256 i = 0; i < 3; i++) {
      r.owner = bad[i];
      vm.prank(PLAYER);
      vm.expectRevert(abi.encodeWithSelector(GameEntry.BadOwner.selector, bad[i]));
      game.openPosition(r);
    }
  }

  // ----------------- currency administration (ADR-0021) -----------------

  function test_AddCurrencyRules() public {
    address[] memory path = new address[](2);
    path[0] = address(usdg);
    path[1] = address(token);
    vm.prank(ADMIN);
    vm.expectRevert(GameAdmin.NotTimelock.selector);
    game.addCurrency(address(usdgVault), 5000, 0, path);

    // a vault not bound to this game
    Vault stray = Vault(
      address(new ERC1967Proxy(address(new Vault()), abi.encodeCall(Vault.initialize, (address(access), address(usdg)))))
    );
    vm.prank(TIMELOCK);
    vm.expectRevert(abi.encodeWithSelector(GameAdmin.VaultNotBound.selector, address(stray)));
    game.addCurrency(address(stray), 5000, 0, path);

    // route path must start with the currency's token and end with OVER
    address[] memory bad = new address[](2);
    bad[0] = address(usdg);
    bad[1] = address(virt);
    vm.prank(ADMIN);
    vm.expectRevert(abi.encodeWithSelector(GameAdmin.BadRoute.selector, "end"));
    game.setRoutePath(USDG, bad);
    bad[0] = address(virt);
    bad[1] = address(token);
    vm.prank(ADMIN);
    vm.expectRevert(abi.encodeWithSelector(GameAdmin.BadRoute.selector, "start"));
    game.setRoutePath(USDG, bad);
    vm.prank(ADMIN);
    game.setRoutePath(USDG, path);
    (,,, address[] memory stored) = game.currencyInfo(USDG);
    assertEq(stored.length, 2);

    // the dust floor is capped at one whole unit of the currency; the router is timelock-only
    vm.prank(ADMIN);
    vm.expectRevert(abi.encodeWithSelector(GameAdmin.BadCurrencyParams.selector, "dust"));
    game.setCurrencyParams(USDG, 5000, 1e6 + 1);
    vm.prank(ADMIN);
    vm.expectRevert(GameAdmin.NotTimelock.selector);
    game.setRouter(address(0xBEEF));
  }

  // ----------------- entry permit (ADR-0023) -----------------

  /// @dev A USDG request for PLAYER, everything valid except the permit under test.
  function _usdgRequest() internal view returns (ChannelGame.OpenRequest memory r) {
    (ChannelGame.VolatilityQuote memory q, bytes memory sig) = _quote(0.0007e18);
    r.newChannel = ChannelGame.NewChannel(BTC, 0, uint64(block.timestamp + 4 hours), 0, 0.02e18, 0, true, PLAYER);
    r.side = GameState.Side.Survive;
    r.deposit = 50e6;
    r.owner = PLAYER;
    r.quote = q;
    r.quoteSignature = sig;
  }

  function test_UsdgNeedsAnEntryPermitByDefault() public {
    ChannelGame.OpenRequest memory r = _usdgRequest();

    vm.prank(PLAYER);
    vm.expectRevert(abi.encodeWithSelector(ChannelGame.PermitExpired.selector, uint64(0)));
    game.openPositionIn(r, USDG, 0, "");
  }

  function test_EntryPermitOpensForItsOwner() public {
    ChannelGame.OpenRequest memory r = _usdgRequest();
    (uint64 pd, bytes memory ps) = _permitFor(PLAYER, USDG);

    vm.prank(PLAYER);
    uint256 pid = game.openPositionIn(r, USDG, pd, ps);

    assertEq(game.getPosition(pid).currencyId, USDG);
    assertEq(game.getPosition(pid).owner, PLAYER);
  }

  function test_EntryPermitCannotServeAnotherOwner() public {
    ChannelGame.OpenRequest memory r = _usdgRequest();
    (uint64 pd, bytes memory ps) = _permitFor(PLAYER2, USDG); // the staker's permit, someone else's position

    vm.prank(PLAYER);
    vm.expectPartialRevert(ChannelGame.PermitSignerNotOperator.selector);
    game.openPositionIn(r, USDG, pd, ps);
  }

  function test_EntryPermitMustComeFromTheOperator() public {
    ChannelGame.OpenRequest memory r = _usdgRequest();
    uint256 strangerPk = 0xD00D;
    uint64 pd = uint64(block.timestamp + 600);
    bytes memory ps = _signPermit(strangerPk, PLAYER, USDG, pd);

    vm.prank(PLAYER);
    vm.expectRevert(abi.encodeWithSelector(ChannelGame.PermitSignerNotOperator.selector, vm.addr(strangerPk)));
    game.openPositionIn(r, USDG, pd, ps);
  }

  function test_EntryPermitExpires() public {
    ChannelGame.OpenRequest memory r = _usdgRequest();
    (uint64 pd, bytes memory ps) = _permitFor(PLAYER, USDG);
    vm.warp(uint256(pd) + 1);
    (r.quote, r.quoteSignature) = _quote(0.0007e18); // a fresh quote: only the permit is stale
    r.newChannel.endTs = uint64(block.timestamp + 4 hours);

    vm.prank(PLAYER);
    vm.expectRevert(abi.encodeWithSelector(ChannelGame.PermitExpired.selector, pd));
    game.openPositionIn(r, USDG, pd, ps);
  }

  function test_AdminOpensACurrencyToEveryone() public {
    vm.prank(PLAYER);
    vm.expectRevert(GameAdmin.NotAdmin.selector);
    game.setCurrencyPermitless(USDG, true);
    vm.prank(ADMIN);
    vm.expectRevert(abi.encodeWithSelector(GameAdmin.UnknownCurrency.selector, uint8(0)));
    game.setCurrencyPermitless(0, true); // OVER never needs a permit

    vm.prank(ADMIN);
    vm.expectEmit(address(game));
    emit GameAdmin.CurrencyAccessSet(USDG, true);
    game.setCurrencyPermitless(USDG, true);

    ChannelGame.OpenRequest memory r = _usdgRequest();
    vm.prank(PLAYER);
    uint256 pid = game.openPositionIn(r, USDG, 0, "");
    assertEq(game.getPosition(pid).currencyId, USDG);
  }

  function test_OverThroughOpenPositionInNeedsNoPermit() public {
    (ChannelGame.VolatilityQuote memory q, bytes memory sig) = _quote(0.0007e18);
    ChannelGame.OpenRequest memory r;
    r.newChannel = ChannelGame.NewChannel(BTC, 0, uint64(block.timestamp + 4 hours), 0, 0.02e18, 0, true, PLAYER);
    r.side = GameState.Side.Survive;
    r.deposit = 100e18;
    r.owner = PLAYER;
    r.quote = q;
    r.quoteSignature = sig;

    vm.prank(PLAYER);
    uint256 pid = game.openPositionIn(r, 0, 0, "");
    assertEq(game.getPosition(pid).currencyId, 0);
  }
}
