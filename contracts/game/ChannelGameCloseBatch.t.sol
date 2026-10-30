// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ChannelGame} from "./ChannelGame.sol";
import {GameState} from "./GameState.sol";
import {ChannelGameTestBase} from "./ChannelGameTestBase.sol";

/// @dev requestCloseBatch (owner 2026-10-11): one transaction closes a selection of positions; anything that can no
///      longer be closed is skipped instead of reverting the batch.
contract ChannelGameCloseBatchTest is ChannelGameTestBase {
  function _activePosition(address player) internal returns (uint256 pid) {
    pid = _openDefault(GameState.Side.Survive, player);
    _bind(pid, 80_000e18, 0.5e18);
  }

  function _ids(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory ids) {
    ids = new uint256[](3);
    (ids[0], ids[1], ids[2]) = (a, b, c);
  }

  function _status(uint256 pid) internal view returns (GameState.PositionStatus) {
    return game.getPosition(pid).status;
  }

  function test_ClosesEveryPositionInOneCall() public {
    uint256 a = _activePosition(PLAYER);
    uint256 b = _activePosition(PLAYER);
    uint256 c = _activePosition(PLAYER);

    vm.expectEmit(true, false, false, true, address(game));
    emit ChannelGame.CloseRequested(a, uint64(block.timestamp));
    vm.expectEmit(true, false, false, true, address(game));
    emit ChannelGame.CloseRequested(b, uint64(block.timestamp));
    vm.expectEmit(true, false, false, true, address(game));
    emit ChannelGame.CloseRequested(c, uint64(block.timestamp));
    vm.prank(PLAYER);
    uint256 closed = game.requestCloseBatch(_ids(a, b, c));

    assertEq(closed, 3);
    for (uint256 i = 0; i < 3; ++i) {
      uint256 pid = [a, b, c][i];
      assertEq(uint8(_status(pid)), uint8(GameState.PositionStatus.CloseRequested));
      assertEq(game.getPosition(pid).closeRequestTs, block.timestamp);
    }
  }

  function test_SkipsWhatCanNoLongerBeClosed() public {
    uint256 mine = _activePosition(PLAYER);
    uint256 theirs = _activePosition(PLAYER2); // not the caller's
    uint256 unbound = _openDefault(GameState.Side.Survive, PLAYER); // still Requested
    uint256 breached = _activePosition(PLAYER);
    _breachEntry(game.getPosition(breached).channelId, 81_000e18, uint32(block.timestamp + 10));

    uint256[] memory ids = new uint256[](5);
    (ids[0], ids[1], ids[2], ids[3], ids[4]) = (theirs, unbound, breached, mine, mine); // mine twice
    vm.prank(PLAYER);
    uint256 closed = game.requestCloseBatch(ids);

    assertEq(closed, 1);
    assertEq(uint8(_status(mine)), uint8(GameState.PositionStatus.CloseRequested));
    assertEq(uint8(_status(theirs)), uint8(GameState.PositionStatus.Active));
    assertEq(uint8(_status(unbound)), uint8(GameState.PositionStatus.Requested));
    assertEq(uint8(_status(breached)), uint8(GameState.PositionStatus.Active));
  }

  function test_SkipsAPositionWhoseChannelEnded() public {
    uint256 early = _activePosition(PLAYER);
    vm.warp(block.timestamp + 3 hours);
    uint256 late = _activePosition(PLAYER);
    vm.warp(game.getChannel(game.getPosition(early).channelId).endTs); // early's channel just ended

    uint256[] memory ids = new uint256[](2);
    (ids[0], ids[1]) = (early, late);
    vm.prank(PLAYER);
    uint256 closed = game.requestCloseBatch(ids);

    assertEq(closed, 1);
    assertEq(uint8(_status(early)), uint8(GameState.PositionStatus.Active));
    assertEq(uint8(_status(late)), uint8(GameState.PositionStatus.CloseRequested));
  }

  function test_RevertsWhenNothingWasClosed() public {
    uint256 theirs = _activePosition(PLAYER2);
    uint256[] memory ids = new uint256[](2);
    (ids[0], ids[1]) = (theirs, 999_999); // someone else's and a position that does not exist

    vm.prank(PLAYER);
    vm.expectRevert(ChannelGame.NothingToClose.selector);
    game.requestCloseBatch(ids);

    vm.prank(PLAYER);
    vm.expectRevert(ChannelGame.NothingToClose.selector);
    game.requestCloseBatch(new uint256[](0));
  }

  function test_RejectsABatchAboveTheCap() public {
    uint256[] memory ids = new uint256[](game.MAX_CLOSE_BATCH() + 1);
    vm.prank(PLAYER);
    vm.expectRevert(abi.encodeWithSelector(ChannelGame.BatchTooLarge.selector, ids.length));
    game.requestCloseBatch(ids);
  }

  function test_BatchClosedPositionSettlesLikeASingleClose() public {
    uint256 a = _activePosition(PLAYER);
    uint256 b = _activePosition(PLAYER);
    vm.warp(block.timestamp + 10 minutes);
    vm.prank(PLAYER);
    game.requestCloseBatch(_twoIds(a, b));

    _settleCloseEntry(a, 80_000e18, 0.5e18);

    assertEq(uint8(_status(a)), uint8(GameState.PositionStatus.Settled));
    assertEq(uint8(_status(b)), uint8(GameState.PositionStatus.CloseRequested));
  }

  function test_SingleRequestCloseKeepsItsErrors() public {
    uint256 theirs = _activePosition(PLAYER2);
    vm.prank(PLAYER);
    vm.expectRevert(abi.encodeWithSelector(ChannelGame.NotPositionOwner.selector, theirs));
    game.requestClose(theirs);
  }

  function _twoIds(uint256 a, uint256 b) internal pure returns (uint256[] memory ids) {
    ids = new uint256[](2);
    (ids[0], ids[1]) = (a, b);
  }
}
