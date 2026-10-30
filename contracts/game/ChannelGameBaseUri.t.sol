// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {ChannelGame} from "./ChannelGame.sol";
import {GameState} from "./GameState.sol";
import {ChannelGameTestBase} from "./ChannelGameTestBase.sol";

/// @dev Channel NFT metadata (owner 2026-10-19): the admin sets a base URI, tokenURI = base + channel id.
contract ChannelGameBaseUriTest is ChannelGameTestBase {
  string constant BASE = "https://api.overcall.io/nft/channel/";

  function _channel() internal returns (uint256 channelId) {
    uint256 pid = _openDefault(GameState.Side.Survive, PLAYER);
    channelId = game.getPosition(pid).channelId;
  }

  function test_TokenUriIsEmptyUntilTheAdminSetsABase() public {
    uint256 channelId = _channel();
    assertEq(game.tokenURI(channelId), "");
  }

  function test_AdminSetsTheBaseAndTokenUriAppendsTheChannelId() public {
    uint256 channelId = _channel();

    vm.expectEmit(false, false, false, true, address(game));
    emit ChannelGame.BaseURISet(BASE);
    vm.expectEmit(false, false, false, true, address(game));
    emit ChannelGame.BatchMetadataUpdate(0, type(uint256).max);
    vm.prank(ADMIN);
    game.setBaseURI(BASE);

    assertEq(game.tokenURI(channelId), string.concat(BASE, Strings.toString(channelId)));
  }

  function test_TheAdminCanChangeAndClearTheBase() public {
    uint256 channelId = _channel();
    vm.startPrank(ADMIN);
    game.setBaseURI(BASE);
    game.setBaseURI("ipfs://bafy/");
    vm.stopPrank();
    assertEq(game.tokenURI(channelId), string.concat("ipfs://bafy/", Strings.toString(channelId)));

    vm.prank(ADMIN);
    game.setBaseURI("");
    assertEq(game.tokenURI(channelId), "");
  }

  function test_OnlyTheAdminSetsTheBase() public {
    for (uint256 i = 0; i < 3; ++i) {
      address caller = [PLAYER, GUARDIAN, TIMELOCK][i];
      vm.prank(caller);
      vm.expectRevert(ChannelGame.NotAdmin.selector);
      game.setBaseURI(BASE);
    }
  }

  function test_AnUnknownChannelStillReverts() public {
    vm.prank(ADMIN);
    game.setBaseURI(BASE);
    vm.expectRevert();
    game.tokenURI(999_999);
  }

  function test_SupportsErc4906AndErc721() public view {
    assertTrue(game.supportsInterface(0x49064906)); // ERC-4906
    assertTrue(game.supportsInterface(0x80ac58cd)); // ERC-721
    assertTrue(game.supportsInterface(0x5b5e139f)); // ERC-721 metadata
    assertTrue(game.supportsInterface(0x01ffc9a7)); // ERC-165
    assertFalse(game.supportsInterface(0xffffffff));
  }
}
