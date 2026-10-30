// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title TaxedToken
 * @notice Test double for the Virtuals AgentToken tax (audit 2026-10-19, H-01): the token owner can
 *         mark an address as a taxed pool, after which every transfer to it loses `taxBps` to the
 *         owner. OVER's owner key is outside the protocol, so the vault must never trust the amount
 *         it asked for.
 */
contract TaxedToken is ERC20 {
  error NotOwner();

  address public owner;
  uint16 public taxBps;
  mapping(address => bool) public isTaxedPool;

  constructor() ERC20("Taxed", "TAX") {
    owner = msg.sender;
    _mint(msg.sender, 10_000_000e18);
  }

  function setTaxedPool(address pool, uint16 bps) external {
    if (msg.sender != owner) revert NotOwner();
    isTaxedPool[pool] = true;
    taxBps = bps;
  }

  function _update(address from, address to, uint256 value) internal override {
    if (from == address(0) || !isTaxedPool[to] || taxBps == 0) return super._update(from, to, value);
    uint256 tax = (value * taxBps) / 10_000;
    super._update(from, owner, tax);
    super._update(from, to, value - tax);
  }
}
