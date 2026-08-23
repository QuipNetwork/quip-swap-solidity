// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {CommitAuthorization} from '../../src/protocol/CommitValidation.sol';
import {ProtocolTerms, VerifiedCommitAuthorization} from '../../src/protocol/ProtocolTypes.sol';

contract CommitAuthorizationHarness {
  error SimulatedStateFailure();
  error SimulatedCustodyFailure();

  address public immutable directGateway;
  uint256 public stateEffects;
  uint256 public custodyEffects;

  constructor(address directGateway_) {
    directGateway = directGateway_;
  }

  function commitAuthorized(
    ProtocolTerms calldata terms,
    bool party,
    bytes32 lock,
    VerifiedCommitAuthorization calldata evidence,
    uint8 failurePoint
  ) external {
    CommitAuthorization.validate(
      terms, party, directGateway, address(this), lock, msg.sender, evidence, block.timestamp
    );

    ++stateEffects;
    if (failurePoint == 1) revert SimulatedStateFailure();

    ++custodyEffects;
    if (failurePoint == 2) revert SimulatedCustodyFailure();
  }

  function validateOnly(
    ProtocolTerms calldata terms,
    bool party,
    bytes32 lock,
    VerifiedCommitAuthorization calldata evidence
  ) external view returns (bytes32 tradeId) {
    return CommitAuthorization.validate(
      terms, party, directGateway, address(this), lock, msg.sender, evidence, block.timestamp
    );
  }
}
