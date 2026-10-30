// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniswapV2Router02} from "../interfaces/IUniswapV2Router02.sol";

/**
 * @title MockRouter
 * @notice Uniswap v2-shaped router for tests: pulls `path[0]`, pays `path[last]` from its own balance
 *         at a fixed rate (`amountIn × rateNum / rateDen`), honours `amountOutMin` and `deadline`,
 *         and can be switched off to simulate a dead route.
 */
contract MockRouter is IUniswapV2Router02 {
  using SafeERC20 for IERC20;

  error Expired();
  error InsufficientOutput(uint256 out, uint256 min);
  error Broken();

  uint256 public rateNum = 1;
  uint256 public rateDen = 1;
  bool public broken;
  uint256 public lastAmountIn;
  address[] public lastPath;

  function setRate(uint256 num, uint256 den) external {
    rateNum = num;
    rateDen = den;
  }

  function setBroken(bool b) external {
    broken = b;
  }

  function swapExactTokensForTokens(
    uint256 amountIn,
    uint256 amountOutMin,
    address[] calldata path,
    address to,
    uint256 deadline
  ) external returns (uint256[] memory amounts) {
    if (broken) revert Broken();
    if (block.timestamp > deadline) revert Expired();
    uint256 out = (amountIn * rateNum) / rateDen;
    if (out < amountOutMin) revert InsufficientOutput(out, amountOutMin);
    IERC20(path[0]).safeTransferFrom(msg.sender, address(this), amountIn);
    IERC20(path[path.length - 1]).safeTransfer(to, out);
    lastAmountIn = amountIn;
    delete lastPath;
    for (uint256 i = 0; i < path.length; i++) lastPath.push(path[i]);
    amounts = new uint256[](path.length);
    amounts[0] = amountIn;
    amounts[path.length - 1] = out;
  }
}
