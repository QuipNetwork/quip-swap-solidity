// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {IRegisteredCommitTarget} from '../../src/interfaces/IRegisteredCommitTarget.sol';

contract RegisteredCommitTargetHarness is IRegisteredCommitTarget {
  error CommitRejected();
  bool public reject;
  address public registryCaller;
  address public registeredEOA;
  bytes32 public commitPayloadHash;
  bytes public commitData;

  function setReject(bool value) external {
    reject = value;
  }

  function completeRegisteredCommit(address eoa, bytes32 payloadHash, bytes calldata data) external {
    if (reject) revert CommitRejected();
    registryCaller = msg.sender;
    registeredEOA = eoa;
    commitPayloadHash = payloadHash;
    commitData = data;
  }
}
