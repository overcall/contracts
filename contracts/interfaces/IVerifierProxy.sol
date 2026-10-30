// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

/// @notice Chainlink-deployed entry point for Data Streams report verification.
///         Consumers never call the underlying Verifier directly: the proxy
///         checks the DON signatures and routes the call.
///         Addresses per network: https://docs.chain.link/data-streams/crypto-streams
interface IVerifierProxy {
  /// @param payload          Full report payload (header + signed report) as returned
  ///                         by the Data Streams API `fullReport` field.
  /// @param parameterPayload Fee metadata. Empty for subscription billing.
  function verify(
    bytes calldata payload,
    bytes calldata parameterPayload
  ) external payable returns (bytes memory verifierResponse);

  /// @param payloads         Array of full report payloads, possibly for different feed IDs.
  /// @param parameterPayload Fee metadata. Empty for subscription billing.
  /// @return verifiedReports Verified report bytes, in the same order as the input.
  function verifyBulk(
    bytes[] calldata payloads,
    bytes calldata parameterPayload
  ) external payable returns (bytes[] memory verifiedReports);
}
