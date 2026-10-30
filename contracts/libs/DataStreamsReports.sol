// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/**
 * @title DataStreamsReports
 * @notice Decodes verified Chainlink Data Streams reports into a single shape the game
 *         needs: price (mid), observation interval, stream. An internal library —
 *         deliberately not a contract (ARCHITECTURE: an external call isolates nothing here).
 *
 *         The schema is derived from the stream's first two bytes; exactly one price is taken
 *         from each schema — the same one used for binding (breach rules, ARCHITECTURE):
 *           v3  crypto            → price
 *           v8  RWA standard      → midPrice
 *           v10 tokenized asset   → price
 *           v11 RWA advanced      → mid
 *         bid/ask/lastTradedPrice are not used — otherwise the operator could pick, among
 *         several prices, the one that breaches.
 *
 * @dev The report's `expiresAt` is NOT checked: a breach proof can be a week old
 *      (ADR-0001). Freshness, where needed, is checked by the game via timestamps.
 */
library DataStreamsReports {
  uint16 internal constant SCHEMA_V3 = 3;
  uint16 internal constant SCHEMA_V8 = 8;
  uint16 internal constant SCHEMA_V10 = 10;
  uint16 internal constant SCHEMA_V11 = 11;

  struct Decoded {
    bytes32 feedId;
    uint32 validFromTimestamp;
    uint32 observationsTimestamp;
    int192 price;
    uint32 marketStatus; // type(uint32).max for schemas without a status (v3)
  }

  error UnsupportedSchema(uint16 schemaVersion);

  /// @dev Report layouts — from the official Data Streams schema documentation.
  struct ReportV3 {
    bytes32 feedId;
    uint32 validFromTimestamp;
    uint32 observationsTimestamp;
    uint192 nativeFee;
    uint192 linkFee;
    uint32 expiresAt;
    int192 price;
    int192 bid;
    int192 ask;
  }

  struct ReportV8 {
    bytes32 feedId;
    uint32 validFromTimestamp;
    uint32 observationsTimestamp;
    uint192 nativeFee;
    uint192 linkFee;
    uint32 expiresAt;
    uint64 lastUpdateTimestamp;
    int192 midPrice;
    uint32 marketStatus;
  }

  struct ReportV10 {
    bytes32 feedId;
    uint32 validFromTimestamp;
    uint32 observationsTimestamp;
    uint192 nativeFee;
    uint192 linkFee;
    uint32 expiresAt;
    uint64 lastUpdateTimestamp;
    int192 price;
    uint32 marketStatus;
    int192 currentMultiplier;
    int192 newMultiplier;
    uint32 activationDateTime;
    int192 tokenizedPrice;
  }

  struct ReportV11 {
    bytes32 feedId;
    uint32 validFromTimestamp;
    uint32 observationsTimestamp;
    uint192 nativeFee;
    uint192 linkFee;
    uint32 expiresAt;
    int192 mid;
    uint64 lastSeenTimestampNs;
    int192 bid;
    int192 bidVolume;
    int192 ask;
    int192 askVolume;
    int192 lastTradedPrice;
    uint32 marketStatus;
  }

  /// @notice The stream's schema — the first two bytes of the id (equal to the first two bytes of reportData).
  function schemaOf(bytes32 feedId) internal pure returns (uint16) {
    return uint16(bytes2(feedId));
  }

  /// @notice Decodes a VERIFIED report (the output of VerifierProxy.verify).
  function decode(bytes memory verifiedReport) internal pure returns (Decoded memory d) {
    bytes32 feedId;
    assembly {
      feedId := mload(add(verifiedReport, 32))
    }
    uint16 schema = schemaOf(feedId);
    d.marketStatus = type(uint32).max;
    if (schema == SCHEMA_V3) {
      ReportV3 memory r = abi.decode(verifiedReport, (ReportV3));
      (d.feedId, d.validFromTimestamp, d.observationsTimestamp, d.price) =
        (r.feedId, r.validFromTimestamp, r.observationsTimestamp, r.price);
    } else if (schema == SCHEMA_V8) {
      ReportV8 memory r = abi.decode(verifiedReport, (ReportV8));
      (d.feedId, d.validFromTimestamp, d.observationsTimestamp, d.price, d.marketStatus) =
        (r.feedId, r.validFromTimestamp, r.observationsTimestamp, r.midPrice, r.marketStatus);
    } else if (schema == SCHEMA_V10) {
      ReportV10 memory r = abi.decode(verifiedReport, (ReportV10));
      (d.feedId, d.validFromTimestamp, d.observationsTimestamp, d.price, d.marketStatus) =
        (r.feedId, r.validFromTimestamp, r.observationsTimestamp, r.price, r.marketStatus);
    } else if (schema == SCHEMA_V11) {
      ReportV11 memory r = abi.decode(verifiedReport, (ReportV11));
      (d.feedId, d.validFromTimestamp, d.observationsTimestamp, d.price, d.marketStatus) =
        (r.feedId, r.validFromTimestamp, r.observationsTimestamp, r.mid, r.marketStatus);
    } else {
      revert UnsupportedSchema(schema);
    }
  }

  /// @notice Whether the report covers a timestamp (for binding, ADR-0003): validFrom ≤ ts ≤ observations.
  function covers(Decoded memory d, uint64 ts) internal pure returns (bool) {
    return d.validFromTimestamp <= ts && ts <= d.observationsTimestamp;
  }
}
