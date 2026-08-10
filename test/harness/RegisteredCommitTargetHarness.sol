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
  uint256 public valueReceived;

  function setReject(bool value) external {
    reject = value;
  }

  function completeRegisteredCommit(address eoa, address, bytes32 payloadHash, bytes calldata data) external payable {
    if (reject) revert CommitRejected();
    registryCaller = msg.sender;
    registeredEOA = eoa;
    commitPayloadHash = payloadHash;
    commitData = data;
    valueReceived = msg.value;
  }
}
