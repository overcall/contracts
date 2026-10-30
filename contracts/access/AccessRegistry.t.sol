// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessRegistry} from "./AccessRegistry.sol";

contract AccessRegistryV2Mock is AccessRegistry {
  function version() external pure returns (uint256) {
    return 2;
  }
}

contract AccessRegistryTest is Test {
  address constant TIMELOCK = address(0x71);
  address constant ADMIN = address(0xA1);
  address constant OPERATOR = address(0x01);
  address constant GUARDIAN = address(0x61);
  address constant STRANGER = address(0xBAD);

  AccessRegistry registry;

  function setUp() public {
    AccessRegistry impl = new AccessRegistry();
    bytes memory init = abi.encodeCall(AccessRegistry.initialize, (TIMELOCK, ADMIN, OPERATOR, GUARDIAN));
    registry = AccessRegistry(address(new ERC1967Proxy(address(impl), init)));
  }

  // ----------------- initialization -----------------

  function test_InitialRoles() public view {
    assertTrue(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), TIMELOCK));
    assertTrue(registry.isAdmin(ADMIN));
    assertTrue(registry.isOperator(OPERATOR));
    assertTrue(registry.isGuardian(GUARDIAN));
    assertFalse(registry.isAdmin(STRANGER));
    assertFalse(registry.isOperator(STRANGER));
    assertFalse(registry.isGuardian(STRANGER));
  }

  function test_CannotInitializeTwice() public {
    vm.expectRevert(Initializable.InvalidInitialization.selector);
    registry.initialize(TIMELOCK, ADMIN, OPERATOR, GUARDIAN);
  }

  function test_ImplementationIsLocked() public {
    AccessRegistry impl = new AccessRegistry();
    vm.expectRevert(Initializable.InvalidInitialization.selector);
    impl.initialize(TIMELOCK, ADMIN, OPERATOR, GUARDIAN);
  }

  function test_RejectsZeroTimelockOrAdmin() public {
    AccessRegistry impl = new AccessRegistry();
    vm.expectRevert(AccessRegistry.ZeroAddress.selector);
    new ERC1967Proxy(
      address(impl),
      abi.encodeCall(AccessRegistry.initialize, (address(0), ADMIN, OPERATOR, GUARDIAN))
    );
    vm.expectRevert(AccessRegistry.ZeroAddress.selector);
    new ERC1967Proxy(
      address(impl),
      abi.encodeCall(AccessRegistry.initialize, (TIMELOCK, address(0), OPERATOR, GUARDIAN))
    );
  }

  // ----------------- role management -----------------

  function test_AdminRotatesOperatorWithoutTimelock() public {
    address newOperator = address(0x02);
    vm.startPrank(ADMIN);
    registry.grantRole(registry.OPERATOR_ROLE(), newOperator);
    registry.revokeRole(registry.OPERATOR_ROLE(), OPERATOR);
    vm.stopPrank();
    assertTrue(registry.isOperator(newOperator));
    assertFalse(registry.isOperator(OPERATOR));
  }

  function test_AdminRotatesGuardian() public {
    bytes32 guardianRole = registry.GUARDIAN_ROLE();
    vm.prank(ADMIN);
    registry.grantRole(guardianRole, address(0x62));
    assertTrue(registry.isGuardian(address(0x62)));
  }

  function test_OnlyTimelockManagesAdmins() public {
    bytes32 adminRole = registry.ADMIN_ROLE();
    bytes32 rootRole = registry.DEFAULT_ADMIN_ROLE();
    // an admin cannot appoint an admin
    vm.prank(ADMIN);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, ADMIN, rootRole)
    );
    registry.grantRole(adminRole, STRANGER);
    // the timelock can
    vm.prank(TIMELOCK);
    registry.grantRole(adminRole, address(0xA2));
    assertTrue(registry.isAdmin(address(0xA2)));
  }

  function test_OperatorCannotManageRoles() public {
    bytes32 operatorRole = registry.OPERATOR_ROLE();
    bytes32 adminRole = registry.ADMIN_ROLE();
    vm.prank(OPERATOR);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, OPERATOR, adminRole)
    );
    registry.grantRole(operatorRole, STRANGER);
  }

  // ----------------- upgrade -----------------

  function test_TimelockUpgrades() public {
    AccessRegistryV2Mock v2 = new AccessRegistryV2Mock();
    vm.prank(TIMELOCK);
    registry.upgradeToAndCall(address(v2), "");
    assertEq(AccessRegistryV2Mock(address(registry)).version(), 2);
    // roles survived the upgrade
    assertTrue(registry.isAdmin(ADMIN));
    assertTrue(registry.isOperator(OPERATOR));
  }

  function test_AdminCannotUpgrade() public {
    AccessRegistryV2Mock v2 = new AccessRegistryV2Mock();
    bytes32 rootRole = registry.DEFAULT_ADMIN_ROLE();
    vm.prank(ADMIN);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, ADMIN, rootRole)
    );
    registry.upgradeToAndCall(address(v2), "");
  }

  function test_StrangerCannotUpgrade() public {
    AccessRegistryV2Mock v2 = new AccessRegistryV2Mock();
    bytes32 rootRole = registry.DEFAULT_ADMIN_ROLE();
    vm.prank(STRANGER);
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, STRANGER, rootRole)
    );
    registry.upgradeToAndCall(address(v2), "");
  }
}
