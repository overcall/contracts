// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IVerifierProxy} from "../interfaces/IVerifierProxy.sol";

/**
 * @notice Test double for the Chainlink `VerifierProxy`.
 * @dev Mirrors the real proxy's shape: a payload is ABI-encoded as
 *      `(bytes32[3] reportContext, bytes reportData)`, and verification returns
 *      `reportData` — the ABI-encoded report struct. Signature checking is what the
 *      real proxy adds on top, and it is exactly what cannot be exercised locally.
 */
contract MockVerifierProxy is IVerifierProxy {
  bool public shouldRevert;
  /// @dev When set, `verify` returns this instead of the payload's report data.
  ///      Lets tests simulate a response that disagrees with the submitted payload.
  bytes public responseOverride;

  error VerificationFailed();

  function setShouldRevert(bool value) external {
    shouldRevert = value;
  }

  function setResponseOverride(bytes calldata response) external {
    responseOverride = response;
  }

  function verify(
    bytes calldata payload,
    bytes calldata
  ) external payable returns (bytes memory) {
    if (shouldRevert) revert VerificationFailed();
    if (responseOverride.length != 0) return responseOverride;
    (, bytes memory reportData) = abi.decode(payload, (bytes32[3], bytes));
    return reportData;
  }

  function verifyBulk(
    bytes[] calldata payloads,
    bytes calldata
  ) external payable returns (bytes[] memory) {
    if (shouldRevert) revert VerificationFailed();

    bytes[] memory verified = new bytes[](payloads.length);
    for (uint256 i = 0; i < payloads.length; i++) {
      (, bytes memory reportData) = abi.decode(payloads[i], (bytes32[3], bytes));
      verified[i] = reportData;
    }
    return verified;
  }
}
