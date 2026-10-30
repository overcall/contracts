// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/**
 * @title Timelock
 * @notice Holds the upgrade right for all protocol proxies (ADR-0009): an upgrade is announced,
 *         waits out the delay, and only then is applied — in a single atomic
 *         `executeBatch` transaction for all contracts at once.
 *
 *         The timelock itself is NOT behind a proxy: it is the root of trust, its code is immutable.
 *
 *         Delay: the initial value is set at deploy time (target 48 hours — greater than the
 *         maximum channel duration plus the batch period); can only be changed through
 *         the timelock itself (`updateDelay`), i.e. subject to the same delay. The rule
 *         "delay ≥ channel duration + batch" is the admin's responsibility.
 *
 * @dev Exactly OpenZeppelin's TimelockController; the subclass exists to give it a name in
 *      the artifacts and to pin deploy parameters in one place.
 *      OZ roles: PROPOSER_ROLE — who announces operations (admin multisig),
 *      EXECUTOR_ROLE — who executes them once the delay has elapsed (address(0) = anyone),
 *      DEFAULT_ADMIN_ROLE — not granted to anyone except the timelock itself (internal to OZ).
 */
contract Timelock is TimelockController {
  /**
   * @param minDelay  Initial delay, in seconds (target 48 hours).
   * @param proposers Who can announce operations (and cancel them: receives CANCELLER_ROLE).
   * @param executors Who can execute matured operations; [address(0)] — any address.
   */
  constructor(
    uint256 minDelay,
    address[] memory proposers,
    address[] memory executors
  ) TimelockController(minDelay, proposers, executors, address(0)) {}
}
