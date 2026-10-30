// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice A thin wrapper for Ignition: provides a local artifact for the ERC1967 proxy.
contract OverProxy is ERC1967Proxy {
  constructor(address implementation, bytes memory data) ERC1967Proxy(implementation, data) {}
}
