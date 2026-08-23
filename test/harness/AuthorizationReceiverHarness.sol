// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {ICommitAuthorizationReceiver} from '../../src/interfaces/ICommitAuthorizationReceiver.sol';
import {CommitAuthorization} from '../../src/protocol/CommitValidation.sol';
import {ProgressionGate} from '../../src/protocol/CommitValidation.sol';
import {ProtocolTerms, VerifiedCommitAuthorization} from '../../src/protocol/ProtocolTypes.sol';

contract AuthorizationReceiverHarness is ICommitAuthorizationReceiver {
  error SimulatedCommitFailure();

  address public immutable directGateway;
  uint256 public commits;
  address public lastSubmitter;
  bytes public lastCommitData;

  constructor(address gateway) {
    directGateway = gateway;
  }

  function receiveAuthorizedCommit(
    ProtocolTerms calldata terms,
    bool party,
    bytes32 lock,
    bytes32 bobCommitSecret,
    VerifiedCommitAuthorization calldata evidence,
    bytes calldata commitData
  ) external payable {
    CommitAuthorization.validate(
      terms, party, directGateway, address(this), lock, msg.sender, evidence, block.timestamp
    );
    ProgressionGate.validate(terms, bobCommitSecret);
    ++commits;
    lastSubmitter = evidence.authenticatedSubmitter;
    lastCommitData = commitData;
    if (keccak256(commitData) == keccak256('fail')) revert SimulatedCommitFailure();
  }
}
