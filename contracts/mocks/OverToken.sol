// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title OverToken
 * @notice A simple ERC-20 for tests and the testnet (ADR-0010). The entire supply is minted to
 *         the deployer at creation; no further minting. Production uses an already-existing
 *         token: Vault accepts the token address in initialize and knows nothing about the implementation.
 */
contract OverToken is ERC20 {
  constructor(uint256 supply) ERC20("Overcall", "OVER") {
    _mint(msg.sender, supply);
  }
}
