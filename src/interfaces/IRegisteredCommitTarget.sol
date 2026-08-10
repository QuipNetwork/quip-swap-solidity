// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

interface IRegisteredCommitTarget {
  function completeRegisteredCommit(
    address eoa,
    address registrationCaller,
    bytes32 commitPayloadHash,
    bytes calldata commitData
  ) external payable;
}
