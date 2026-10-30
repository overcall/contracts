// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {GameState as S} from "./GameState.sol";
import {Vault} from "../vault/Vault.sol";
import {IUniswapV2Router02} from "../interfaces/IUniswapV2Router02.sol";

/**
 * @title ClaimLogic
 * @notice Royalty claims per currency (ADR-0018/0021) — an external library, delegatecalled by the
 *         game, kept out of ChannelGame for size. OVER royalty is paid as is. Royalty in any other
 *         currency is converted into OVER along the exchange route (router: timelock; path: admin)
 *         and lands in the owner's wallet; an account below the currency's dust floor is paid raw,
 *         because converting it would revert and lock the claim.
 */
library ClaimLogic {
  using SafeERC20 for IERC20;

  event RoyaltyClaimed(uint256 indexed channelId, address indexed owner, uint256 amount);
  event RoyaltyClaimedIn(uint256 indexed channelId, address indexed owner, uint8 indexed currencyId, uint256 amount);
  event RoyaltyConverted(address indexed owner, uint8 indexed currencyId, uint256 amountIn, uint256 amountOut);

  error NotChannelOwner(uint256 channelId);
  error ChannelNotClaimable(uint256 channelId);
  error UnknownCurrency(uint8 currencyId);
  error RouteNotSet(uint8 currencyId);
  error Reentrancy();

  /**
   * @notice Claims the royalty of each channel in one currency. Rules per channel (ADR-0018): owner,
   *         closed, every position settled, not yet claimed in this currency.
   * @param minOverOut  Minimum OVER for the whole conversion (ignored for currency 0).
   * @param deadline    Swap deadline (ignored for currency 0).
   */
  function claim(uint256[] calldata channelIds, uint8 currencyId, uint256 minOverOut, uint256 deadline) external {
    S.GameStorage storage $ = S.s();
    if (currencyId >= $.currencyCount) revert UnknownCurrency(currencyId);
    if ($.reentrancy != 0) revert Reentrancy();
    $.reentrancy = 1;

    Vault vault = S.vaultOf($, currencyId);
    // currency 0 pays the owner directly; others are collected here and converted in one swap
    address payTo = currencyId == 0 ? msg.sender : address(this);
    IERC20 token = IERC20($.currencyTokens[currencyId]);
    uint256 balanceBefore = currencyId == 0 ? 0 : token.balanceOf(address(this));
    for (uint256 i = 0; i < channelIds.length; i++) {
      uint256 id = channelIds[i];
      S.Channel storage c = $.channels[id];
      if (IERC721(address(this)).ownerOf(id) != msg.sender) revert NotChannelOwner(id);
      bool closed = c.breachedAt != 0 || block.timestamp > c.endTs;
      if (!closed || c.openPositions != 0 || _claimed(c, currencyId)) revert ChannelNotClaimable(id);
      _markClaimed(c, currencyId);
      uint256 amount = vault.payRoyalty(id, payTo);
      if (currencyId == 0) emit RoyaltyClaimed(id, msg.sender, amount);
      else emit RoyaltyClaimedIn(id, msg.sender, currencyId, amount);
    }

    // convert what actually arrived, not what the vault reported: a refused transfer (owed to the game) or a
    // fee-on-transfer token must never let the claim spend tokens that happen to sit in the game
    if (currencyId != 0) {
      uint256 received = token.balanceOf(address(this)) - balanceBefore;
      if (received != 0) _convert($, currencyId, received, minOverOut, deadline);
    }
    $.reentrancy = 0;
  }

  /// @dev Converts the collected amount into OVER for the claimant, or pays it raw under the dust floor.
  function _convert(S.GameStorage storage $, uint8 currencyId, uint256 amount, uint256 minOverOut, uint256 deadline) private {
    IERC20 token = IERC20($.currencyTokens[currencyId]);
    if (amount < $.currencies[currencyId].dustFloor) {
      token.safeTransfer(msg.sender, amount);
      emit RoyaltyConverted(msg.sender, currencyId, amount, 0);
      return;
    }
    address[] storage path = $.routePaths[currencyId];
    if ($.router == address(0) || path.length < 2) revert RouteNotSet(currencyId);
    token.forceApprove($.router, amount);
    uint256[] memory amounts =
      IUniswapV2Router02($.router).swapExactTokensForTokens(amount, minOverOut, path, msg.sender, deadline);
    emit RoyaltyConverted(msg.sender, currencyId, amount, amounts[amounts.length - 1]);
  }

  /// @notice Transfer lock (ADR-0018/0021): a closed, fully settled channel whose royalty is claimed
  ///         or empty in every currency is a spent object and must not be sold.
  function isTransferLocked(uint256 channelId) external view returns (bool) {
    S.GameStorage storage $ = S.s();
    S.Channel storage c = $.channels[channelId];
    bool closed = c.breachedAt != 0 || block.timestamp > c.endTs;
    if (!closed || c.openPositions != 0) return false;
    uint8 count = $.currencyCount == 0 ? 1 : $.currencyCount; // pre-v3 state: only OVER exists
    for (uint8 i = 0; i < count; i++) {
      if (_claimed(c, i)) continue;
      if (S.vaultOf($, i).royaltyOf(address(this), channelId) != 0) return false;
    }
    return true;
  }

  /// @dev OVER keeps the v2 bool; other currencies use bit (id − 1) of `claimedOthers`.
  function _claimed(S.Channel storage c, uint8 currencyId) private view returns (bool) {
    return currencyId == 0 ? c.royaltyClaimed : (c.claimedOthers & uint8(1 << (currencyId - 1))) != 0;
  }

  function _markClaimed(S.Channel storage c, uint8 currencyId) private {
    if (currencyId == 0) c.royaltyClaimed = true;
    else c.claimedOthers |= uint8(1 << (currencyId - 1));
  }
}
