// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {DataStreamsReports} from "./DataStreamsReports.sol";

contract DataStreamsReportsHarness {
  function decode(bytes memory report) external pure returns (DataStreamsReports.Decoded memory) {
    return DataStreamsReports.decode(report);
  }
}

contract DataStreamsReportsTest is Test {
  bytes32 constant FEED_V3 = bytes32((uint256(0x0003) << 240) | 1);
  bytes32 constant FEED_V8 = bytes32((uint256(0x0008) << 240) | 2);
  bytes32 constant FEED_V10 = bytes32((uint256(0x000a) << 240) | 3);
  bytes32 constant FEED_V11 = bytes32((uint256(0x000b) << 240) | 4);
  bytes32 constant FEED_BAD = bytes32((uint256(0x0009) << 240) | 5);

  DataStreamsReportsHarness harness;

  function setUp() public {
    harness = new DataStreamsReportsHarness();
  }

  function test_DecodesV3PriceNotBidAsk() public view {
    bytes memory r = abi.encode(
      DataStreamsReports.ReportV3({
        feedId: FEED_V3,
        validFromTimestamp: 100,
        observationsTimestamp: 105,
        nativeFee: 0,
        linkFee: 0,
        expiresAt: 0, // not checked (ADR-0001)
        price: 80_000e18,
        bid: 79_990e18,
        ask: 80_010e18
      })
    );
    DataStreamsReports.Decoded memory d = harness.decode(r);
    assertEq(d.feedId, FEED_V3);
    assertEq(d.price, 80_000e18);
    assertEq(d.validFromTimestamp, 100);
    assertEq(d.observationsTimestamp, 105);
    assertEq(d.marketStatus, type(uint32).max);
  }

  function test_DecodesV8MidPrice() public view {
    bytes memory r = abi.encode(
      DataStreamsReports.ReportV8(FEED_V8, 10, 20, 0, 0, 0, 0, 2000e18, 2)
    );
    DataStreamsReports.Decoded memory d = harness.decode(r);
    assertEq(d.price, 2000e18);
    assertEq(d.marketStatus, 2);
  }

  function test_DecodesV10Price() public view {
    bytes memory r = abi.encode(
      DataStreamsReports.ReportV10(FEED_V10, 10, 20, 0, 0, 0, 0, 350e18, 2, 0, 0, 0, 351e18)
    );
    DataStreamsReports.Decoded memory d = harness.decode(r);
    assertEq(d.price, 350e18); // price, not tokenizedPrice
  }

  function test_DecodesV11MidNotLastTraded() public view {
    bytes memory r = abi.encode(
      DataStreamsReports.ReportV11(FEED_V11, 10, 20, 0, 0, 0, 100e18, 0, 99e18, 0, 101e18, 0, 98e18, 2)
    );
    DataStreamsReports.Decoded memory d = harness.decode(r);
    assertEq(d.price, 100e18); // mid, not lastTradedPrice
    assertEq(d.marketStatus, 2);
  }

  function test_RejectsUnsupportedSchema() public {
    bytes memory r = abi.encode(
      DataStreamsReports.ReportV3(FEED_BAD, 10, 20, 0, 0, 0, 1e18, 1e18, 1e18)
    );
    vm.expectRevert(abi.encodeWithSelector(DataStreamsReports.UnsupportedSchema.selector, uint16(9)));
    harness.decode(r);
  }

  function test_CoversInterval() public pure {
    DataStreamsReports.Decoded memory d;
    d.validFromTimestamp = 100;
    d.observationsTimestamp = 105;
    assert(DataStreamsReports.covers(d, 100));
    assert(DataStreamsReports.covers(d, 105));
    assert(!DataStreamsReports.covers(d, 99));
    assert(!DataStreamsReports.covers(d, 106));
  }
}
