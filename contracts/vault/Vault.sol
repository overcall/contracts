// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessRegistry} from "../access/AccessRegistry.sol";

/**
 * @title Vault
 * @notice OVER custody and protocol accounting (CONTEXT: Vault). Vault is the source of
 *         truth for money and knows NOTHING about game rules: game-driven money movements are
 *         available only to the game contract and must reconcile against a verifiable balance.
 *         Requirement for the production OVER token: a plain ERC-20 with no recipient hooks
 *         (not ERC-777-like) — transfers must not hand off control.
 *
 *         One vault per currency (ADR-0021): this contract knows one token; the game routes a
 *         position's money to the vault of its currency.
 *
 *         Pockets (all in the vault's token):
 *         - capital — what the protocol is liable for on rewards; deposited by the admin and
 *           credited with lost working amounts at settlement (ADR-0022, amending ADR-0013);
 *           withdrawn in two steps with a 3-day delay and only the free portion;
 *         - reserve — the part of capital earmarked for open-position rewards
 *           (ADR-0004);
 *         - open-position deposits — player money before settlement;
 *         - revenue — fees (ADR-0013), withdrawn by the admin with no delay, or moved into
 *           capital with no delay;
 *         - channel royalty accounts — the profit-fee share keyed by channel id (ADR-0018);
 *         - owed payouts — money a recipient refused (a frozen stablecoin address): settlement
 *           never depends on the recipient, the amount waits for them here (ADR-0022).
 *
 *         Invariant (tested): balance ≥ deposits + capital + revenue + royalties + owed.
 *         Reserve ≤ capital. A position settlement must reconcile:
 *         deposit + fromCapital == toPlayer + toRevenue + toRoyalty + toCapital.
 *
 * @dev UUPS (ADR-0009), ERC-7201 storage. The game contract is set by the admin —
 *      once, and only on an empty vault: immutability substitutes for a timelock gate; any further
 *      game change is possible only via an upgrade of its proxy (timelock).
 *      v3 storage is appended only (owedOf, owedTotal); the v2 `settle` signature stays as a
 *      wrapper so no existing caller or test changes.
 */
contract Vault is Initializable, UUPSUpgradeable {
  using SafeERC20 for IERC20;

  uint256 public constant CAPITAL_WITHDRAWAL_DELAY = 3 days;

  /// @custom:storage-location erc7201:overcall.vault
  struct VaultStorage {
    IERC20 token;
    AccessRegistry access;
    address game;
    // pockets
    uint256 capital; // includes the reserved portion
    uint256 reservedTotal;
    uint256 heldDeposits;
    uint256 revenue;
    uint256 royaltyTotal;
    // royalties namespaced by game: future games on the same Vault won't collide on channel ids
    mapping(address game => mapping(uint256 channelId => uint256)) royaltyOf;
    // two-step capital withdrawal
    uint256 pendingCapitalWithdrawal;
    uint64 capitalWithdrawalReadyAt;
    // v3 (ADR-0022): payouts a recipient refused, waiting for them to withdraw
    mapping(address recipient => uint256) owedOf;
    uint256 owedTotal;
  }

  // keccak256(abi.encode(uint256(keccak256("overcall.vault")) - 1)) & ~bytes32(uint256(0xff))
  bytes32 private constant STORAGE_SLOT = 0x9672d6743b10424161d47c4458becccd3923e1b483a57f80171d67c89ba88f00;

  function _s() private pure returns (VaultStorage storage $) {
    assembly {
      $.slot := STORAGE_SLOT
    }
  }

  // ----------------- Events -----------------

  event GameSet(address indexed game);
  event CapitalDeposited(address indexed from, uint256 amount);
  event CapitalWithdrawalRequested(uint256 amount, uint64 readyAt);
  event CapitalWithdrawalCancelled();
  event CapitalWithdrawn(address indexed to, uint256 amount);
  event RevenueWithdrawn(address indexed to, uint256 amount);
  event DepositCollected(address indexed from, uint256 amount);
  event Reserved(uint256 amount);
  event Released(uint256 amount);
  event Settled(
    uint256 depositIn, uint256 fromCapital, address indexed to, uint256 toPlayer, uint256 toRevenue,
    uint256 indexed royaltyChannelId, uint256 toRoyalty
  );
  event RoyaltyPaid(uint256 indexed channelId, address indexed to, uint256 amount);
  // v3 — additive: `Settled` keeps its v2 signature, the capital leg gets its own event
  event CapitalCredited(uint256 amount);
  event RevenueMovedToCapital(uint256 amount);
  event PayoutOwed(address indexed to, uint256 amount);
  event OwedWithdrawn(address indexed to, uint256 amount);

  // ----------------- Errors -----------------

  error NotAdmin();
  /// @dev An inflow arrived short of the requested amount (a transfer tax): refused, never booked (audit 2026-10-19, H-01).
  error InboundShortfall(uint256 requested, uint256 received);
  error NotTimelock();
  error NotGame();
  error ZeroAddress();
  error GameAlreadySet();
  error VaultNotEmpty();
  error InsufficientFreeCapital(uint256 requested, uint256 free);
  error InsufficientReserve(uint256 requested, uint256 reserved);
  error InsufficientRevenue(uint256 requested, uint256 available);
  error InsufficientDeposits(uint256 requested, uint256 held);
  error SettlementImbalance(uint256 inflow, uint256 outflow);
  error NoPendingWithdrawal();
  error WithdrawalNotReady(uint64 readyAt);
  error WithdrawalAlreadyPending();
  error NothingOwed(address to);
  error TransferFailed(address to, uint256 amount);

  // ----------------- Modifiers -----------------

  modifier onlyAdmin() {
    if (!_s().access.isAdmin(msg.sender)) revert NotAdmin();
    _;
  }

  modifier onlyTimelock() {
    if (!_s().access.isTimelock(msg.sender)) revert NotTimelock();
    _;
  }

  modifier onlyGame() {
    if (msg.sender != _s().game) revert NotGame();
    _;
  }

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  function initialize(address access_, address token_) external initializer {
    if (access_ == address(0) || token_ == address(0)) revert ZeroAddress();
    _s().access = AccessRegistry(access_);
    _s().token = IERC20(token_);
  }

  /// @notice The game contract: set by the admin, once, and only on an empty
  ///         vault (nothing to steal). It cannot be changed afterward — only by upgrading the game
  ///         through its proxy (timelock, ADR-0009).
  function setGame(address game_) external onlyAdmin {
    VaultStorage storage $ = _s();
    if (game_ == address(0)) revert ZeroAddress();
    if ($.game != address(0)) revert GameAlreadySet();
    if ($.capital != 0 || $.heldDeposits != 0 || $.revenue != 0) revert VaultNotEmpty();
    $.game = game_;
    emit GameSet(game_);
  }

  // ----------------- Capital (admin / timelock via the delay built into Vault) -----------------

  /// @notice Capital deposit by the admin (requires an approve on Vault).
  function depositCapital(uint256 amount) external onlyAdmin {
    _pullExact(msg.sender, amount);
    _s().capital += amount;
    emit CapitalDeposited(msg.sender, amount);
  }

  /**
   * @notice Two-step capital withdrawal: request → 3 days → execution. The delay
   *         is enforced by Vault itself and does not depend on timelock discipline.
   *         Both at request and at execution the amount is bounded by the free portion.
   */
  function requestCapitalWithdrawal(uint256 amount) external onlyAdmin {
    VaultStorage storage $ = _s();
    if ($.pendingCapitalWithdrawal != 0) revert WithdrawalAlreadyPending();
    uint256 free = $.capital - $.reservedTotal;
    if (amount == 0 || amount > free) revert InsufficientFreeCapital(amount, free);
    $.pendingCapitalWithdrawal = amount;
    $.capitalWithdrawalReadyAt = uint64(block.timestamp + CAPITAL_WITHDRAWAL_DELAY);
    emit CapitalWithdrawalRequested(amount, $.capitalWithdrawalReadyAt);
  }

  function cancelCapitalWithdrawal() external onlyAdmin {
    if (_s().pendingCapitalWithdrawal == 0) revert NoPendingWithdrawal();
    _s().pendingCapitalWithdrawal = 0;
    _s().capitalWithdrawalReadyAt = 0;
    emit CapitalWithdrawalCancelled();
  }

  function executeCapitalWithdrawal(address to) external onlyAdmin {
    VaultStorage storage $ = _s();
    uint256 amount = $.pendingCapitalWithdrawal;
    if (amount == 0) revert NoPendingWithdrawal();
    if (block.timestamp < $.capitalWithdrawalReadyAt) revert WithdrawalNotReady($.capitalWithdrawalReadyAt);
    uint256 free = $.capital - $.reservedTotal;
    if (amount > free) revert InsufficientFreeCapital(amount, free);
    $.pendingCapitalWithdrawal = 0;
    $.capitalWithdrawalReadyAt = 0;
    $.capital -= amount;
    $.token.safeTransfer(to, amount);
    emit CapitalWithdrawn(to, amount);
  }

  /// @notice Revenue is withdrawn by the admin with no delay (ADR-0013: it's not collateral).
  function withdrawRevenue(address to, uint256 amount) external onlyAdmin {
    VaultStorage storage $ = _s();
    if (amount > $.revenue) revert InsufficientRevenue(amount, $.revenue);
    $.revenue -= amount;
    $.token.safeTransfer(to, amount);
    emit RevenueWithdrawn(to, amount);
  }

  /// @notice Moves fees into the bankroll (ADR-0022). No delay: money entering the protected
  ///         pocket needs none; it leaves again only through the delayed capital withdrawal.
  function revenueToCapital(uint256 amount) external onlyAdmin {
    VaultStorage storage $ = _s();
    if (amount > $.revenue) revert InsufficientRevenue(amount, $.revenue);
    $.revenue -= amount;
    $.capital += amount;
    emit RevenueMovedToCapital(amount);
  }

  /// @notice A recipient the token refused (ADR-0022: a frozen stablecoin address) collects what
  ///         the vault owes them, once the token accepts them again. Paid to the caller only —
  ///         the vault never helps money around a freeze.
  function withdrawOwed() external {
    VaultStorage storage $ = _s();
    uint256 amount = $.owedOf[msg.sender];
    if (amount == 0) revert NothingOwed(msg.sender);
    $.owedOf[msg.sender] = 0;
    $.owedTotal -= amount;
    if (!_tryTransfer(msg.sender, amount)) revert TransferFailed(msg.sender, amount);
    emit OwedWithdrawn(msg.sender, amount);
  }

  // ----------------- Game-driven movements (game contract only) -----------------

  /// @notice Pull a request's deposit from the payer (requires the player's approve on Vault).
  function collectDeposit(address from, uint256 amount) external onlyGame {
    _pullExact(from, amount);
    _s().heldDeposits += amount;
    emit DepositCollected(from, amount);
  }

  /// @notice Reserve a reward out of capital (ADR-0004).
  function reserve(uint256 amount) external onlyGame {
    VaultStorage storage $ = _s();
    uint256 free = $.capital - $.reservedTotal;
    if (amount > free) revert InsufficientFreeCapital(amount, free);
    $.reservedTotal += amount;
    emit Reserved(amount);
  }

  /// @notice Release part of the reserve (trueing up at binding, refunds, losses).
  function release(uint256 amount) external onlyGame {
    VaultStorage storage $ = _s();
    if (amount > $.reservedTotal) revert InsufficientReserve(amount, $.reservedTotal);
    $.reservedTotal -= amount;
    emit Released(amount);
  }

  /**
   * @notice Settles a position in one call. Vault checks that the money reconciles:
   *         `depositIn + fromCapital == toPlayer + toRevenue + toRoyalty + toCapital`.
   * @param depositIn        How much of the position's deposit leaves the deposits pocket.
   * @param fromCapital      How much of the reward is paid from capital (no reserve here:
   *                         the game releases the exact reserve amount via a separate `release`).
   * @param to               The payout recipient (position owner).
   * @param toPlayer         Payout to the player. If the token refuses the recipient, the amount
   *                         is booked as owed to them instead of reverting (ADR-0022).
   * @param toRevenue        To revenue (fees).
   * @param royaltyChannelId The channel for the royalty (0 is allowed when toRoyalty == 0).
   * @param toRoyalty        To the channel's royalty account.
   * @param toCapital        To capital: the lost working amount, or an early-close shortfall
   *                         (ADR-0022, amending ADR-0013).
   */
  function settle(
    uint256 depositIn,
    uint256 fromCapital,
    address to,
    uint256 toPlayer,
    uint256 toRevenue,
    uint256 royaltyChannelId,
    uint256 toRoyalty,
    uint256 toCapital
  ) public onlyGame {
    VaultStorage storage $ = _s();
    uint256 outflow = toPlayer + toRevenue + toRoyalty + toCapital;
    if (depositIn + fromCapital != outflow) revert SettlementImbalance(depositIn + fromCapital, outflow);
    if (depositIn > $.heldDeposits) revert InsufficientDeposits(depositIn, $.heldDeposits);
    // the game releases the exact reserve before settle → the reward is paid out of the free portion
    uint256 freeCapital = $.capital - $.reservedTotal;
    if (fromCapital > freeCapital) revert InsufficientFreeCapital(fromCapital, freeCapital);

    $.heldDeposits -= depositIn;
    $.capital = $.capital - fromCapital + toCapital;
    $.revenue += toRevenue;
    if (toRoyalty != 0) {
      $.royaltyTotal += toRoyalty;
      $.royaltyOf[msg.sender][royaltyChannelId] += toRoyalty;
    }
    if (toPlayer != 0) _payOrOwe(to, toPlayer);
    emit Settled(depositIn, fromCapital, to, toPlayer, toRevenue, royaltyChannelId, toRoyalty);
    if (toCapital != 0) emit CapitalCredited(toCapital);
  }

  /// @notice v2 signature, kept for callers that have no capital leg (`toCapital = 0`).
  function settle(
    uint256 depositIn,
    uint256 fromCapital,
    address to,
    uint256 toPlayer,
    uint256 toRevenue,
    uint256 royaltyChannelId,
    uint256 toRoyalty
  ) external {
    settle(depositIn, fromCapital, to, toPlayer, toRevenue, royaltyChannelId, toRoyalty, 0);
  }

  /// @notice Pays out a channel's accrued royalty (claim rules are checked by the game, ADR-0018).
  ///         A refused recipient is booked as owed, like a payout.
  function payRoyalty(uint256 channelId, address to) external onlyGame returns (uint256 amount) {
    VaultStorage storage $ = _s();
    amount = $.royaltyOf[msg.sender][channelId];
    if (amount != 0) {
      $.royaltyOf[msg.sender][channelId] = 0;
      $.royaltyTotal -= amount;
      _payOrOwe(to, amount);
    }
    emit RoyaltyPaid(channelId, to, amount);
  }

  // ----------------- Payout plumbing (ADR-0022: settlement never depends on the recipient) -----------------

  /// @dev Pull exactly `amount` or revert. Every exit pays against the booked amount, so a short
  ///      inflow (an OVER pool tax the token owner can switch on) must never be booked (audit
  ///      2026-10-19, H-01): crediting only the delta would still refund the nominal deposit.
  function _pullExact(address from, uint256 amount) private {
    IERC20 asset = _s().token;
    uint256 before = asset.balanceOf(address(this));
    asset.safeTransferFrom(from, address(this), amount);
    uint256 received = asset.balanceOf(address(this)) - before;
    if (received != amount) revert InboundShortfall(amount, received);
  }

  /// @dev Transfer, or book the amount as owed when the token refuses the recipient.
  function _payOrOwe(address to, uint256 amount) private {
    if (_tryTransfer(to, amount)) return;
    VaultStorage storage $ = _s();
    // a vault short of its own token is broken accounting, not a refusing recipient: fail loudly
    if ($.token.balanceOf(address(this)) < amount) revert TransferFailed(to, amount);
    $.owedOf[to] += amount;
    $.owedTotal += amount;
    emit PayoutOwed(to, amount);
  }

  /// @dev ERC-20 transfer that reports failure instead of reverting: a revert (frozen address),
  ///      a `false` return, or a non-contract token all count as failure. Mirrors SafeERC20's
  ///      acceptance of empty return data.
  function _tryTransfer(address to, uint256 amount) private returns (bool) {
    address token_ = address(_s().token);
    (bool ok, bytes memory ret) = token_.call(abi.encodeCall(IERC20.transfer, (to, amount)));
    if (!ok || token_.code.length == 0) return false;
    if (ret.length == 0) return true;
    // strict: exactly a true word; anything else (short data, non-boolean) counts as a refusal, never a revert
    return ret.length >= 32 && uint256(bytes32(ret)) == 1;
  }

  // ----------------- Views -----------------

  function token() external view returns (address) {
    return address(_s().token);
  }

  function game() external view returns (address) {
    return _s().game;
  }

  function capital() external view returns (uint256) {
    return _s().capital;
  }

  function reservedTotal() external view returns (uint256) {
    return _s().reservedTotal;
  }

  function freeCapital() external view returns (uint256) {
    return _s().capital - _s().reservedTotal;
  }

  function heldDeposits() external view returns (uint256) {
    return _s().heldDeposits;
  }

  function revenue() external view returns (uint256) {
    return _s().revenue;
  }

  function royaltyOf(address game_, uint256 channelId) external view returns (uint256) {
    return _s().royaltyOf[game_][channelId];
  }

  function royaltyTotal() external view returns (uint256) {
    return _s().royaltyTotal;
  }

  function pendingCapitalWithdrawal() external view returns (uint256 amount, uint64 readyAt) {
    return (_s().pendingCapitalWithdrawal, _s().capitalWithdrawalReadyAt);
  }

  function owedOf(address to) external view returns (uint256) {
    return _s().owedOf[to];
  }

  function owedTotal() external view returns (uint256) {
    return _s().owedTotal;
  }

  /// @notice Accounting invariant: the balance covers all liabilities.
  function solvent() external view returns (bool) {
    VaultStorage storage $ = _s();
    return $.token.balanceOf(address(this))
      >= $.heldDeposits + $.capital + $.revenue + $.royaltyTotal + $.owedTotal;
  }

  // ----------------- UUPS -----------------

  function _authorizeUpgrade(address) internal override onlyTimelock {}
}
