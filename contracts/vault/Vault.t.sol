// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AccessRegistry} from "../access/AccessRegistry.sol";
import {OverToken} from "../mocks/OverToken.sol";
import {FreezableToken} from "../mocks/FreezableToken.sol";
import {Vault} from "./Vault.sol";

contract VaultTest is Test {
  address constant TIMELOCK = address(0x71);
  address constant ADMIN = address(0xA1);
  address constant GAME = address(0x6A);
  address constant PLAYER = address(0x1);
  address constant TREASURY = address(0x77);
  bytes32 constant ASSET = keccak256("BTC");
  bytes32 constant ASSET2 = keccak256("ETH");

  OverToken token;
  AccessRegistry access;
  Vault vault;

  function setUp() public {
    token = new OverToken(1_000_000e18);
    AccessRegistry aImpl = new AccessRegistry();
    access = AccessRegistry(
      address(
        new ERC1967Proxy(
          address(aImpl), abi.encodeCall(AccessRegistry.initialize, (TIMELOCK, ADMIN, address(0x01), address(0x61)))
        )
      )
    );
    Vault vImpl = new Vault();
    vault = Vault(
      address(new ERC1967Proxy(address(vImpl), abi.encodeCall(Vault.initialize, (address(access), address(token)))))
    );
    vm.prank(ADMIN);
    vault.setGame(GAME);

    // distribute OVER and approve
    token.transfer(ADMIN, 500_000e18);
    token.transfer(PLAYER, 10_000e18);
    vm.prank(ADMIN);
    token.approve(address(vault), type(uint256).max);
    vm.prank(PLAYER);
    token.approve(address(vault), type(uint256).max);
  }

  function _fundCapital(uint256 amount) internal {
    vm.prank(ADMIN);
    vault.depositCapital(amount);
  }

  // ----------------- game address -----------------

  function test_SetGameOnceByAdminOnEmptyVaultOnly() public {
    vm.prank(ADMIN);
    vm.expectRevert(Vault.GameAlreadySet.selector);
    vault.setGame(address(0xDEAD));

    Vault fresh = Vault(
      address(
        new ERC1967Proxy(address(new Vault()), abi.encodeCall(Vault.initialize, (address(access), address(token))))
      )
    );
    // not the admin — not allowed
    vm.prank(PLAYER);
    vm.expectRevert(Vault.NotAdmin.selector);
    fresh.setGame(GAME);
    // non-empty vault — not allowed
    vm.startPrank(ADMIN);
    token.approve(address(fresh), type(uint256).max);
    fresh.depositCapital(1e18);
    vm.expectRevert(Vault.VaultNotEmpty.selector);
    fresh.setGame(GAME);
    vm.stopPrank();
  }

  // ----------------- capital -----------------

  function test_DepositCapitalOnlyAdmin() public {
    _fundCapital(1000e18);
    assertEq(vault.capital(), 1000e18);
    assertTrue(vault.solvent());

    vm.prank(PLAYER);
    vm.expectRevert(Vault.NotAdmin.selector);
    vault.depositCapital(1e18);
  }

  function test_CapitalWithdrawalTwoStepWithDelay() public {
    _fundCapital(1000e18);
    vm.prank(ADMIN);
    vault.requestCapitalWithdrawal(400e18);

    // cannot execute immediately
    vm.prank(ADMIN);
    vm.expectRevert();
    vault.executeCapitalWithdrawal(TREASURY);

    vm.warp(block.timestamp + 3 days);
    vm.prank(ADMIN);
    vault.executeCapitalWithdrawal(TREASURY);
    assertEq(token.balanceOf(TREASURY), 400e18);
    assertEq(vault.capital(), 600e18);
    assertTrue(vault.solvent());
  }

  function test_CapitalWithdrawalLimitedToFreePart() public {
    _fundCapital(1000e18);
    vm.prank(GAME);
    vault.reserve(800e18);

    // a request above the free amount is rejected
    vm.prank(ADMIN);
    vm.expectRevert(abi.encodeWithSelector(Vault.InsufficientFreeCapital.selector, 300e18, 200e18));
    vault.requestCapitalWithdrawal(300e18);

    // request within the free amount, but by execution time the free amount has shrunk — reverts
    vm.prank(ADMIN);
    vault.requestCapitalWithdrawal(200e18);
    vm.prank(GAME);
    vault.reserve(100e18); // free amount is now 100
    vm.warp(block.timestamp + 3 days);
    vm.prank(ADMIN);
    vm.expectRevert(abi.encodeWithSelector(Vault.InsufficientFreeCapital.selector, 200e18, 100e18));
    vault.executeCapitalWithdrawal(TREASURY);
  }

  function test_CancelCapitalWithdrawal() public {
    _fundCapital(100e18);
    vm.startPrank(ADMIN);
    vault.requestCapitalWithdrawal(50e18);
    vault.cancelCapitalWithdrawal();
    vm.expectRevert(Vault.NoPendingWithdrawal.selector);
    vault.executeCapitalWithdrawal(TREASURY);
    vm.stopPrank();
  }

  // ----------------- reserves -----------------

  function test_ReserveLimitedByCapital() public {
    _fundCapital(1000e18);
    vm.startPrank(GAME);
    vault.reserve(700e18);
    vault.reserve(200e18);
    assertEq(vault.reservedTotal(), 900e18);
    assertEq(vault.freeCapital(), 100e18);

    vm.expectRevert(abi.encodeWithSelector(Vault.InsufficientFreeCapital.selector, 101e18, 100e18));
    vault.reserve(101e18);

    vault.release(700e18);
    assertEq(vault.freeCapital(), 800e18);
    assertEq(vault.reservedTotal(), 200e18);
    vault.release(200e18);
    vm.expectRevert(abi.encodeWithSelector(Vault.InsufficientReserve.selector, 1, 0));
    vault.release(1);
    vm.stopPrank();
  }

  function test_OnlyGameMovesGameMoney() public {
    _fundCapital(100e18);
    vm.startPrank(ADMIN);
    vm.expectRevert(Vault.NotGame.selector);
    vault.reserve(1e18);
    vm.expectRevert(Vault.NotGame.selector);
    vault.collectDeposit(PLAYER, 1e18);
    vm.expectRevert(Vault.NotGame.selector);
    vault.settle(0, 0, PLAYER, 0, 0, 0, 0);
    vm.expectRevert(Vault.NotGame.selector);
    vault.payRoyalty(1, PLAYER);
    vm.stopPrank();
  }

  // ----------------- deposits and settlement -----------------

  function test_WinningSettlementFlow() public {
    // Position: deposit 100, opening fee 1 (to revenue at settlement), working amount 99,
    // multiplier ×2 → reward 99, profit fee 10% = 9.9, royalty 15% of the fee = 1.485.
    _fundCapital(1000e18);
    vm.prank(GAME);
    vault.collectDeposit(PLAYER, 100e18);
    assertEq(vault.heldDeposits(), 100e18);
    vm.prank(GAME);
    vault.reserve(99e18);

    uint256 playerBefore = token.balanceOf(PLAYER);
    vm.startPrank(GAME);
    vault.release(99e18); // the reserve is released for the exact reward
    // to the player: 99 (stake) + 99·0.9 (reward after fee) = 188.1
    // revenue: 1 (opening) + 9.9·0.85 = 9.415; royalty: 1.485
    vault.settle(100e18, 99e18, PLAYER, 188.1e18, 9.415e18, 42, 1.485e18);
    vm.stopPrank();

    assertEq(token.balanceOf(PLAYER) - playerBefore, 188.1e18);
    assertEq(vault.revenue(), 9.415e18);
    assertEq(vault.royaltyOf(GAME, 42), 1.485e18);
    assertEq(vault.capital(), 1000e18 - 99e18);
    assertEq(vault.heldDeposits(), 0);
    assertTrue(vault.solvent());
  }

  function test_LosingSettlementDepositToCapitalIsExplicit() public {
    // Loss: the deposit is split — fees go to revenue, the working amount goes to capital.
    // "To capital" = a negative fromCapital is impossible, so: the deposit comes in,
    // the player gets 0, fees go to revenue — does the working amount go to revenue too? No — to capital:
    // this is modeled as settle(deposit, 0, ..., toPlayer=0, toRevenue=fees, royalty 0)
    // PLUS the remainder goes to capital via a separate field? No such field is needed: the remainder must
    // be zero per the balance check, so the working amount is booked as game revenue.
    // A deliberate accounting decision: the protocol's win is also revenue, not capital
    // (ADR-0013: fees don't go into capital; player losses are income, withdrawn by the admin).
    _fundCapital(100e18);
    vm.startPrank(GAME);
    vault.collectDeposit(PLAYER, 100e18);
    vault.settle(100e18, 0, PLAYER, 0, 100e18, 0, 0);
    vm.stopPrank();
    assertEq(vault.revenue(), 100e18);
    assertEq(vault.heldDeposits(), 0);
    assertTrue(vault.solvent());
  }

  function test_SettleRejectsImbalance() public {
    _fundCapital(100e18);
    vm.startPrank(GAME);
    vault.collectDeposit(PLAYER, 100e18);
    vm.expectRevert(abi.encodeWithSelector(Vault.SettlementImbalance.selector, 100e18, 99e18));
    vault.settle(100e18, 0, PLAYER, 99e18, 0, 0, 0);
    vm.expectRevert(abi.encodeWithSelector(Vault.InsufficientDeposits.selector, 101e18, 100e18));
    vault.settle(101e18, 0, PLAYER, 101e18, 0, 0, 0);
    vm.stopPrank();
  }

  // ----------------- revenue and royalty -----------------

  function test_RevenueWithdrawableByAdminAnytime() public {
    _fundCapital(10e18);
    vm.startPrank(GAME);
    vault.collectDeposit(PLAYER, 50e18);
    vault.settle(50e18, 0, PLAYER, 0, 50e18, 0, 0);
    vm.stopPrank();

    vm.prank(ADMIN);
    vault.withdrawRevenue(TREASURY, 30e18);
    assertEq(token.balanceOf(TREASURY), 30e18);
    assertEq(vault.revenue(), 20e18);
    assertTrue(vault.solvent());

    vm.prank(ADMIN);
    vm.expectRevert(abi.encodeWithSelector(Vault.InsufficientRevenue.selector, 21e18, 20e18));
    vault.withdrawRevenue(TREASURY, 21e18);
  }

  function test_RoyaltyAccrualAndPayout() public {
    _fundCapital(100e18);
    vm.startPrank(GAME);
    vault.collectDeposit(PLAYER, 100e18);
    vault.settle(100e18, 0, PLAYER, 0, 90e18, 7, 10e18);
    assertEq(vault.royaltyOf(GAME, 7), 10e18);
    assertEq(vault.royaltyTotal(), 10e18);

    uint256 paid = vault.payRoyalty(7, PLAYER);
    assertEq(paid, 10e18);
    assertEq(vault.royaltyOf(GAME, 7), 0);
    assertEq(vault.royaltyTotal(), 0);
    // a repeat claim pays zero
    assertEq(vault.payRoyalty(7, PLAYER), 0);
    vm.stopPrank();
    assertTrue(vault.solvent());
  }

  // ----------------- invariant (fuzz) -----------------

  function testFuzz_SolvencyHoldsAcrossFlows(uint96 dep, uint96 res, uint96 win) public {
    uint256 capitalIn = 10_000e18;
    _fundCapital(capitalIn);
    uint256 deposit = (uint256(dep) % 5_000e18) + 1e18;
    deal(address(token), PLAYER, deposit);
    vm.prank(PLAYER);
    token.approve(address(vault), deposit);

    vm.startPrank(GAME);
    vault.collectDeposit(PLAYER, deposit);
    uint256 reserveAmt = uint256(res) % vault.freeCapital();
    vault.reserve(reserveAmt);

    // settlement: part of the deposit to the player, part to revenue, the reward from capital ≤ the reserve
    uint256 fromCapital = uint256(win) % (reserveAmt + 1);
    vault.release(reserveAmt);
    uint256 toPlayer = deposit / 2 + fromCapital;
    uint256 toRevenue = deposit - deposit / 2;
    vault.settle(deposit, fromCapital, PLAYER, toPlayer, toRevenue, 0, 0);
    vm.stopPrank();

    assertTrue(vault.solvent());
    assertEq(vault.reservedTotal(), 0);
    assertEq(vault.heldDeposits(), 0);
  }

  // ----------------- v3: capital leg (ADR-0022) -----------------

  function test_LossWorkingAmountGoesToCapital() public {
    // Loss: deposit 100 = fee 1 (revenue) + working amount 99 (capital). The bankroll grows.
    _fundCapital(100e18);
    vm.startPrank(GAME);
    vault.collectDeposit(PLAYER, 100e18);
    vault.settle(100e18, 0, PLAYER, 0, 1e18, 0, 0, 99e18);
    vm.stopPrank();
    assertEq(vault.capital(), 199e18);
    assertEq(vault.revenue(), 1e18);
    assertEq(vault.heldDeposits(), 0);
    assertTrue(vault.solvent());
  }

  function test_SettleImbalanceCountsCapitalLeg() public {
    _fundCapital(100e18);
    vm.startPrank(GAME);
    vault.collectDeposit(PLAYER, 100e18);
    vm.expectRevert(abi.encodeWithSelector(Vault.SettlementImbalance.selector, 100e18, 101e18));
    vault.settle(100e18, 0, PLAYER, 0, 1e18, 0, 0, 100e18);
    vm.stopPrank();
  }

  function test_V2SettleSignatureStillWorks() public {
    _fundCapital(100e18);
    vm.startPrank(GAME);
    vault.collectDeposit(PLAYER, 10e18);
    vault.settle(10e18, 0, PLAYER, 9e18, 1e18, 0, 0); // 7-arg wrapper: toCapital = 0
    vm.stopPrank();
    assertEq(vault.capital(), 100e18);
    assertEq(vault.revenue(), 1e18);
  }

  function test_RevenueToCapitalByAdminNoDelay() public {
    _fundCapital(10e18);
    vm.startPrank(GAME);
    vault.collectDeposit(PLAYER, 50e18);
    vault.settle(50e18, 0, PLAYER, 0, 50e18, 0, 0);
    vm.stopPrank();

    vm.prank(PLAYER);
    vm.expectRevert(Vault.NotAdmin.selector);
    vault.revenueToCapital(1e18);

    vm.prank(ADMIN);
    vault.revenueToCapital(30e18);
    assertEq(vault.revenue(), 20e18);
    assertEq(vault.capital(), 40e18);
    assertTrue(vault.solvent());

    vm.prank(ADMIN);
    vm.expectRevert(abi.encodeWithSelector(Vault.InsufficientRevenue.selector, 21e18, 20e18));
    vault.revenueToCapital(21e18);
  }

  // ----------------- v3: refused recipient is owed, not reverted (ADR-0022) -----------------

  function _freezableVault() internal returns (Vault v, FreezableToken usdg) {
    usdg = new FreezableToken("Global Dollar", "USDG", 6);
    v = Vault(
      address(new ERC1967Proxy(address(new Vault()), abi.encodeCall(Vault.initialize, (address(access), address(usdg)))))
    );
    vm.prank(ADMIN);
    v.setGame(GAME);
    usdg.mint(ADMIN, 1_000_000e6);
    usdg.mint(PLAYER, 1_000e6);
    vm.prank(ADMIN);
    usdg.approve(address(v), type(uint256).max);
    vm.prank(PLAYER);
    usdg.approve(address(v), type(uint256).max);
    vm.prank(ADMIN);
    v.depositCapital(10_000e6);
  }

  function test_FrozenRecipientPayoutIsOwedAndSettlementSucceeds() public {
    (Vault v, FreezableToken usdg) = _freezableVault();
    vm.startPrank(GAME);
    v.collectDeposit(PLAYER, 50e6);
    v.reserve(44.55e6);
    vm.stopPrank();

    usdg.freeze(PLAYER);

    vm.startPrank(GAME);
    v.release(44.55e6);
    vm.expectEmit(true, false, false, true, address(v));
    emit Vault.PayoutOwed(PLAYER, 89.595e6);
    v.settle(50e6, 44.55e6, PLAYER, 89.595e6, 4.28675e6, 7, 0.66825e6, 0);
    vm.stopPrank();

    assertEq(v.owedOf(PLAYER), 89.595e6);
    assertEq(v.owedTotal(), 89.595e6);
    assertEq(usdg.balanceOf(PLAYER), 1_000e6 - 50e6); // nothing arrived
    assertTrue(v.solvent());

    // still frozen: the withdrawal itself fails loudly, nothing is lost
    vm.prank(PLAYER);
    vm.expectRevert(abi.encodeWithSelector(Vault.TransferFailed.selector, PLAYER, 89.595e6));
    v.withdrawOwed();
    assertEq(v.owedOf(PLAYER), 89.595e6);

    usdg.unfreeze(PLAYER);
    vm.prank(PLAYER);
    v.withdrawOwed();
    assertEq(usdg.balanceOf(PLAYER), 1_000e6 - 50e6 + 89.595e6);
    assertEq(v.owedOf(PLAYER), 0);
    assertEq(v.owedTotal(), 0);
    assertTrue(v.solvent());

    vm.prank(PLAYER);
    vm.expectRevert(abi.encodeWithSelector(Vault.NothingOwed.selector, PLAYER));
    v.withdrawOwed();
  }

  function test_FrozenRoyaltyRecipientIsOwed() public {
    (Vault v, FreezableToken usdg) = _freezableVault();
    vm.startPrank(GAME);
    v.collectDeposit(PLAYER, 50e6);
    v.settle(50e6, 0, PLAYER, 0, 40e6, 7, 10e6, 0);
    vm.stopPrank();
    usdg.freeze(PLAYER);
    vm.prank(GAME);
    assertEq(v.payRoyalty(7, PLAYER), 10e6);
    assertEq(v.royaltyOf(GAME, 7), 0);
    assertEq(v.owedOf(PLAYER), 10e6);
    assertTrue(v.solvent());
  }

  function testFuzz_SolvencyHoldsWithCapitalLeg(uint96 dep, uint96 res, uint96 split) public {
    _fundCapital(10_000e18);
    uint256 deposit = (uint256(dep) % 5_000e18) + 1e18;
    deal(address(token), PLAYER, deposit);
    vm.prank(PLAYER);
    token.approve(address(vault), deposit);

    vm.startPrank(GAME);
    vault.collectDeposit(PLAYER, deposit);
    uint256 reserveAmt = uint256(res) % vault.freeCapital();
    vault.reserve(reserveAmt);
    vault.release(reserveAmt);
    // a loss: the deposit splits between revenue and capital, nothing to the player
    uint256 toCapital = uint256(split) % (deposit + 1);
    vault.settle(deposit, 0, PLAYER, 0, deposit - toCapital, 0, 0, toCapital);
    vm.stopPrank();

    assertTrue(vault.solvent());
    assertEq(vault.capital(), 10_000e18 + toCapital);
    assertEq(vault.heldDeposits(), 0);
  }

  // ----------------- upgrade -----------------

  function test_UpgradeOnlyTimelock() public {
    Vault v2 = new Vault();
    vm.prank(ADMIN);
    vm.expectRevert(Vault.NotTimelock.selector);
    vault.upgradeToAndCall(address(v2), "");
    vm.prank(TIMELOCK);
    vault.upgradeToAndCall(address(v2), "");
  }
}
