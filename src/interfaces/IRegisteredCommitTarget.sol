// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

/// @notice Atomic callback used after a direct identity is first registered.
interface IRegisteredCommitTarget {
  /// @notice Completes the first commit whose payload hash was bound into registration.
  function completeRegisteredCommit(
    address eoa,
    address registrationCaller,
    bytes32 commitPayloadHash,
    bytes calldata commitData
  ) external payable;
}
