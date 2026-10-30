// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Vault} from "../vault/Vault.sol";
import {AssetRegistry} from "../assets/AssetRegistry.sol";
import {TaxedToken} from "../mocks/TaxedToken.sol";
import {ChannelGame} from "./ChannelGame.sol";
import {GameState} from "./GameState.sol";
import {GameLogic} from "./GameLogic.sol";
import {ChannelGameTestBase} from "./ChannelGameTestBase.sol";

/// @dev Fixes from the 2026-10-19 contract audit (0xSimao + Plamen): measured vault inflows (H-01), no
///      bind on a known outcome (H-03), the operator's survival attestation, the report lag bound
///      (M-06), the CloseRequested fallback (M-05) and the channel creation fee cap (M-08).
contract ChannelGameAudit1910Test is ChannelGameTestBase {
  uint8 constant KIND_BIND = uint8(GameState.EntryKind.Bind);
  uint8 constant KIND_SETTLE = uint8(GameState.EntryKind.Settle);
  uint8 constant KIND_SETTLE_CLOSE = uint8(GameState.EntryKind.SettleClose);
  uint8 constant KIND_MARK_SURVIVED = uint8(GameState.EntryKind.MarkSurvived);

  // ----------------- helpers -----------------

  function _bindAt(uint256 positionId, int192 price, uint32 observed) internal {
    GameState.Position memory p = game.getPosition(positionId);
    bytes[] memory reports = new bytes[](1);
    reports[0] = _report(price, uint32(p.requestTs) - 1, observed);
    GameState.BatchEntry[] memory entries = new GameState.BatchEntry[](1);
    entries[0] = GameState.BatchEntry(GameState.EntryKind.Bind, positionId, 0, 0.5e18, 0.02e18);
    vm.prank(operator);
    game.processBatch(reports, entries);
  }

  function _settleCloseAt(uint256 positionId, int192 price, uint32 observed) internal {
    GameState.Position memory p = game.getPosition(positionId);
    bytes[] memory reports = new bytes[](1);
    reports[0] = _report(price, uint32(p.closeRequestTs) - 1, observed);
    GameState.BatchEntry[] memory entries = new GameState.BatchEntry[](1);
    entries[0] = GameState.BatchEntry(GameState.EntryKind.SettleClose, positionId, 0, 0.5e18, 0);
    vm.prank(operator);
    game.processBatch(reports, entries);
  }

  function _expectSkip(uint256 id, uint8 kind, bytes memory reason) internal {
    vm.expectEmit(true, false, false, true, address(game));
    emit ChannelGame.BatchEntrySkipped(id, kind, reason);
  }

  function _endOf(uint256 positionId) internal view returns (uint256) {
    return game.getChannel(game.getPosition(positionId).channelId).endTs;
  }

  function _status(uint256 positionId) internal view returns (uint8) {
    return uint8(game.getPosition(positionId).status);
  }

  function _boundSurvive() internal returns (uint256 pid, uint256 channelId) {
    pid = _openDefault(GameState.Side.Survive, PLAYER);
    _bind(pid, 80_000e18, 0.5e18); // M = 1.96
    channelId = game.getPosition(pid).channelId;
  }

  // ----------------- H-01: the vault books what arrived -----------------

  function _taxedVault() internal returns (TaxedToken taxed, Vault taxedVault) {
    taxed = new TaxedToken();
    taxedVault = Vault(
      address(new ERC1967Proxy(address(new Vault()), abi.encodeCall(Vault.initialize, (address(access), address(taxed)))))
    );
    taxed.transfer(ADMIN, 1_000_000e18);
    taxed.transfer(PLAYER, 1_000e18);
    vm.prank(ADMIN);
    taxed.approve(address(taxedVault), type(uint256).max);
    vm.prank(PLAYER);
    taxed.approve(address(taxedVault), type(uint256).max);
  }

  function test_DepositCapitalRevertsWhenTheTokenTaxesTheVault() public {
    (TaxedToken taxed, Vault taxedVault) = _taxedVault();
    taxed.setTaxedPool(address(taxedVault), 100); // 1 %, what the owner of an AgentToken can switch on

    vm.prank(ADMIN);
    vm.expectRevert(abi.encodeWithSelector(Vault.InboundShortfall.selector, 1_000e18, 990e18));
    taxedVault.depositCapital(1_000e18);
    assertEq(taxedVault.capital(), 0);
  }

  function test_CollectDepositRevertsWhenTheTokenTaxesTheVault() public {
    (TaxedToken taxed, Vault taxedVault) = _taxedVault();
    address game_ = address(0x6A3E);
    vm.prank(ADMIN);
    taxedVault.setGame(game_);
    taxed.setTaxedPool(address(taxedVault), 10_000); // the 100 % pool tax from the audit's PoC

    vm.prank(game_);
    vm.expectRevert(abi.encodeWithSelector(Vault.InboundShortfall.selector, 100e18, 0));
    taxedVault.collectDeposit(PLAYER, 100e18);
    assertEq(taxedVault.heldDeposits(), 0);
  }

  function test_UntaxedInflowsAreBookedInFull() public {
    (, Vault taxedVault) = _taxedVault();
    address game_ = address(0x6A3E);
    vm.startPrank(ADMIN);
    taxedVault.setGame(game_);
    taxedVault.depositCapital(1_000e18);
    vm.stopPrank();
    vm.prank(game_);
    taxedVault.collectDeposit(PLAYER, 100e18);
    assertEq(taxedVault.capital(), 1_000e18);
    assertEq(taxedVault.heldDeposits(), 100e18);
  }

  // ----------------- MarkSurvived: the only way a channel survives -----------------

  function test_ExpiredChannelIsNotSurvivedWithoutTheAttestation() public {
    (uint256 pid,) = _boundSurvive();
    vm.warp(_endOf(pid) + 1 days);
    _expectSkip(pid, KIND_SETTLE, "not-final");
    _settleOnlyEntry(pid);
    assertEq(_status(pid), uint8(GameState.PositionStatus.Active));
  }

  function test_BreachSideIsNotSettledWithoutTheAttestationEither() public {
    (, uint256 channelId) = _boundSurvive();
    uint256 pidB = _joinBreachSide(channelId);
    vm.warp(_endOf(pidB) + 1);
    _expectSkip(pidB, KIND_SETTLE, "not-final");
    _settleOnlyEntry(pidB);
    assertEq(_status(pidB), uint8(GameState.PositionStatus.Active));
  }

  function test_AttestationSettlesBothSides() public {
    (uint256 pid, uint256 channelId) = _boundSurvive();
    uint256 pidB = _joinBreachSide(channelId);
    vm.warp(_endOf(pid) + 1);

    vm.expectEmit(true, false, false, true, address(game));
    emit GameLogic.ChannelSurvived(channelId, uint64(block.timestamp));
    _markSurvivedEntry(channelId);
    assertEq(game.getChannel(channelId).survivedAt, block.timestamp);

    uint256 before = token.balanceOf(PLAYER);
    uint256 beforeB = token.balanceOf(PLAYER2);
    _settleOnlyEntry(pid);
    _settleOnlyEntry(pidB);
    assertEq(token.balanceOf(PLAYER) - before, 184.536e18); // 99 + 95.04 − 9.504
    assertEq(token.balanceOf(PLAYER2), beforeB); // the breach side lost
    assertEq(vault.reservedTotal(), 0);
    assertTrue(vault.solvent());
  }

  function test_AttestationBeforeTheEndIsRefused() public {
    (, uint256 channelId) = _boundSurvive();
    _expectSkip(channelId, KIND_MARK_SURVIVED, "not-final");
    _markSurvivedEntry(channelId);
    assertEq(game.getChannel(channelId).survivedAt, 0);
  }

  function test_AttestationAfterTheSettlementWindowIsRefused() public {
    (uint256 pid, uint256 channelId) = _boundSurvive();
    vm.warp(_endOf(pid) + 7 days + 1);
    _expectSkip(channelId, KIND_MARK_SURVIVED, "late");
    _markSurvivedEntry(channelId);
    // the player is not stuck: the stale refund opens after the window
    vm.prank(PLAYER);
    game.refundStale(pid);
    assertEq(_status(pid), uint8(GameState.PositionStatus.Refunded));
  }

  function test_AttestationOfABreachedChannelIsRefused() public {
    (uint256 pid, uint256 channelId) = _boundSurvive();
    _breachEntry(channelId, 81_000e18, uint32(block.timestamp + 10));
    vm.warp(_endOf(pid) + 1);
    _expectSkip(channelId, KIND_MARK_SURVIVED, "breached");
    _markSurvivedEntry(channelId);
    assertEq(game.getChannel(channelId).survivedAt, 0);
  }

  function test_AttestationIsOneTimeAndNeedsAKnownChannel() public {
    (uint256 pid, uint256 channelId) = _boundSurvive();
    vm.warp(_endOf(pid) + 1);
    _markSurvivedEntry(channelId);
    uint256 at = game.getChannel(channelId).survivedAt;

    vm.warp(block.timestamp + 60);
    _expectSkip(channelId, KIND_MARK_SURVIVED, "already");
    _markSurvivedEntry(channelId);
    assertEq(game.getChannel(channelId).survivedAt, at);

    _expectSkip(999, KIND_MARK_SURVIVED, "channel");
    _markSurvivedEntry(999);
  }

  function test_OnlyTheOperatorAttests() public {
    (uint256 pid, uint256 channelId) = _boundSurvive();
    vm.warp(_endOf(pid) + 1);
    GameState.BatchEntry[] memory entries = new GameState.BatchEntry[](1);
    entries[0] = GameState.BatchEntry(GameState.EntryKind.MarkSurvived, channelId, 0, 0, 0);
    for (uint256 i = 0; i < 3; ++i) {
      address caller = [PLAYER, ADMIN, GUARDIAN][i];
      vm.prank(caller);
      vm.expectRevert(ChannelGame.NotOperator.selector);
      game.processBatch(new bytes[](0), entries);
    }
  }

  function test_SettlePastTheWindowWithoutAttestationRefunds() public {
    (uint256 pid,) = _boundSurvive();
    vm.warp(_endOf(pid) + 7 days + 1);
    uint256 before = token.balanceOf(PLAYER);
    vm.expectEmit(true, false, false, true, address(game));
    emit GameLogic.PositionRefunded(pid, 99.5e18);
    _settleOnlyEntry(pid);
    assertEq(_status(pid), uint8(GameState.PositionStatus.Refunded));
    assertEq(token.balanceOf(PLAYER) - before, 99.5e18); // deposit − fixed fee, as refundStale pays
    assertEq(vault.reservedTotal(), 0);
    assertTrue(vault.solvent());
  }

  function test_CloseRequestedPastTheWindowWithoutAttestationRefunds() public {
    (uint256 pid,) = _boundSurvive();
    vm.warp(block.timestamp + 600);
    vm.prank(PLAYER);
    game.requestClose(pid);
    vm.warp(_endOf(pid) + 7 days + 1);
    _settleOnlyEntry(pid);
    assertEq(_status(pid), uint8(GameState.PositionStatus.Refunded));
    assertEq(vault.reservedTotal(), 0);
  }

  /// @dev A reward deferred before the upgrade was settled by the clock (no attestation existed):
  ///      survivedAt stays 0, and approval must still pay it.
  function test_RewardDeferredBeforeTheUpgradeStaysApprovable() public {
    (uint256 pid, uint256 channelId) = _boundSurvive();
    vm.prank(GUARDIAN);
    game.setPaused(true);
    vm.warp(_endOf(pid) + 1);
    _settleEntry(pid);
    assertEq(_status(pid), uint8(GameState.PositionStatus.RewardDeferred));

    // simulate the legacy state: clear Channel.survivedAt (slot 4 of the channel, bytes 22..29)
    GameState.Channel memory c0 = game.getChannel(channelId);
    bytes32 base = keccak256(abi.encode(channelId, uint256(GameState.STORAGE_SLOT) + 6));
    bytes32 word = bytes32(uint256(base) + 4);
    uint256 v = uint256(vm.load(address(game), word));
    vm.store(address(game), word, bytes32(v & ~(uint256(type(uint64).max) << 176)));
    GameState.Channel memory c1 = game.getChannel(channelId);
    assertEq(c1.survivedAt, 0);
    assertEq(c1.openPositions, c0.openPositions); // neighbours intact
    assertEq(c1.totalPositions, c0.totalPositions);
    assertEq(c1.claimedOthers, c0.claimedOthers);

    vm.warp(_endOf(pid) + 8 days); // past the window: the channel can no longer be attested
    uint256 reward = game.getPosition(pid).reserved;
    uint256 before = token.balanceOf(PLAYER);
    uint256[] memory ids = new uint256[](1);
    ids[0] = pid;
    vm.prank(ADMIN);
    game.approveRewards(ids);
    assertEq(_status(pid), uint8(GameState.PositionStatus.Settled));
    assertEq(token.balanceOf(PLAYER) - before, reward - reward / 10);
  }

  function test_CloseReportOutsideTheBandAfterTheAttestationIsRefused() public {
    (uint256 pid, uint256 channelId) = _boundSurvive();
    vm.warp(_endOf(pid) - 600);
    vm.prank(PLAYER);
    game.requestClose(pid);
    uint32 closeTs = uint32(game.getPosition(pid).closeRequestTs);
    vm.warp(_endOf(pid) + 1);
    _markSurvivedEntry(channelId);

    _expectSkip(pid, KIND_SETTLE_CLOSE, "survived");
    _settleCloseAt(pid, 81_000e18, closeTs + 1);
    assertEq(game.getChannel(channelId).breachedAt, 0);
  }

  function test_CloseReportObservedAfterExpiryNeverBackdatesABreach() public {
    (uint256 pid, uint256 channelId) = _boundSurvive();
    vm.warp(_endOf(pid) - 10);
    vm.prank(PLAYER);
    game.requestClose(pid);
    vm.warp(_endOf(pid) + 20);

    _expectSkip(pid, KIND_SETTLE_CLOSE, "time");
    _settleCloseAt(pid, 81_000e18, uint32(_endOf(pid) + 5));
    assertEq(game.getChannel(channelId).breachedAt, 0);
  }

  // ----------------- H-03: no bind on a known outcome -----------------

  function test_BindAfterTheSettlementWindowCancelsWithARefund() public {
    uint256 pid = _openDefault(GameState.Side.Survive, PLAYER);
    vm.warp(_endOf(pid) + 7 days + 1);
    uint256 before = token.balanceOf(PLAYER);
    vm.expectEmit(true, false, false, false, address(game));
    emit GameLogic.PositionCancelled(pid);
    _bind(pid, 80_000e18, 0.5e18);
    assertEq(_status(pid), uint8(GameState.PositionStatus.Cancelled));
    assertEq(token.balanceOf(PLAYER) - before, 99.5e18); // deposit − fixed fee
    assertEq(vault.reservedTotal(), 0);
  }

  function test_BindOnAnAttestedChannelCancelsWithARefund() public {
    (uint256 first, uint256 channelId) = _boundSurvive();
    // a second request on the same channel, still unbound when the channel ends
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
    uint256 pid = game.openPosition(r);

    vm.warp(_endOf(first) + 1);
    _markSurvivedEntry(channelId);
    uint256 before = token.balanceOf(PLAYER2);
    _bind(pid, 80_100e18, 0.6e18);
    assertEq(_status(pid), uint8(GameState.PositionStatus.Cancelled));
    assertEq(token.balanceOf(PLAYER2) - before, 99.5e18);
  }

  function test_BindAfterTheEndInsideTheWindowStillWorks() public {
    // a request from inside the channel's life may still be bound late, before any attestation:
    // its report is from the request second, so the price carries no knowledge of the outcome
    uint256 pid = _openDefault(GameState.Side.Survive, PLAYER);
    vm.warp(_endOf(pid) + 1 hours);
    _bind(pid, 80_000e18, 0.5e18);
    assertEq(_status(pid), uint8(GameState.PositionStatus.Active));
  }

  // ----------------- M-06: report lag bound -----------------

  function test_MaxReportLagDefaultsTo30Seconds() public view {
    assertEq(game.maxReportLag(), 30);
  }

  function test_BindRefusesAReportObservedTooLongAfterTheRequest() public {
    uint256 pid = _openDefault(GameState.Side.Survive, PLAYER);
    uint32 requestTs = uint32(game.getPosition(pid).requestTs);
    vm.warp(requestTs + 60);

    _expectSkip(pid, KIND_BIND, "lag");
    _bindAt(pid, 80_000e18, requestTs + 31);
    assertEq(_status(pid), uint8(GameState.PositionStatus.Requested));

    _bindAt(pid, 80_000e18, requestTs + 30);
    assertEq(_status(pid), uint8(GameState.PositionStatus.Active));
  }

  function test_AdminCanWidenTheLag() public {
    uint256 pid = _openDefault(GameState.Side.Survive, PLAYER);
    uint32 requestTs = uint32(game.getPosition(pid).requestTs);
    vm.warp(requestTs + 120);

    vm.expectEmit(false, false, false, true, address(game));
    emit ChannelGame.MaxReportLagSet(60);
    vm.prank(ADMIN);
    game.setMaxReportLag(60);
    assertEq(game.maxReportLag(), 60);

    _bindAt(pid, 80_000e18, requestTs + 60);
    assertEq(_status(pid), uint8(GameState.PositionStatus.Active));
  }

  function test_LagSetterBoundsAndAccess() public {
    vm.startPrank(ADMIN);
    vm.expectRevert(abi.encodeWithSelector(ChannelGame.InvalidReportLag.selector, 0));
    game.setMaxReportLag(0);
    vm.expectRevert(abi.encodeWithSelector(ChannelGame.InvalidReportLag.selector, 301));
    game.setMaxReportLag(301);
    game.setMaxReportLag(300);
    game.setMaxReportLag(1);
    vm.stopPrank();
    assertEq(game.maxReportLag(), 1);

    for (uint256 i = 0; i < 3; ++i) {
      address caller = [PLAYER, GUARDIAN, TIMELOCK][i];
      vm.prank(caller);
      vm.expectRevert(ChannelGame.NotAdmin.selector);
      game.setMaxReportLag(60);
    }
  }

  function test_SettleCloseRefusesAReportObservedTooLongAfterTheRequest() public {
    (uint256 pid,) = _boundSurvive();
    vm.warp(block.timestamp + 600);
    vm.prank(PLAYER);
    game.requestClose(pid);
    uint32 closeTs = uint32(game.getPosition(pid).closeRequestTs);
    vm.warp(closeTs + 60);

    _expectSkip(pid, KIND_SETTLE_CLOSE, "lag");
    _settleCloseAt(pid, 80_000e18, closeTs + 31);
    assertEq(_status(pid), uint8(GameState.PositionStatus.CloseRequested));
  }

  // ----------------- M-05: a close no report could price -----------------

  function test_UnpricedCloseSettlesByTheOutcomeAfterTheFallbackDelay() public {
    (uint256 pid, uint256 channelId) = _boundSurvive();
    vm.warp(block.timestamp + 600);
    vm.prank(PLAYER);
    game.requestClose(pid);

    vm.warp(_endOf(pid) + 1);
    _markSurvivedEntry(channelId);
    _expectSkip(pid, KIND_SETTLE, "close-pending");
    _settleOnlyEntry(pid);

    vm.warp(_endOf(pid) + 1 hours + 1);
    uint256 before = token.balanceOf(PLAYER);
    _settleOnlyEntry(pid);
    assertEq(_status(pid), uint8(GameState.PositionStatus.Settled));
    assertEq(token.balanceOf(PLAYER) - before, 184.536e18); // settled as a survive win
    assertEq(vault.reservedTotal(), 0);
    assertTrue(vault.solvent());
  }

  function test_UnpricedCloseWaitsForTheOutcome() public {
    (uint256 pid,) = _boundSurvive();
    vm.warp(block.timestamp + 600);
    vm.prank(PLAYER);
    game.requestClose(pid);
    vm.warp(_endOf(pid) + 2 hours);
    _expectSkip(pid, KIND_SETTLE, "close-pending");
    _settleOnlyEntry(pid);
    assertEq(_status(pid), uint8(GameState.PositionStatus.CloseRequested));
  }

  function test_UnpricedCloseLosesWhenTheChannelBreachedAfterTheRequest() public {
    (uint256 pid, uint256 channelId) = _boundSurvive();
    vm.warp(block.timestamp + 600);
    vm.prank(PLAYER);
    game.requestClose(pid);
    _breachEntry(channelId, 81_000e18, uint32(block.timestamp + 60));

    vm.warp(_endOf(pid) + 1 hours + 1);
    uint256 before = token.balanceOf(PLAYER);
    _settleOnlyEntry(pid);
    assertEq(_status(pid), uint8(GameState.PositionStatus.Liquidated));
    assertEq(token.balanceOf(PLAYER), before);
  }

  // ----------------- M-08: channel creation fee cap -----------------

  function test_CreationFeeAboveTheMinimumDepositIsRefused() public {
    vm.startPrank(ADMIN);
    vm.expectRevert(abi.encodeWithSelector(AssetRegistry.InvalidConfig.selector, "creation-fee"));
    assets.setCurrencyTerms(BTC, 0, AssetRegistry.CurrencyTerms(10e18, 10_000e18, 0.5e18, 10e18 + 1, 50e18));
    assets.setCurrencyTerms(BTC, 0, AssetRegistry.CurrencyTerms(10e18, 10_000e18, 0.5e18, 10e18, 50e18));

    AssetRegistry.AssetConfig memory cfg = _config();
    cfg.channelCreationFee = 11e18;
    vm.expectRevert(abi.encodeWithSelector(AssetRegistry.InvalidConfig.selector, "creation-fee"));
    assets.registerAsset(bytes32((uint256(0x0003) << 240) | 2), cfg);
    vm.stopPrank();
  }

  // ----------------- N-1: channel expiry bound -----------------

  function test_ChannelCreationRefusesAnEndBeyondTheMaximumDuration() public {
    ChannelGame.NewChannel memory n = ChannelGame.NewChannel(BTC, 0, type(uint64).max, 0, 0.02e18, 0, true, PLAYER);
    vm.prank(PLAYER);
    vm.expectRevert(abi.encodeWithSelector(ChannelGame.BadGeometry.selector, "duration"));
    game.createChannel(n);

    n.endTs = uint64(block.timestamp + 24 hours + 1);
    vm.prank(PLAYER);
    vm.expectRevert(abi.encodeWithSelector(ChannelGame.BadGeometry.selector, "duration"));
    game.createChannel(n);

    n.endTs = uint64(block.timestamp);
    vm.prank(PLAYER);
    vm.expectRevert(abi.encodeWithSelector(ChannelGame.BadGeometry.selector, "duration"));
    game.createChannel(n);

    n.endTs = uint64(block.timestamp + 24 hours);
    vm.prank(PLAYER);
    game.createChannel(n);
  }
}
