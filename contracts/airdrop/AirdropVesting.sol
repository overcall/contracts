// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
 * @title AirdropVesting
 * @notice The Genesis airdrop payout (owner 2026-10-20): every winner of the final
 *         airdrop board gets a fixed allocation, set once in the constructor, that
 *         unlocks in 15 equal daily steps — the first one day after `start`, the last
 *         fifteen days after it. A winner claims what has unlocked at any time before
 *         `claimEnd` (30 days after `start`); after it nothing can be claimed.
 *
 *         The owner withdraws any amount of the token to any address at any time
 *         (owner 2026-10-21), up to the whole balance — a claim then reverts until
 *         the contract is funded again. After `claimEnd` that is how the unclaimed
 *         rewards flow into the vault (Vault.depositCapital is admin-only). Any other
 *         ERC20 sent here by mistake is returned with `rescue`. The owner cannot change
 *         an allocation, and ownership cannot be renounced: that would lock the
 *         leftover forever. Plain ETH transfers revert (no receive function).
 *
 *         Funding is a plain transfer after the deploy; a claim before it reverts on
 *         the transfer.
 *
 * @dev    ASSUMES a standard ERC20 token: NOT fee-on-transfer and NOT rebasing (a
 *         claim pays exactly the vested amount).
 */
contract AirdropVesting is ReentrancyGuard, Ownable2Step {
  using SafeERC20 for IERC20;

  uint256 public constant STEPS = 15;
  uint256 public constant STEP = 1 days;
  uint256 public constant CLAIM_WINDOW = 30 days;

  IERC20 public immutable token;
  /// @notice Unix time the vesting starts; step k (1..15) unlocks at start + k days.
  uint64 public immutable start;
  /// @notice Claims are accepted strictly before this moment (start + 30 days).
  uint64 public immutable claimEnd;
  /// @notice Sum of every allocation.
  uint256 public immutable totalAllocated;

  mapping(address => uint256) public allocation;
  mapping(address => uint256) public claimed;
  uint256 public totalClaimed;

  event Allocated(address indexed winner, uint256 amount);
  event Claimed(address indexed winner, uint256 amount, uint256 claimedTotal);
  event Withdrawn(address indexed to, uint256 amount);
  event Rescued(address indexed asset, address indexed to, uint256 amount);

  error ZeroAddress();
  error ZeroAmount();
  error LengthMismatch(uint256 winners, uint256 amounts);
  error DuplicateWinner(address winner);
  error NotAWinner(address account);
  error NothingToClaim();
  error ClaimWindowClosed(uint64 claimEnd);
  error WithdrawExceedsBalance(uint256 requested, uint256 balance);
  error RenounceDisabled();

  constructor(
    IERC20 token_,
    address owner_,
    uint64 start_,
    address[] memory winners,
    uint256[] memory amounts
  ) Ownable(owner_) {
    if (address(token_) == address(0)) revert ZeroAddress();
    if (start_ == 0) revert ZeroAmount();
    if (winners.length != amounts.length) revert LengthMismatch(winners.length, amounts.length);
    token = token_;
    start = start_;
    claimEnd = start_ + uint64(CLAIM_WINDOW);
    totalAllocated = _allocate(winners, amounts);
  }

  // ----------------- winners -----------------

  /// @notice Sends the caller everything unlocked and not claimed yet.
  function claim() external nonReentrant returns (uint256 amount) {
    if (block.timestamp >= claimEnd) revert ClaimWindowClosed(claimEnd);
    if (allocation[msg.sender] == 0) revert NotAWinner(msg.sender);
    amount = vested(msg.sender) - claimed[msg.sender];
    if (amount == 0) revert NothingToClaim();
    claimed[msg.sender] += amount;
    totalClaimed += amount;
    token.safeTransfer(msg.sender, amount);
    emit Claimed(msg.sender, amount, claimed[msg.sender]);
  }

  /// @notice Steps unlocked so far, 0..STEPS.
  function unlockedSteps() public view returns (uint256) {
    if (block.timestamp < start) return 0;
    uint256 steps = (block.timestamp - start) / STEP;
    return steps > STEPS ? STEPS : steps;
  }

  /// @notice The part of the winner's allocation unlocked so far (claimed or not).
  function vested(address winner) public view returns (uint256) {
    return (allocation[winner] * unlockedSteps()) / STEPS;
  }

  /// @notice What `claim` would send the winner now; 0 once the claim window has closed.
  function claimable(address winner) external view returns (uint256) {
    if (block.timestamp >= claimEnd) return 0;
    return vested(winner) - claimed[winner];
  }

  /// @notice When the next step unlocks; 0 once every step has.
  function nextUnlockAt() external view returns (uint64) {
    uint256 steps = unlockedSteps();
    if (steps == STEPS) return 0;
    return start + uint64((steps + 1) * STEP);
  }

  // ----------------- owner -----------------

  /// @notice Still owed to the winners: unclaimed allocations before claimEnd, 0 after it (informational).
  function outstanding() external view returns (uint256) {
    if (block.timestamp >= claimEnd) return 0;
    return totalAllocated - totalClaimed;
  }

  /// @notice Sends `amount` of the token to `to`: any amount up to the whole balance, at any time.
  function withdraw(address to, uint256 amount) external onlyOwner nonReentrant {
    if (to == address(0)) revert ZeroAddress();
    if (amount == 0) revert ZeroAmount();
    uint256 balance = token.balanceOf(address(this));
    if (amount > balance) revert WithdrawExceedsBalance(amount, balance);
    token.safeTransfer(to, amount);
    emit Withdrawn(to, amount);
  }

  /// @notice Sends `amount` of any ERC20 held here (one sent by mistake; the airdrop token too) to `to`.
  function rescue(IERC20 asset, address to, uint256 amount) external onlyOwner nonReentrant {
    if (address(asset) == address(0) || to == address(0)) revert ZeroAddress();
    if (amount == 0) revert ZeroAmount();
    uint256 balance = asset.balanceOf(address(this));
    if (amount > balance) revert WithdrawExceedsBalance(amount, balance);
    asset.safeTransfer(to, amount);
    emit Rescued(address(asset), to, amount);
  }

  /// @dev Disabled: without an owner the leftover after claimEnd would be locked forever.
  function renounceOwnership() public view override onlyOwner {
    revert RenounceDisabled();
  }

  function _allocate(address[] memory winners, uint256[] memory amounts) private returns (uint256 total) {
    for (uint256 i = 0; i < winners.length; i++) {
      address winner = winners[i];
      if (winner == address(0)) revert ZeroAddress();
      if (amounts[i] == 0) revert ZeroAmount();
      if (allocation[winner] != 0) revert DuplicateWinner(winner);
      allocation[winner] = amounts[i];
      total += amounts[i];
      emit Allocated(winner, amounts[i]);
    }
  }
}
