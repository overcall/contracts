// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Vault} from "../vault/Vault.sol";
import {AssetRegistry} from "../assets/AssetRegistry.sol";
import {GameState} from "../game/GameState.sol";

/**
 * @title LayoutProbe
 * @notice Never deployed. Declares one state variable per ERC-7201 struct so that solc's
 *         `storageLayout` output expands every member with its slot and offset. The dev script
 *         scripts/dev/storage-layout.mjs compiles it and the layout test compares the result
 *         against test/storage-layout-v2 — live proxies must keep every existing slot in place.
 */
contract LayoutProbe {
  Vault.VaultStorage internal vaultStorage;
  AssetRegistry.AssetsStorage internal assetsStorage;
  AssetRegistry.AssetConfig internal assetConfig;
  AssetRegistry.CurrencyTerms internal currencyTerms; // v3, no baseline
  GameState.GameStorage internal gameStorage;
  GameState.Channel internal channel;
  GameState.Position internal position;
  GameState.CurrencyState internal currencyState; // v3, no baseline
}
