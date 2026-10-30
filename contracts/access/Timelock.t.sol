// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Timelock} from "./Timelock.sol";
import {AccessRegistry} from "./AccessRegistry.sol";

contract AccessRegistryV2Mock2 is AccessRegistry {
  function version() external pure returns (uint256) {
    return 2;
  }
}

contract TimelockTest is Test {
  uint256 constant DELAY = 48 hours;
  address constant PROPOSER = address(0xA1);
  address constant ADMIN = address(0xA1);
  address constant ANYONE = address(0xE1);

  Timelock timelock;
  AccessRegistry registry;

  function setUp() public {
    address[] memory proposers = new address[](1);
    proposers[0] = PROPOSER;
    address[] memory executors = new address[](1);
    executors[0] = address(0); // anyone can execute
    timelock = new Timelock(DELAY, proposers, executors);

    AccessRegistry impl = new AccessRegistry();
    registry = AccessRegistry(
      address(
        new ERC1967Proxy(
          address(impl),
          abi.encodeCall(AccessRegistry.initialize, (address(timelock), ADMIN, address(0x01), address(0x61)))
        )
      )
    );
  }

  function _scheduleUpgrade(address newImpl) internal returns (bytes memory data) {
    data = abi.encodeCall(registry.upgradeToAndCall, (newImpl, ""));
    vm.prank(PROPOSER);
    timelock.schedule(address(registry), 0, data, bytes32(0), bytes32(0), DELAY);
  }

  function test_UpgradeThroughTimelockAfterDelay() public {
    address v2 = address(new AccessRegistryV2Mock2());
    bytes memory data = _scheduleUpgrade(v2);

    // cannot execute before the delay elapses
    vm.expectRevert();
    vm.prank(ANYONE);
    timelock.execute(address(registry), 0, data, bytes32(0), bytes32(0));

    vm.warp(block.timestamp + DELAY);
    vm.prank(ANYONE); // the executor is any address
    timelock.execute(address(registry), 0, data, bytes32(0), bytes32(0));
    assertEq(AccessRegistryV2Mock2(address(registry)).version(), 2);
  }

  function test_DirectUpgradeByProposerStillForbidden() public {
    // the upgrade right belongs to the timelock, not the proposer
    address v2 = address(new AccessRegistryV2Mock2());
    vm.prank(PROPOSER);
    vm.expectRevert();
    registry.upgradeToAndCall(v2, "");
  }

  function test_AtomicBatchUpgradesTwoProxies() public {
    // a second proxy of the same contract — the "all contracts are upgraded in one batch" model
    AccessRegistry impl = new AccessRegistry();
    AccessRegistry second = AccessRegistry(
      address(
        new ERC1967Proxy(
          address(impl),
          abi.encodeCall(AccessRegistry.initialize, (address(timelock), ADMIN, address(0), address(0)))
        )
      )
    );
    address v2 = address(new AccessRegistryV2Mock2());

    address[] memory targets = new address[](2);
    targets[0] = address(registry);
    targets[1] = address(second);
    uint256[] memory values = new uint256[](2);
    bytes[] memory payloads = new bytes[](2);
    payloads[0] = abi.encodeCall(registry.upgradeToAndCall, (v2, ""));
    payloads[1] = abi.encodeCall(second.upgradeToAndCall, (v2, ""));

    vm.prank(PROPOSER);
    timelock.scheduleBatch(targets, values, payloads, bytes32(0), bytes32(0), DELAY);
    vm.warp(block.timestamp + DELAY);
    timelock.executeBatch(targets, values, payloads, bytes32(0), bytes32(0));

    assertEq(AccessRegistryV2Mock2(address(registry)).version(), 2);
    assertEq(AccessRegistryV2Mock2(address(second)).version(), 2);
  }

  function test_DelayChangesOnlyThroughItself() public {
    // not even the proposer can do it directly
    vm.prank(PROPOSER);
    vm.expectRevert();
    timelock.updateDelay(1 hours);

    // through its own queue — allowed
    bytes memory data = abi.encodeCall(timelock.updateDelay, (72 hours));
    vm.prank(PROPOSER);
    timelock.schedule(address(timelock), 0, data, bytes32(0), bytes32(0), DELAY);
    vm.warp(block.timestamp + DELAY);
    timelock.execute(address(timelock), 0, data, bytes32(0), bytes32(0));
    assertEq(timelock.getMinDelay(), 72 hours);
  }

  function test_ScheduleBelowMinDelayReverts() public {
    bytes memory data = abi.encodeCall(timelock.updateDelay, (1 hours));
    vm.prank(PROPOSER);
    vm.expectRevert(
      abi.encodeWithSelector(TimelockController.TimelockInsufficientDelay.selector, DELAY - 1, DELAY)
    );
    timelock.schedule(address(timelock), 0, data, bytes32(0), bytes32(0), DELAY - 1);
  }

  function test_StrangerCannotSchedule() public {
    bytes memory data = abi.encodeCall(timelock.updateDelay, (72 hours));
    vm.prank(ANYONE);
    vm.expectRevert();
    timelock.schedule(address(timelock), 0, data, bytes32(0), bytes32(0), DELAY);
  }
}
