// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AccessRegistry} from "../access/AccessRegistry.sol";
import {AssetRegistry} from "./AssetRegistry.sol";

contract AssetRegistryTest is Test {
  address constant TIMELOCK = address(0x71);
  address constant ADMIN = address(0xA1);
  address constant OPERATOR = address(0x01);
  address constant STRANGER = address(0xBAD);

  bytes32 constant BTC = bytes32((uint256(0x0003) << 240) | 1); // v3 crypto
  bytes32 constant HOOD = bytes32((uint256(0x000b) << 240) | 2); // v11 RWA advanced
  bytes32 constant BAD_SCHEMA = bytes32((uint256(0x0009) << 240) | 3);

  AccessRegistry access;
  AssetRegistry registry;

  function setUp() public {
    AccessRegistry aImpl = new AccessRegistry();
    access = AccessRegistry(
      address(
        new ERC1967Proxy(
          address(aImpl), abi.encodeCall(AccessRegistry.initialize, (TIMELOCK, ADMIN, OPERATOR, address(0x61)))
        )
      )
    );
    AssetRegistry impl = new AssetRegistry();
    registry =
      AssetRegistry(address(new ERC1967Proxy(address(impl), abi.encodeCall(AssetRegistry.initialize, (address(access))))));
  }

  function _config() internal pure returns (AssetRegistry.AssetConfig memory cfg) {
    cfg.enabled = true;
    cfg.assetType = AssetRegistry.AssetType.Continuous;
    cfg.decimals = 18;
    cfg.minHeightSigmaWad = 4e18;
    cfg.maxHeightSigmaWad = 40e18;
    cfg.maxSlopeSigmaPerMinWad = 0.0167e18;
    cfg.minDurationSec = 15 minutes;
    cfg.maxDurationSec = 24 hours;
    cfg.minDeposit = 10e18;
    cfg.maxDeposit = 10_000e18;
    cfg.openFeeBps = 100; // 1%
    cfg.openFeeFixed = 0.5e18;
    cfg.profitFeeBps = 1000; // 10%
    cfg.royaltyBps = 1500; // 15%
    cfg.earlyClosePenaltyBps = 500; // 5%
    cfg.channelCreationFee = 0;
    cfg.ceilingWad = 50e18;
    cfg.minMultiplierWad = 1.01e18;
  }

  // ----------------- registration -----------------

  function test_RegisterDerivesSchemaFromStreamPrefix() public {
    vm.prank(ADMIN);
    registry.registerAsset(BTC, _config());
    assertEq(registry.getConfig(BTC).schemaVersion, 3);
    assertTrue(registry.isRegistered(BTC));

    vm.prank(ADMIN);
    registry.registerAsset(HOOD, _config());
    assertEq(registry.getConfig(HOOD).schemaVersion, 11);
    assertEq(registry.feedIds().length, 2);
  }

  function test_RejectsUnsupportedSchemaAndDuplicates() public {
    vm.startPrank(ADMIN);
    vm.expectRevert(abi.encodeWithSelector(AssetRegistry.UnsupportedSchemaVersion.selector, uint16(9)));
    registry.registerAsset(BAD_SCHEMA, _config());

    registry.registerAsset(BTC, _config());
    vm.expectRevert(abi.encodeWithSelector(AssetRegistry.AlreadyRegistered.selector, BTC));
    registry.registerAsset(BTC, _config());
    vm.stopPrank();
  }

  function test_OnlyAdminRegistersAndConfigures() public {
    vm.prank(STRANGER);
    vm.expectRevert(AssetRegistry.NotAdmin.selector);
    registry.registerAsset(BTC, _config());

    vm.prank(ADMIN);
    registry.registerAsset(BTC, _config());
    vm.prank(OPERATOR);
    vm.expectRevert(AssetRegistry.NotAdmin.selector);
    registry.configureAsset(BTC, _config());
  }

  function test_ValidationRejectsBadConfigs() public {
    vm.startPrank(ADMIN);
    AssetRegistry.AssetConfig memory cfg;

    cfg = _config();
    cfg.royaltyBps = 5001; // above the self-play cap (ADR-0018)
    vm.expectRevert(abi.encodeWithSelector(AssetRegistry.InvalidConfig.selector, "royalty"));
    registry.registerAsset(BTC, cfg);

    cfg = _config();
    cfg.maxHeightSigmaWad = 1e18; // below the minimum
    vm.expectRevert(abi.encodeWithSelector(AssetRegistry.InvalidConfig.selector, "height"));
    registry.registerAsset(BTC, cfg);

    cfg = _config();
    cfg.ceilingWad = 0.5e18; // cap below ×1
    vm.expectRevert(abi.encodeWithSelector(AssetRegistry.InvalidConfig.selector, "multiplier"));
    registry.registerAsset(BTC, cfg);
    vm.stopPrank();
  }

  function test_ConfigureKeepsSchema() public {
    vm.startPrank(ADMIN);
    registry.registerAsset(BTC, _config());
    AssetRegistry.AssetConfig memory cfg = _config();
    cfg.schemaVersion = 999; // an attempt to swap the schema is ignored
    cfg.profitFeeBps = 2000;
    registry.configureAsset(BTC, cfg);
    vm.stopPrank();
    assertEq(registry.getConfig(BTC).schemaVersion, 3);
    assertEq(registry.getConfig(BTC).profitFeeBps, 2000);
  }

  // ----------------- operator -----------------

  function test_TradingWindowRotationAndAcceptsExpiry() public {
    AssetRegistry.AssetConfig memory cfg = _config();
    cfg.assetType = AssetRegistry.AssetType.Session;
    vm.prank(ADMIN);
    registry.registerAsset(HOOD, cfg);

    vm.warp(1_800_000_000);
    // window not set → Session asset is closed
    assertFalse(registry.acceptsExpiry(HOOD, uint64(block.timestamp + 1 hours)));

    vm.prank(OPERATOR);
    registry.setTradingWindow(HOOD, uint64(block.timestamp - 1 hours), uint64(block.timestamp + 8 hours));
    assertTrue(registry.acceptsExpiry(HOOD, uint64(block.timestamp + 8 hours)));
    // expiry past the window — no (expiry must be entirely within the window)
    assertFalse(registry.acceptsExpiry(HOOD, uint64(block.timestamp + 9 hours)));

    // Continuous always accepts (if enabled)
    vm.prank(ADMIN);
    registry.registerAsset(BTC, _config());
    assertTrue(registry.acceptsExpiry(BTC, uint64(block.timestamp + 24 hours)));
    vm.prank(ADMIN);
    registry.setEnabled(BTC, false);
    assertFalse(registry.acceptsExpiry(BTC, uint64(block.timestamp + 1 hours)));
  }

  // ----------------- v3: currency terms (ADR-0021) -----------------

  function _usdgTerms() internal pure returns (AssetRegistry.CurrencyTerms memory t) {
    t.minDeposit = 0.5e6;
    t.maxDeposit = 50e6;
    t.openFeeFixed = 0.05e6;
    t.channelCreationFee = 0;
    t.ceilingWad = 10e18;
  }

  function test_CurrencyZeroTermsAreTheV2ConfigFields() public {
    vm.prank(ADMIN);
    registry.registerAsset(BTC, _config());
    AssetRegistry.CurrencyTerms memory t = registry.getCurrencyTerms(BTC, 0);
    assertEq(t.minDeposit, 10e18);
    assertEq(t.maxDeposit, 10_000e18);
    assertEq(t.openFeeFixed, 0.5e18);
    assertEq(t.ceilingWad, 50e18);
    assertTrue(registry.acceptsCurrency(BTC, 0));

    // writing currency 0 terms updates the config struct in place (the launch reconfiguration)
    AssetRegistry.CurrencyTerms memory over = AssetRegistry.CurrencyTerms(500e18, 200_000e18, 20e18, 0, 50e18);
    vm.prank(ADMIN);
    registry.setCurrencyTerms(BTC, 0, over);
    assertEq(registry.getConfig(BTC).maxDeposit, 200_000e18);
    assertEq(registry.getConfig(BTC).openFeeFixed, 20e18);
    assertEq(registry.getConfig(BTC).profitFeeBps, 1000); // shared fields untouched
  }

  function test_OtherCurrencyClosedUntilTermsSet() public {
    vm.prank(ADMIN);
    registry.registerAsset(BTC, _config());
    assertFalse(registry.acceptsCurrency(BTC, 1));
    assertEq(registry.getCurrencyTerms(BTC, 1).maxDeposit, 0);

    vm.prank(ADMIN);
    registry.setCurrencyTerms(BTC, 1, _usdgTerms());
    assertTrue(registry.acceptsCurrency(BTC, 1));
    assertEq(registry.getCurrencyTerms(BTC, 1).ceilingWad, 10e18);
    assertEq(registry.getCurrencyTerms(BTC, 0).ceilingWad, 50e18); // OVER untouched

    // disabling the asset closes every currency; closing the terms closes just that currency
    vm.prank(ADMIN);
    registry.setEnabled(BTC, false);
    assertFalse(registry.acceptsCurrency(BTC, 1));
    vm.prank(ADMIN);
    registry.setEnabled(BTC, true);
    AssetRegistry.CurrencyTerms memory closed;
    vm.prank(ADMIN);
    registry.setCurrencyTerms(BTC, 1, closed);
    assertFalse(registry.acceptsCurrency(BTC, 1));
    assertTrue(registry.acceptsCurrency(BTC, 0));
  }

  function test_CurrencyTermsValidation() public {
    vm.startPrank(ADMIN);
    registry.registerAsset(BTC, _config());
    AssetRegistry.CurrencyTerms memory t;

    t = _usdgTerms();
    t.minDeposit = 60e6; // min above max
    vm.expectRevert(abi.encodeWithSelector(AssetRegistry.InvalidConfig.selector, "deposit"));
    registry.setCurrencyTerms(BTC, 1, t);

    t = _usdgTerms();
    t.ceilingWad = 1.005e18; // cap below the shared floor 1.01× → every request would revert
    vm.expectRevert(abi.encodeWithSelector(AssetRegistry.InvalidConfig.selector, "floor-above-cap"));
    registry.setCurrencyTerms(BTC, 1, t);

    vm.expectRevert(abi.encodeWithSelector(AssetRegistry.InvalidConfig.selector, "currency"));
    registry.setCurrencyTerms(BTC, 8, _usdgTerms());

    // currency 0 cannot be "closed" by zero terms
    AssetRegistry.CurrencyTerms memory closed;
    vm.expectRevert(abi.encodeWithSelector(AssetRegistry.InvalidConfig.selector, "deposit"));
    registry.setCurrencyTerms(BTC, 0, closed);

    vm.expectRevert(abi.encodeWithSelector(AssetRegistry.UnknownAsset.selector, HOOD));
    registry.setCurrencyTerms(HOOD, 1, _usdgTerms());
    vm.stopPrank();

    vm.prank(OPERATOR);
    vm.expectRevert(AssetRegistry.NotAdmin.selector);
    registry.setCurrencyTerms(BTC, 1, _usdgTerms());
  }

  function test_ConfigureKeepsCurrencyTermsAndChecksFloor() public {
    vm.startPrank(ADMIN);
    registry.registerAsset(BTC, _config());
    registry.setCurrencyTerms(BTC, 1, _usdgTerms());

    AssetRegistry.AssetConfig memory cfg = _config();
    cfg.profitFeeBps = 2000;
    registry.configureAsset(BTC, cfg);
    assertEq(registry.getCurrencyTerms(BTC, 1).maxDeposit, 50e6); // survived the reconfiguration

    cfg.minMultiplierWad = 11e18; // a floor above the USDG cap of 10× is refused
    vm.expectRevert(abi.encodeWithSelector(AssetRegistry.InvalidConfig.selector, "floor-above-cap"));
    registry.configureAsset(BTC, cfg);

    cfg = _config();
    cfg.ceilingWad = 1.005e18; // the asset's own cap below its floor (1.01×) is refused as well
    vm.expectRevert(abi.encodeWithSelector(AssetRegistry.InvalidConfig.selector, "floor-above-cap"));
    registry.configureAsset(BTC, cfg);
    vm.stopPrank();
  }

  function test_MulticallBatchesAdminCalls() public {
    bytes[] memory calls = new bytes[](3);
    calls[0] = abi.encodeCall(registry.registerAsset, (BTC, _config()));
    calls[1] = abi.encodeCall(registry.registerAsset, (HOOD, _config()));
    calls[2] = abi.encodeCall(registry.setCurrencyTerms, (BTC, 1, _usdgTerms()));
    vm.prank(ADMIN);
    registry.multicall(calls);
    assertEq(registry.feedIds().length, 2);
    assertTrue(registry.acceptsCurrency(BTC, 1));

    // the batch runs as the caller: a stranger gets the same refusal, and nothing partial lands
    bytes[] memory one = new bytes[](1);
    one[0] = abi.encodeCall(registry.setEnabled, (BTC, false));
    vm.prank(STRANGER);
    vm.expectRevert(AssetRegistry.NotAdmin.selector);
    registry.multicall(one);
    assertTrue(registry.acceptsCurrency(BTC, 0));
  }

  // ----------------- upgrade -----------------

  function test_UpgradeOnlyTimelock() public {
    AssetRegistry v2 = new AssetRegistry();
    vm.prank(ADMIN);
    vm.expectRevert(AssetRegistry.NotTimelock.selector);
    registry.upgradeToAndCall(address(v2), "");
    vm.prank(TIMELOCK);
    registry.upgradeToAndCall(address(v2), "");
  }
}
