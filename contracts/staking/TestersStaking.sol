// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title TestersStaking
 * @notice The testers-rewards entry ticket: hold the OVER token staked here while
 *         testing the product on the testnet. No lockups, no penalties — stake and
 *         unstake at will. The only privileged action is `rescue`, and it can NEVER
 *         reach staked principal: for the staking token it withdraws only the surplus
 *         above totalStaked (stray direct transfers); for any other token, the whole
 *         balance. Owner cannot touch, freeze, or seize anyone's stake.
 *
 *         All reward accounting is off-chain: the backend integrates token-seconds
 *         from the Staked/Unstaked events (each carries the resulting balance, so
 *         a listener never needs storage reads), combines them with testnet play
 *         stats, and a separate claim contract distributes the reward pool later.
 *
 * @dev    ASSUMES a standard ERC20 for the staking token: NOT fee-on-transfer and
 *         NOT rebasing. Both break the 1:1 stake accounting (credited amount vs
 *         received/held balance) and would let the surplus math underflow to zero.
 */
contract TestersStaking is ReentrancyGuard, Ownable {
  using SafeERC20 for IERC20;

  IERC20 public immutable token;

  mapping(address => uint256) public staked;
  uint256 public totalStaked;

  /// @dev `ts` = block.timestamp: the off-chain token-seconds integrator reads it
  ///      straight from the log without a per-event block lookup.
  event Staked(address indexed user, uint256 amount, uint256 balance, uint64 ts);
  event Unstaked(address indexed user, uint256 amount, uint256 balance, uint64 ts);
  event Rescued(address indexed asset, address indexed to, uint256 amount);

  error ZeroAmount();
  error ZeroAddress();
  error InsufficientStake(uint256 requested, uint256 available);
  error RescueExceedsAvailable(uint256 requested, uint256 available);

  constructor(IERC20 token_, address owner_) Ownable(owner_) {
    if (address(token_) == address(0)) revert ZeroAddress();
    token = token_;
  }

  function stake(uint256 amount) external nonReentrant {
    if (amount == 0) revert ZeroAmount();
    staked[msg.sender] += amount;
    totalStaked += amount;
    token.safeTransferFrom(msg.sender, address(this), amount);
    emit Staked(msg.sender, amount, staked[msg.sender], uint64(block.timestamp));
  }

  function unstake(uint256 amount) external nonReentrant {
    uint256 available = staked[msg.sender];
    if (amount == 0) revert ZeroAmount();
    if (amount > available) revert InsufficientStake(amount, available);
    unchecked {
      staked[msg.sender] = available - amount;
      totalStaked -= amount;
    }
    token.safeTransfer(msg.sender, amount);
    emit Unstaked(msg.sender, amount, staked[msg.sender], uint64(block.timestamp));
  }

  /**
   * @notice Withdraw a stuck token. For the staking token this is capped at the
   *         surplus above totalStaked, so staked principal can never be touched;
   *         for any other token the full balance is withdrawable.
   */
  function rescue(IERC20 asset, address to, uint256 amount) external onlyOwner nonReentrant {
    if (to == address(0)) revert ZeroAddress();

    uint256 available = asset.balanceOf(address(this));
    if (asset == token) {
      // never reach staked principal — only the surplus (stray transfers)
      available = available > totalStaked ? available - totalStaked : 0;
    }
    if (amount > available) revert RescueExceedsAvailable(amount, available);

    asset.safeTransfer(to, amount);
    emit Rescued(address(asset), to, amount);
  }
}
