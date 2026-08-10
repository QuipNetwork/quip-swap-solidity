// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {CommitAuthorization} from '../../src/CommitAuthorization.sol';
import {ProgressionGate} from '../../src/ProgressionGate.sol';
import {ProtocolTerms, VerifiedCommitAuthorization} from '../../src/ProtocolTypes.sol';
import {ICommitAuthorizationReceiver} from '../../src/interfaces/ICommitAuthorizationReceiver.sol';

contract AuthorizationReceiverHarness is ICommitAuthorizationReceiver {
  using CommitAuthorization for CommitAuthorization.Layout;
  error SimulatedCommitFailure();

  address public immutable directGateway;
  uint256 public commits;
  address public lastSubmitter;
  bytes public lastCommitData;
  CommitAuthorization.Layout private authorizations;

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
  ) external {
    CommitAuthorization.PreparedAuthorization memory prepared = authorizations.validate(
      terms, party, directGateway, address(this), lock, msg.sender, evidence, block.timestamp
    );
    ProgressionGate.validate(terms, party, bobCommitSecret);
    ++commits;
    lastSubmitter = evidence.authenticatedSubmitter;
    lastCommitData = commitData;
    if (keccak256(commitData) == keccak256('fail')) revert SimulatedCommitFailure();
    authorizations.consume(prepared);
  }
}
