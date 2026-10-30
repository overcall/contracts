// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/// @notice The one router call the exchange route needs (ADR-0021). Uniswap v2 ABI; any v2 fork works.
interface IUniswapV2Router02 {
  function swapExactTokensForTokens(
    uint256 amountIn,
    uint256 amountOutMin,
    address[] calldata path,
    address to,
    uint256 deadline
  ) external returns (uint256[] memory amounts);
}
