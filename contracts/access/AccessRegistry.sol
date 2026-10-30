// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @title AccessRegistry
 * @notice Single protocol role registry (CONTEXT: Access). Other contracts
 *         check permissions here and keep no lists of their own.
 *
 *         Roles:
 *         - DEFAULT_ADMIN_ROLE — the timelock (ADR-0009): root of trust; manages
 *           admins and the upgrade right of all proxies.
 *         - ADMIN_ROLE — admin: changes configurations and bounds (request
 *           acceptance conditions, but not their outcome); manages operators and guardians so
 *           key rotation doesn't have to wait on the timelock.
 *         - OPERATOR_ROLE — operator: binding, breaches, settlement, trading window
 *           rotation; signs volatility quotes (ADR-0016) and brings P (ADR-0019).
 *         - GUARDIAN_ROLE — can only pause request acceptance.
 *
 * @dev UUPS; has no storage of its own — everything lives in OpenZeppelin's namespaced
 *      slots (ERC-7201). Upgrade — only DEFAULT_ADMIN_ROLE, i.e. the timelock.
 */
contract AccessRegistry is Initializable, AccessControlUpgradeable, UUPSUpgradeable {
  bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
  bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
  bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

  error ZeroAddress();

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  /**
   * @param timelock The protocol's timelock — receives DEFAULT_ADMIN_ROLE and the upgrade right.
   * @param admin    The first admin (can be a multisig).
   * @param operator The first operator (backend address).
   * @param guardian The first guardian.
   */
  function initialize(
    address timelock,
    address admin,
    address operator,
    address guardian
  ) external initializer {
    if (timelock == address(0) || admin == address(0)) revert ZeroAddress();
    __AccessControl_init();

    _grantRole(DEFAULT_ADMIN_ROLE, timelock);
    _grantRole(ADMIN_ROLE, admin);
    if (operator != address(0)) _grantRole(OPERATOR_ROLE, operator);
    if (guardian != address(0)) _grantRole(GUARDIAN_ROLE, guardian);

    // Operator and guardian rotation — by the admin, without the timelock.
    _setRoleAdmin(OPERATOR_ROLE, ADMIN_ROLE);
    _setRoleAdmin(GUARDIAN_ROLE, ADMIN_ROLE);
  }

  // ----------------- Convenience checks for other contracts -----------------

  /// @notice The timelock = the holder of DEFAULT_ADMIN_ROLE (ADR-0009).
  function isTimelock(address account) external view returns (bool) {
    return hasRole(DEFAULT_ADMIN_ROLE, account);
  }

  function isAdmin(address account) external view returns (bool) {
    return hasRole(ADMIN_ROLE, account);
  }

  function isOperator(address account) external view returns (bool) {
    return hasRole(OPERATOR_ROLE, account);
  }

  function isGuardian(address account) external view returns (bool) {
    return hasRole(GUARDIAN_ROLE, account);
  }

  // ----------------- UUPS -----------------

  /// @dev Upgrade — timelock only (ADR-0009).
  function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
