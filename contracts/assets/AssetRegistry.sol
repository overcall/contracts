// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {MulticallUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/MulticallUpgradeable.sol";
import {AccessRegistry} from "../access/AccessRegistry.sol";

/**
 * @title AssetRegistry
 * @notice Asset and the conditions under which it accepts requests (CONTEXT: Assets, ADR-0005).
 *         The configuration is mutable: it only governs the acceptance of new requests; everything
 *         that affects the outcome of an open position is captured into the position at request time (ADR-0013).
 *
 *         Changed by the admin; the operator only rotates the trading window. Shares are in bps (10000 = 100%), relative
 *         geometry values are WAD (1e18).
 *
 *         Currency terms (ADR-0021): the money amounts and the multiplier cap differ by currency.
 *         Currency 0 (OVER) keeps them in `AssetConfig`, exactly where v2 stored them; every other
 *         currency has its own `CurrencyTerms`. Percentages, geometry, durations, the multiplier
 *         floor and the trading window are shared by all currencies.
 *
 * @dev UUPS (ADR-0009), ERC-7201 storage. The Data Streams report schema is derived from
 *      the first two bytes of the stream — an asset cannot be fed a report of a different schema.
 *      Multicall lets the admin reconfigure every asset in one transaction (no storage of its own).
 */
contract AssetRegistry is Initializable, UUPSUpgradeable, MulticallUpgradeable {
  uint16 public constant BPS = 10_000;
  /// @dev Royalty share cap — limits the creator's self-play advantage (ADR-0018).
  uint16 public constant MAX_ROYALTY_BPS = 5_000;
  /// @dev Currency ids are small; bounds the loop that re-validates terms against a new floor.
  uint8 public constant MAX_CURRENCIES = 8;

  /// @notice Supported report schemas (first two bytes of the stream).
  uint16 public constant SCHEMA_V3_CRYPTO = 3;
  uint16 public constant SCHEMA_V8_RWA = 8;
  uint16 public constant SCHEMA_V10_TOKENIZED = 10;
  uint16 public constant SCHEMA_V11_RWA_ADVANCED = 11;

  enum AssetType {
    Continuous, // trades around the clock
    Session // by session: expiry must fall within the trading window
  }

  /// @notice Asset configuration. Mutable (ADR-0005); snapshots are the game's concern.
  struct AssetConfig {
    bool enabled; // request acceptance enabled
    AssetType assetType;
    uint16 schemaVersion; // from the stream prefix
    uint8 decimals; // decimals of prices in stream reports
    // geometry (in units of σ₁ₘ from the quote, WAD)
    uint128 minHeightSigmaWad;
    uint128 maxHeightSigmaWad;
    uint128 maxSlopeSigmaPerMinWad;
    uint32 minDurationSec; // 15 minutes
    uint32 maxDurationSec; // 24 hours
    // deposits and fees
    uint128 minDeposit;
    uint128 maxDeposit;
    uint16 openFeeBps; // percentage part of the opening fee
    uint128 openFeeFixed; // fixed amount in OVER, never refunded (ADR-0013)
    uint16 profitFeeBps; // closing fee, % of the reward
    uint16 royaltyBps; // share of the profit fee to the channel owner (ADR-0018), ≤ MAX_ROYALTY_BPS
    uint16 earlyClosePenaltyBps; // early-close penalty (ADR-0012)
    uint128 channelCreationFee; // channel creation fee, can be 0 (ADR-0018)
    // multipliers and limits
    uint128 ceilingWad; // multiplier cap, WAD (e.g. 50e18)
    uint64 minMultiplierWad; // side below this is not offered (pricing.md), e.g. 1.01e18
    // trading window (for Session): requests and expiries only inside it; rotated by the operator
    uint64 windowOpensAt;
    uint64 windowClosesAt;
  }

  /// @notice The per-currency part of an asset's configuration (ADR-0021). Amounts are in the
  ///         currency's own units. `maxDeposit == 0` means the asset does not accept that currency.
  struct CurrencyTerms {
    uint128 minDeposit;
    uint128 maxDeposit;
    uint128 openFeeFixed; // never refunded (ADR-0013)
    uint128 channelCreationFee; // can be 0 (ADR-0018)
    uint128 ceilingWad; // multiplier cap for this currency, WAD; the payout multiple the player sees
  }

  /// @custom:storage-location erc7201:overcall.assets
  struct AssetsStorage {
    AccessRegistry access;
    mapping(bytes32 feedId => AssetConfig) configs;
    mapping(uint32 version => bytes32 paramsHash) modelParamsHash; // ADR-0020
    bytes32[] feedIds;
    // v3 (ADR-0021): terms for currencies other than 0; currency 0 lives in `configs`
    mapping(bytes32 feedId => mapping(uint8 currencyId => CurrencyTerms)) currencyTerms;
  }

  // keccak256(abi.encode(uint256(keccak256("overcall.assets")) - 1)) & ~bytes32(uint256(0xff))
  bytes32 private constant STORAGE_SLOT = 0x072bee1a6be12712b7179166a44aa6f69cc1f05d0d090b6caea6e4cc3b12f400;

  function _s() private pure returns (AssetsStorage storage $) {
    assembly {
      $.slot := STORAGE_SLOT
    }
  }

  // ----------------- Events -----------------

  event AssetRegistered(bytes32 indexed feedId, uint16 schemaVersion);
  event AssetConfigured(bytes32 indexed feedId);
  event AssetEnabled(bytes32 indexed feedId, bool enabled);
  event TradingWindowSet(bytes32 indexed feedId, uint64 opensAt, uint64 closesAt);
  event ModelRegistered(uint32 indexed version, bytes32 paramsHash);
  event CurrencyTermsSet(bytes32 indexed feedId, uint8 indexed currencyId);

  // ----------------- Errors -----------------

  error NotAdmin();
  error NotOperator();
  error NotTimelock();
  error ZeroAddress();
  error UnknownAsset(bytes32 feedId);
  error AlreadyRegistered(bytes32 feedId);
  error UnsupportedSchemaVersion(uint16 schemaVersion);
  error InvalidConfig(string what);

  modifier onlyAdmin() {
    if (!_s().access.isAdmin(msg.sender)) revert NotAdmin();
    _;
  }

  modifier onlyOperator() {
    if (!_s().access.isOperator(msg.sender)) revert NotOperator();
    _;
  }

  modifier exists(bytes32 feedId) {
    if (_s().configs[feedId].schemaVersion == 0) revert UnknownAsset(feedId);
    _;
  }

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  function initialize(address access_) external initializer {
    if (access_ == address(0)) revert ZeroAddress();
    _s().access = AccessRegistry(access_);
  }

  // ----------------- Administration -----------------

  /**
   * @notice Registers an asset with a full configuration. The schema is derived from the stream
   *         prefix. An unconfigured asset accepts no requests (enabled is set separately).
   */
  function registerAsset(bytes32 feedId, AssetConfig calldata cfg) external onlyAdmin {
    AssetsStorage storage $ = _s();
    if ($.configs[feedId].schemaVersion != 0) revert AlreadyRegistered(feedId);
    uint16 schema = uint16(bytes2(feedId));
    if (
      schema != SCHEMA_V3_CRYPTO && schema != SCHEMA_V8_RWA && schema != SCHEMA_V10_TOKENIZED
        && schema != SCHEMA_V11_RWA_ADVANCED
    ) revert UnsupportedSchemaVersion(schema);
    _validate(cfg);
    $.configs[feedId] = cfg;
    $.configs[feedId].schemaVersion = schema;
    $.feedIds.push(feedId);
    emit AssetRegistered(feedId, schema);
  }

  /// @notice Full configuration update (except schema). Does not touch open positions (ADR-0005)
  ///         and leaves the other currencies' terms in place; a new floor is checked against them.
  function configureAsset(bytes32 feedId, AssetConfig calldata cfg) external onlyAdmin exists(feedId) {
    _validate(cfg);
    AssetsStorage storage $ = _s();
    for (uint8 c = 1; c < MAX_CURRENCIES; c++) {
      CurrencyTerms storage t = $.currencyTerms[feedId][c];
      if (t.maxDeposit != 0 && t.ceilingWad < cfg.minMultiplierWad) revert InvalidConfig("floor-above-cap");
    }
    uint16 schema = $.configs[feedId].schemaVersion;
    $.configs[feedId] = cfg;
    $.configs[feedId].schemaVersion = schema;
    emit AssetConfigured(feedId);
  }

  /**
   * @notice Sets the currency-specific terms of an asset (ADR-0021). Currency 0 writes into the
   *         v2 fields of `AssetConfig`; others into their own slot. `maxDeposit == 0` closes the
   *         currency for the asset. The cap must sit above the shared floor — with a Multicall
   *         batch one wrong value would otherwise make every request of the currency revert.
   */
  function setCurrencyTerms(bytes32 feedId, uint8 currencyId, CurrencyTerms calldata t)
    external
    onlyAdmin
    exists(feedId)
  {
    if (currencyId >= MAX_CURRENCIES) revert InvalidConfig("currency");
    AssetsStorage storage $ = _s();
    AssetConfig storage cfg = $.configs[feedId];
    if (t.maxDeposit != 0) {
      if (t.maxDeposit < t.minDeposit) revert InvalidConfig("deposit");
      if (t.ceilingWad < 1e18) revert InvalidConfig("multiplier");
      if (t.ceilingWad < cfg.minMultiplierWad) revert InvalidConfig("floor-above-cap");
      // pulled from the payer on top of the deposit: never more than the smallest deposit (audit 2026-10-19, M-08)
      if (t.channelCreationFee > t.minDeposit) revert InvalidConfig("creation-fee");
    } else if (currencyId == 0) {
      revert InvalidConfig("deposit"); // OVER cannot be closed through its terms; use setEnabled
    }
    if (currencyId == 0) {
      cfg.minDeposit = t.minDeposit;
      cfg.maxDeposit = t.maxDeposit;
      cfg.openFeeFixed = t.openFeeFixed;
      cfg.channelCreationFee = t.channelCreationFee;
      cfg.ceilingWad = t.ceilingWad;
    } else {
      $.currencyTerms[feedId][currencyId] = t;
    }
    emit CurrencyTermsSet(feedId, currencyId);
  }

  function setEnabled(bytes32 feedId, bool enabled) external onlyAdmin exists(feedId) {
    _s().configs[feedId].enabled = enabled;
    emit AssetEnabled(feedId, enabled);
  }

  // ----------------- Operator -----------------

  /// @notice Trading window rotation (Session assets).
  function setTradingWindow(bytes32 feedId, uint64 opensAt, uint64 closesAt) external onlyOperator exists(feedId) {
    if (closesAt <= opensAt) revert InvalidConfig("window");
    AssetConfig storage cfg = _s().configs[feedId];
    cfg.windowOpensAt = opensAt;
    cfg.windowClosesAt = closesAt;
    emit TradingWindowSet(feedId, opensAt, closesAt);
  }

  // ----------------- Views -----------------

  function getConfig(bytes32 feedId) external view exists(feedId) returns (AssetConfig memory) {
    return _s().configs[feedId];
  }

  /// @notice The asset's terms in one currency (ADR-0021). Currency 0 is read from `AssetConfig`.
  function getCurrencyTerms(bytes32 feedId, uint8 currencyId)
    external
    view
    exists(feedId)
    returns (CurrencyTerms memory t)
  {
    if (currencyId == 0) {
      AssetConfig storage cfg = _s().configs[feedId];
      return CurrencyTerms({
        minDeposit: cfg.minDeposit,
        maxDeposit: cfg.maxDeposit,
        openFeeFixed: cfg.openFeeFixed,
        channelCreationFee: cfg.channelCreationFee,
        ceilingWad: cfg.ceilingWad
      });
    }
    return _s().currencyTerms[feedId][currencyId];
  }

  /// @notice Whether the asset takes requests in the currency: enabled, and the terms are set.
  function acceptsCurrency(bytes32 feedId, uint8 currencyId) external view exists(feedId) returns (bool) {
    AssetsStorage storage $ = _s();
    if (!$.configs[feedId].enabled) return false;
    if (currencyId == 0) return true;
    return $.currencyTerms[feedId][currencyId].maxDeposit != 0;
  }

  function isRegistered(bytes32 feedId) external view returns (bool) {
    return _s().configs[feedId].schemaVersion != 0;
  }

  function feedIds() external view returns (bytes32[] memory) {
    return _s().feedIds;
  }

  /// @notice Whether the asset accepts a request with the given expiry (window, ADR: expiry entirely within the window).
  function acceptsExpiry(bytes32 feedId, uint64 expiry) external view exists(feedId) returns (bool) {
    AssetConfig storage cfg = _s().configs[feedId];
    if (!cfg.enabled) return false;
    if (cfg.assetType == AssetType.Continuous) return true;
    return block.timestamp >= cfg.windowOpensAt && expiry <= cfg.windowClosesAt;
  }

  // ----------------- Model registry (ADR-0020) -----------------

  /// @notice Hash of the `model-v<N>.json` parameter file — makes multipliers auditable (ADR-0020).
  function registerModel(uint32 version, bytes32 paramsHash) external onlyAdmin {
    if (version == 0 || paramsHash == bytes32(0)) revert InvalidConfig("model");
    if (_s().modelParamsHash[version] != bytes32(0)) revert InvalidConfig("model-exists");
    _s().modelParamsHash[version] = paramsHash;
    emit ModelRegistered(version, paramsHash);
  }

  function modelParamsHash(uint32 version) external view returns (bytes32) {
    return _s().modelParamsHash[version];
  }

  // ----------------- Internal -----------------

  function _validate(AssetConfig calldata cfg) private pure {
    if (cfg.minHeightSigmaWad == 0 || cfg.maxHeightSigmaWad < cfg.minHeightSigmaWad) revert InvalidConfig("height");
    if (cfg.minDurationSec == 0 || cfg.maxDurationSec < cfg.minDurationSec) revert InvalidConfig("duration");
    if (cfg.maxDeposit < cfg.minDeposit) revert InvalidConfig("deposit");
    if (cfg.openFeeBps >= BPS || cfg.profitFeeBps >= BPS) revert InvalidConfig("fees");
    if (cfg.royaltyBps > MAX_ROYALTY_BPS) revert InvalidConfig("royalty");
    if (cfg.earlyClosePenaltyBps >= BPS) revert InvalidConfig("penalty");
    if (cfg.ceilingWad < 1e18 || cfg.minMultiplierWad < 1e18) revert InvalidConfig("multiplier");
    if (cfg.ceilingWad < cfg.minMultiplierWad) revert InvalidConfig("floor-above-cap");
    if (cfg.channelCreationFee > cfg.minDeposit) revert InvalidConfig("creation-fee");
  }

  /// @dev Upgrade — timelock only (ADR-0009).
  function _authorizeUpgrade(address) internal override {
    if (!_s().access.isTimelock(msg.sender)) revert NotTimelock();
  }
}
