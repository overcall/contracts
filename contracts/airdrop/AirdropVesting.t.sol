// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {OverToken} from "../mocks/OverToken.sol";
import {AirdropVesting} from "./AirdropVesting.sol";

/// A smart-account winner (17 of the mainnet winners are EIP-7702 wallets): claims through a call.
contract ClaimingWallet {
  function claim(AirdropVesting vesting) external returns (uint256) {
    return vesting.claim();
  }
}

contract AirdropVestingTest is Test {
  uint64 constant START = 1_792_490_400; // 2026-10-20 10:00:00 UTC
  uint64 constant CLAIM_END = START + 30 days;
  uint256 constant FUND = 10_000_000 ether;
  address constant OWNER = address(0x0E);
  address constant ALICE = address(0xA11CE);
  address constant BOB = address(0xB0B);
  address constant CAROL = address(0xCA201);
  uint256 constant ALICE_AMOUNT = 6_000_000 ether;
  uint256 constant BOB_AMOUNT = 3_998_999 ether + 1; // not divisible by 15; the three add up to 9,999,999 OVER
  uint256 constant CAROL_AMOUNT = 1_000 ether - 1;

  OverToken token;
  AirdropVesting vesting;

  event Allocated(address indexed winner, uint256 amount);
  event Claimed(address indexed winner, uint256 amount, uint256 claimedTotal);
  event Withdrawn(address indexed to, uint256 amount);
  event Rescued(address indexed asset, address indexed to, uint256 amount);

  function setUp() public {
    vm.warp(START - 1 hours);
    token = new OverToken(1_000_000_000 ether);
    vesting = _deploy(_winners(), _amounts());
    token.transfer(address(vesting), FUND);
  }

  // ----------------- constructor -----------------

  function test_constructorStoresAllocationsAndSchedule() public view {
    assertEq(address(vesting.token()), address(token));
    assertEq(vesting.owner(), OWNER);
    assertEq(vesting.start(), START);
    assertEq(vesting.claimEnd(), CLAIM_END);
    assertEq(vesting.allocation(ALICE), ALICE_AMOUNT);
    assertEq(vesting.allocation(BOB), BOB_AMOUNT);
    assertEq(vesting.allocation(CAROL), CAROL_AMOUNT);
    assertEq(vesting.totalAllocated(), ALICE_AMOUNT + BOB_AMOUNT + CAROL_AMOUNT);
    assertEq(vesting.allocation(address(0xDEAD)), 0);
  }

  function test_constructorEmitsOneAllocatedPerWinner() public {
    vm.expectEmit(true, false, false, true);
    emit Allocated(ALICE, ALICE_AMOUNT);
    vm.expectEmit(true, false, false, true);
    emit Allocated(BOB, BOB_AMOUNT);
    vm.expectEmit(true, false, false, true);
    emit Allocated(CAROL, CAROL_AMOUNT);
    _deploy(_winners(), _amounts());
  }

  function test_constructorRejectsBadInput() public {
    address[] memory winners = _winners();
    uint256[] memory amounts = _amounts();

    vm.expectRevert(AirdropVesting.ZeroAddress.selector);
    new AirdropVesting(IERC20(address(0)), OWNER, START, winners, amounts);

    vm.expectRevert(AirdropVesting.ZeroAmount.selector);
    new AirdropVesting(token, OWNER, 0, winners, amounts);

    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
    new AirdropVesting(token, address(0), START, winners, amounts);

    vm.expectRevert(abi.encodeWithSelector(AirdropVesting.LengthMismatch.selector, 3, 2));
    new AirdropVesting(token, OWNER, START, winners, _pair(1 ether, 2 ether));
  }

  function test_constructorRejectsBadRows() public {
    vm.expectRevert(AirdropVesting.ZeroAddress.selector);
    _deploy(_pairAddr(ALICE, address(0)), _pair(1 ether, 1 ether));

    vm.expectRevert(AirdropVesting.ZeroAmount.selector);
    _deploy(_pairAddr(ALICE, BOB), _pair(1 ether, 0));

    vm.expectRevert(abi.encodeWithSelector(AirdropVesting.DuplicateWinner.selector, ALICE));
    _deploy(_pairAddr(ALICE, ALICE), _pair(1 ether, 2 ether));
  }

  // ----------------- schedule -----------------

  function test_nothingUnlocksBeforeTheFirstDay() public {
    assertEq(vesting.unlockedSteps(), 0);
    vm.warp(START);
    assertEq(vesting.unlockedSteps(), 0);
    vm.warp(START + 1 days - 1);
    assertEq(vesting.unlockedSteps(), 0);
    assertEq(vesting.claimable(ALICE), 0);
    assertEq(vesting.nextUnlockAt(), START + 1 days);
  }

  function test_eachDayUnlocksOneFifteenth() public {
    for (uint256 day = 1; day <= 15; day++) {
      vm.warp(START + day * 1 days);
      assertEq(vesting.unlockedSteps(), day);
      assertEq(vesting.vested(ALICE), (ALICE_AMOUNT * day) / 15);
      assertEq(vesting.vested(BOB), (BOB_AMOUNT * day) / 15);
      assertEq(vesting.nextUnlockAt(), day == 15 ? 0 : START + uint64((day + 1) * 1 days));
    }
  }

  function test_theLastStepUnlocksTheWholeAllocation() public {
    vm.warp(START + 15 days);
    assertEq(vesting.vested(BOB), BOB_AMOUNT);
    assertEq(vesting.vested(CAROL), CAROL_AMOUNT);
    vm.warp(START + 29 days);
    assertEq(vesting.unlockedSteps(), 15);
    assertEq(vesting.vested(BOB), BOB_AMOUNT);
  }

  // ----------------- claim -----------------

  function test_claimSendsTheUnlockedPart() public {
    vm.warp(START + 1 days);
    vm.expectEmit(true, false, false, true);
    emit Claimed(ALICE, ALICE_AMOUNT / 15, ALICE_AMOUNT / 15);
    vm.prank(ALICE);
    uint256 amount = vesting.claim();

    assertEq(amount, ALICE_AMOUNT / 15);
    assertEq(token.balanceOf(ALICE), ALICE_AMOUNT / 15);
    assertEq(vesting.claimed(ALICE), ALICE_AMOUNT / 15);
    assertEq(vesting.totalClaimed(), ALICE_AMOUNT / 15);
    assertEq(vesting.claimable(ALICE), 0);
  }

  function test_secondClaimOnTheSameDayHasNothing() public {
    vm.warp(START + 1 days);
    vm.prank(ALICE);
    vesting.claim();

    vm.warp(START + 2 days - 1);
    vm.prank(ALICE);
    vm.expectRevert(AirdropVesting.NothingToClaim.selector);
    vesting.claim();
  }

  function test_aLaterClaimCollectsEveryMissedStep() public {
    vm.warp(START + 1 days);
    vm.prank(BOB);
    vesting.claim();

    vm.warp(START + 9 days + 5 hours);
    vm.prank(BOB);
    uint256 amount = vesting.claim();

    assertEq(amount, (BOB_AMOUNT * 9) / 15 - BOB_AMOUNT / 15);
    assertEq(token.balanceOf(BOB), (BOB_AMOUNT * 9) / 15);
  }

  function test_claimsAddUpToTheAllocationExactly() public {
    for (uint256 day = 1; day <= 15; day++) {
      vm.warp(START + day * 1 days);
      vm.prank(BOB);
      vesting.claim();
    }
    assertEq(token.balanceOf(BOB), BOB_AMOUNT);
    assertEq(vesting.claimed(BOB), BOB_AMOUNT);

    vm.warp(START + 20 days);
    vm.prank(BOB);
    vm.expectRevert(AirdropVesting.NothingToClaim.selector);
    vesting.claim();
  }

  function test_claimWorksUntilTheLastSecondOfTheWindow() public {
    vm.warp(CLAIM_END - 1);
    vm.prank(CAROL);
    assertEq(vesting.claim(), CAROL_AMOUNT);
  }

  function test_claimIsClosedFromClaimEnd() public {
    vm.warp(CLAIM_END);
    assertEq(vesting.claimable(ALICE), 0);
    vm.prank(ALICE);
    vm.expectRevert(abi.encodeWithSelector(AirdropVesting.ClaimWindowClosed.selector, CLAIM_END));
    vesting.claim();
  }

  function test_claimRejectsAnAccountOffTheList() public {
    vm.warp(START + 3 days);
    vm.prank(address(0xDEAD));
    vm.expectRevert(abi.encodeWithSelector(AirdropVesting.NotAWinner.selector, address(0xDEAD)));
    vesting.claim();
  }

  function test_claimBeforeFundingReverts() public {
    AirdropVesting unfunded = _deploy(_winners(), _amounts());
    vm.warp(START + 1 days);
    vm.prank(ALICE);
    vm.expectRevert(
      abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(unfunded), 0, ALICE_AMOUNT / 15)
    );
    unfunded.claim();
  }

  function test_aSmartAccountWinnerClaims() public {
    ClaimingWallet wallet = new ClaimingWallet();
    AirdropVesting withWallet = _deploy(_pairAddr(address(wallet), ALICE), _pair(15 ether, 30 ether));
    token.transfer(address(withWallet), 45 ether);

    vm.warp(START + 4 days);
    assertEq(wallet.claim(withWallet), 4 ether);
    assertEq(token.balanceOf(address(wallet)), 4 ether);
  }

  // ----------------- owner -----------------

  function test_ownerWithdrawsAnyAmountAtAnyTime() public {
    // before the start, during vesting, and the whole rest of the balance
    vm.prank(OWNER);
    vesting.withdraw(OWNER, 1 ether);
    vm.warp(START + 5 days);
    vm.prank(OWNER);
    vesting.withdraw(OWNER, 1_000_000 ether);

    uint256 rest = token.balanceOf(address(vesting));
    vm.expectEmit(true, false, false, true);
    emit Withdrawn(OWNER, rest);
    vm.prank(OWNER);
    vesting.withdraw(OWNER, rest);

    assertEq(token.balanceOf(OWNER), FUND);
    assertEq(token.balanceOf(address(vesting)), 0);
  }

  function test_withdrawingEverythingStopsClaimsUntilRefunded() public {
    vm.warp(START + 3 days);
    vm.prank(OWNER);
    vesting.withdraw(OWNER, FUND);

    vm.prank(ALICE);
    vm.expectRevert(
      abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(vesting), 0, (ALICE_AMOUNT * 3) / 15)
    );
    vesting.claim();

    vm.prank(OWNER);
    token.transfer(address(vesting), FUND);
    vm.prank(ALICE);
    assertEq(vesting.claim(), (ALICE_AMOUNT * 3) / 15);
  }

  function test_withdrawRejectsMoreThanTheBalance() public {
    vm.prank(OWNER);
    vm.expectRevert(abi.encodeWithSelector(AirdropVesting.WithdrawExceedsBalance.selector, FUND + 1, FUND));
    vesting.withdraw(OWNER, FUND + 1);
  }

  function test_afterClaimEndTheOwnerTakesWhatIsLeft() public {
    vm.warp(START + 15 days);
    vm.prank(ALICE);
    vesting.claim();

    vm.warp(CLAIM_END);
    uint256 left = FUND - ALICE_AMOUNT;
    assertEq(vesting.outstanding(), 0);
    assertEq(token.balanceOf(address(vesting)), left);

    address vaultFeeder = address(0xFEED);
    vm.prank(OWNER);
    vesting.withdraw(vaultFeeder, left);
    assertEq(token.balanceOf(vaultFeeder), left);
    assertEq(token.balanceOf(address(vesting)), 0);
  }

  function test_ownerRescuesAnyTokenSentByMistake() public {
    OverToken stray = new OverToken(1_000 ether);
    stray.transfer(address(vesting), 250 ether);

    vm.expectEmit(true, true, false, true);
    emit Rescued(address(stray), BOB, 100 ether);
    vm.prank(OWNER);
    vesting.rescue(stray, BOB, 100 ether);
    vm.prank(OWNER);
    vesting.rescue(stray, OWNER, 150 ether);

    assertEq(stray.balanceOf(BOB), 100 ether);
    assertEq(stray.balanceOf(OWNER), 150 ether);
    assertEq(stray.balanceOf(address(vesting)), 0);
    assertEq(token.balanceOf(address(vesting)), FUND); // the airdrop token untouched

    // the airdrop token through rescue too
    vm.prank(OWNER);
    vesting.rescue(token, OWNER, 1 ether);
    assertEq(token.balanceOf(OWNER), 1 ether);
  }

  function test_rescueIsOwnerOnlyAndChecksInput() public {
    OverToken stray = new OverToken(1_000 ether);
    stray.transfer(address(vesting), 10 ether);

    vm.prank(ALICE);
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ALICE));
    vesting.rescue(stray, ALICE, 1);

    vm.startPrank(OWNER);
    vm.expectRevert(AirdropVesting.ZeroAddress.selector);
    vesting.rescue(IERC20(address(0)), OWNER, 1);
    vm.expectRevert(AirdropVesting.ZeroAddress.selector);
    vesting.rescue(stray, address(0), 1);
    vm.expectRevert(AirdropVesting.ZeroAmount.selector);
    vesting.rescue(stray, OWNER, 0);
    vm.expectRevert(abi.encodeWithSelector(AirdropVesting.WithdrawExceedsBalance.selector, 10 ether + 1, 10 ether));
    vesting.rescue(stray, OWNER, 10 ether + 1);
    vm.stopPrank();
  }

  function test_plainEthIsRefused() public {
    vm.deal(ALICE, 1 ether);
    vm.prank(ALICE);
    (bool ok,) = address(vesting).call{value: 1 ether}("");
    assertFalse(ok);
    assertEq(address(vesting).balance, 0);
  }

  function test_withdrawIsOwnerOnlyAndChecksInput() public {
    vm.warp(CLAIM_END);
    vm.prank(ALICE);
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ALICE));
    vesting.withdraw(ALICE, 1);

    vm.startPrank(OWNER);
    vm.expectRevert(AirdropVesting.ZeroAddress.selector);
    vesting.withdraw(address(0), 1);
    vm.expectRevert(AirdropVesting.ZeroAmount.selector);
    vesting.withdraw(OWNER, 0);
    vm.stopPrank();
  }

  function test_ownershipCannotBeRenounced() public {
    vm.prank(OWNER);
    vm.expectRevert(AirdropVesting.RenounceDisabled.selector);
    vesting.renounceOwnership();
    assertEq(vesting.owner(), OWNER);
  }

  function test_ownershipMovesInTwoSteps() public {
    address safe = address(0x5AFE);
    vm.prank(OWNER);
    vesting.transferOwnership(safe);
    assertEq(vesting.owner(), OWNER);
    assertEq(vesting.pendingOwner(), safe);

    vm.prank(safe);
    vesting.acceptOwnership();
    assertEq(vesting.owner(), safe);

    vm.warp(CLAIM_END);
    vm.prank(OWNER);
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, OWNER));
    vesting.withdraw(OWNER, 1);
  }

  // ----------------- fuzz -----------------

  /// Claims at any moments never pay more than the vested part, and a claim from day 15 completes it.
  function testFuzz_claimsNeverExceedTheVestedPart(uint32[6] memory gaps) public {
    uint256 t = START;
    for (uint256 i = 0; i < gaps.length; i++) {
      t += uint256(gaps[i]) % (4 days);
      if (t >= CLAIM_END) break;
      vm.warp(t);
      uint256 vestedNow = vesting.vested(BOB);
      if (vestedNow > vesting.claimed(BOB)) {
        vm.prank(BOB);
        vesting.claim();
      }
      assertEq(vesting.claimed(BOB), vestedNow);
      assertLe(vesting.claimed(BOB), BOB_AMOUNT);
    }
    vm.warp(START + 15 days);
    if (vesting.claimed(BOB) < BOB_AMOUNT) {
      vm.prank(BOB);
      vesting.claim();
    }
    assertEq(token.balanceOf(BOB), BOB_AMOUNT);
    assertEq(token.balanceOf(address(vesting)), FUND - BOB_AMOUNT);
  }

  // ----------------- the owner's checklist (2026-10-21) -----------------

  /// 15 days of unlocks, then 15 more days to claim, then claims are blocked.
  function test_fifteenDaysOfUnlocksThenFifteenMoreToClaim() public {
    assertEq(vesting.claimEnd(), START + 30 days);

    vm.warp(START + 15 days - 1);
    assertEq(vesting.unlockedSteps(), 14);
    vm.warp(START + 15 days);
    assertEq(vesting.vested(CAROL), CAROL_AMOUNT); // everything unlocked after 15 days

    // the next 15 days: still claimable, to the last second
    vm.warp(START + 22 days);
    vm.prank(BOB);
    assertEq(vesting.claim(), BOB_AMOUNT);
    vm.warp(START + 30 days - 1);
    assertEq(vesting.claimable(CAROL), CAROL_AMOUNT);
    vm.prank(CAROL);
    assertEq(vesting.claim(), CAROL_AMOUNT);

    // day 30: blocked for everyone, whatever is unclaimed
    vm.warp(START + 30 days);
    assertEq(vesting.claimable(ALICE), 0);
    vm.prank(ALICE);
    vm.expectRevert(abi.encodeWithSelector(AirdropVesting.ClaimWindowClosed.selector, CLAIM_END));
    vesting.claim();
    vm.warp(START + 365 days);
    vm.prank(ALICE);
    vm.expectRevert(abi.encodeWithSelector(AirdropVesting.ClaimWindowClosed.selector, CLAIM_END));
    vesting.claim();
  }

  /// 87 winners (as on mainnet) with uneven amounts, claiming in three patterns, each gets exactly its allocation.
  function test_everyWinnerGetsExactlyItsAllocation() public {
    uint256 n = 87;
    address[] memory winners = new address[](n);
    uint256[] memory amounts = new uint256[](n);
    uint256 total;
    for (uint256 i = 0; i < n; i++) {
      winners[i] = address(uint160(0x1000 + i));
      // uneven, wei-precise amounts from 10 OVER to ~600k OVER
      amounts[i] = 10 ether + (uint256(keccak256(abi.encode(i))) % 600_000 ether);
      total += amounts[i];
    }
    AirdropVesting many = _deploy(winners, amounts);
    token.transfer(address(many), total + 7); // 7 wei of dust over the allocations

    // pattern 0 claims every day, pattern 1 once on day 15, pattern 2 on day 4, day 11 and a second before the end
    for (uint256 day = 1; day <= 15; day++) {
      vm.warp(START + day * 1 days + 1 hours);
      for (uint256 i = 0; i < n; i += 3) {
        vm.prank(winners[i]);
        many.claim();
      }
      if (day == 4 || day == 11) {
        for (uint256 i = 2; i < n; i += 3) {
          vm.prank(winners[i]);
          many.claim();
        }
      }
    }
    vm.warp(START + 15 days);
    for (uint256 i = 1; i < n; i += 3) {
      vm.prank(winners[i]);
      many.claim();
    }
    vm.warp(CLAIM_END - 1);
    for (uint256 i = 2; i < n; i += 3) {
      vm.prank(winners[i]);
      many.claim();
    }

    for (uint256 i = 0; i < n; i++) {
      assertEq(token.balanceOf(winners[i]), amounts[i], "winner balance");
      assertEq(many.claimed(winners[i]), amounts[i], "claimed");
    }
    assertEq(many.totalClaimed(), total);
    assertEq(token.balanceOf(address(many)), 7); // only the dust is left
  }

  // ----------------- helpers -----------------

  function _deploy(address[] memory winners, uint256[] memory amounts) internal returns (AirdropVesting) {
    return new AirdropVesting(token, OWNER, START, winners, amounts);
  }

  function _winners() internal pure returns (address[] memory winners) {
    winners = new address[](3);
    winners[0] = ALICE;
    winners[1] = BOB;
    winners[2] = CAROL;
  }

  function _amounts() internal pure returns (uint256[] memory amounts) {
    amounts = new uint256[](3);
    amounts[0] = ALICE_AMOUNT;
    amounts[1] = BOB_AMOUNT;
    amounts[2] = CAROL_AMOUNT;
  }

  function _pairAddr(address a, address b) internal pure returns (address[] memory pair) {
    pair = new address[](2);
    pair[0] = a;
    pair[1] = b;
  }

  function _pair(uint256 a, uint256 b) internal pure returns (uint256[] memory pair) {
    pair = new uint256[](2);
    pair[0] = a;
    pair[1] = b;
  }
}
