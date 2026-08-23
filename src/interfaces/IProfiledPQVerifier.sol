// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

/// @notice Metadata interface used to pin a compatible PQ verifier implementation.
interface IProfiledPQVerifier {
  /// @notice Returns the verifier implementation family/version identifier.
  function VERSION_TAG() external view returns (bytes32);

  /// @notice Returns the cryptographic parameter-profile identifier.
  function PROFILE_TAG() external view returns (bytes32);
}
