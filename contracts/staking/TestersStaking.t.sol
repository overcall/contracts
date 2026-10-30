// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {OverToken} from "../mocks/OverToken.sol";
import {TestersStaking} from "./TestersStaking.sol";

contract TestersStakingTest is Test {
  address constant ALICE = address(0xA11CE);
  address constant BOB = address(0xB0B);

  OverToken token;
  TestersStaking staking;

  function setUp() public {
    token = new OverToken(1_000_000 ether);
    staking = new TestersStaking(token, address(this));
    token.transfer(ALICE, 10_000 ether);
    token.transfer(BOB, 10_000 ether);
    vm.prank(ALICE);
    token.approve(address(staking), type(uint256).max);
    vm.prank(BOB);
    token.approve(address(staking), type(uint256).max);
  }

  function test_stakeMovesTokensAndTracksBalance() public {
    vm.prank(ALICE);
    staking.stake(1_000 ether);

    assertEq(staking.staked(ALICE), 1_000 ether);
    assertEq(staking.totalStaked(), 1_000 ether);
    assertEq(token.balanceOf(address(staking)), 1_000 ether);
    assertEq(token.balanceOf(ALICE), 9_000 ether);
  }

  function test_multipleStakesAccumulate() public {
    vm.startPrank(ALICE);
    staking.stake(1_000 ether);
    staking.stake(500 ether);
    vm.stopPrank();

    assertEq(staking.staked(ALICE), 1_500 ether);
  }

  function test_unstakePartialAndFull() public {
    vm.startPrank(ALICE);
    staking.stake(1_000 ether);
    staking.unstake(400 ether);
    assertEq(staking.staked(ALICE), 600 ether);
    staking.unstake(600 ether);
    vm.stopPrank();

    assertEq(staking.staked(ALICE), 0);
    assertEq(staking.totalStaked(), 0);
    assertEq(token.balanceOf(ALICE), 10_000 ether);
  }

  function test_balancesAreIndependentPerUser() public {
    vm.prank(ALICE);
    staking.stake(1_000 ether);
    vm.prank(BOB);
    staking.stake(2_000 ether);
    vm.prank(ALICE);
    staking.unstake(1_000 ether);

    assertEq(staking.staked(ALICE), 0);
    assertEq(staking.staked(BOB), 2_000 ether);
    assertEq(staking.totalStaked(), 2_000 ether);
  }

  function test_eventsCarryTheResultingBalanceAndTimestamp() public {
    vm.warp(1_800_000_000);
    vm.prank(ALICE);
    vm.expectEmit(true, false, false, true);
    emit TestersStaking.Staked(ALICE, 1_000 ether, 1_000 ether, 1_800_000_000);
    staking.stake(1_000 ether);

    vm.warp(1_800_000_500);
    vm.prank(ALICE);
    vm.expectEmit(true, false, false, true);
    emit TestersStaking.Unstaked(ALICE, 300 ether, 700 ether, 1_800_000_500);
    staking.unstake(300 ether);
  }

  function test_revertsOnZeroAmounts() public {
    vm.prank(ALICE);
    vm.expectRevert(TestersStaking.ZeroAmount.selector);
    staking.stake(0);

    vm.prank(ALICE);
    vm.expectRevert(TestersStaking.ZeroAmount.selector);
    staking.unstake(0);
  }

  function test_revertsOnUnstakingMoreThanStaked() public {
    vm.prank(ALICE);
    staking.stake(100 ether);

    vm.prank(ALICE);
    vm.expectRevert(
      abi.encodeWithSelector(TestersStaking.InsufficientStake.selector, 101 ether, 100 ether)
    );
    staking.unstake(101 ether);
  }

  function test_cannotUnstakeSomeoneElsesStake() public {
    vm.prank(ALICE);
    staking.stake(100 ether);

    vm.prank(BOB);
    vm.expectRevert(
      abi.encodeWithSelector(TestersStaking.InsufficientStake.selector, 100 ether, 0)
    );
    staking.unstake(100 ether);
  }

  function test_rescueCannotTouchStakedPrincipal() public {
    vm.prank(ALICE);
    staking.stake(1_000 ether);
    // surplus is zero: everything held is staked
    vm.expectRevert(
      abi.encodeWithSelector(TestersStaking.RescueExceedsAvailable.selector, 1, 0)
    );
    staking.rescue(token, address(this), 1);
    // stake and totalStaked untouched
    assertEq(staking.staked(ALICE), 1_000 ether);
    assertEq(token.balanceOf(address(staking)), 1_000 ether);
  }

  function test_rescueWithdrawsOnlyTheSurplusOfTheStakingToken() public {
    vm.prank(ALICE);
    staking.stake(1_000 ether);
    // a stray direct transfer creates a 50 surplus above totalStaked
    token.transfer(address(staking), 50 ether);
    // more than the surplus reverts
    vm.expectRevert(
      abi.encodeWithSelector(
        TestersStaking.RescueExceedsAvailable.selector, 51 ether, 50 ether
      )
    );
    staking.rescue(token, address(this), 51 ether);
    // exactly the surplus is recoverable, principal stays put
    uint256 before = token.balanceOf(address(this));
    staking.rescue(token, address(this), 50 ether);
    assertEq(token.balanceOf(address(this)) - before, 50 ether);
    assertEq(token.balanceOf(address(staking)), 1_000 ether);
    assertEq(staking.staked(ALICE), 1_000 ether);
  }

  function test_rescueWithdrawsAnyOtherTokenInFull() public {
    OverToken other = new OverToken(500 ether);
    other.transfer(address(staking), 500 ether);
    staking.rescue(other, ALICE, 500 ether);
    assertEq(other.balanceOf(ALICE), 500 ether);
  }

  function test_rescueIsOwnerOnly() public {
    vm.prank(ALICE);
    vm.expectRevert(
      abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", ALICE)
    );
    staking.rescue(token, ALICE, 0);
  }

  function test_rescueRejectsZeroRecipient() public {
    vm.expectRevert(TestersStaking.ZeroAddress.selector);
    staking.rescue(token, address(0), 0);
  }
}
