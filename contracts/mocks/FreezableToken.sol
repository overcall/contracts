// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title FreezableToken
 * @notice Test double for a Paxos-style stablecoin (USDG): the issuer can freeze an address, after
 *         which any transfer to or from it reverts. Decimals are a constructor parameter so the
 *         same mock serves as 6-decimal USDG and 18-decimal VIRTUAL on the testnet.
 */
contract FreezableToken is ERC20 {
  error Frozen(address account);
  error NotOwner();

  address public owner;
  uint8 private immutable _decimals;
  mapping(address => bool) public isFrozen;

  constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
    owner = msg.sender;
    _decimals = decimals_;
  }

  function decimals() public view override returns (uint8) {
    return _decimals;
  }

  function mint(address to, uint256 amount) external {
    if (msg.sender != owner) revert NotOwner();
    _mint(to, amount);
  }

  function freeze(address account) external {
    if (msg.sender != owner) revert NotOwner();
    isFrozen[account] = true;
  }

  function unfreeze(address account) external {
    if (msg.sender != owner) revert NotOwner();
    isFrozen[account] = false;
  }

  function _update(address from, address to, uint256 value) internal override {
    if (isFrozen[from]) revert Frozen(from);
    if (isFrozen[to]) revert Frozen(to);
    super._update(from, to, value);
  }
}
