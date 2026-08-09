// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {CommitAuthorization} from '../../src/CommitAuthorization.sol';
import {ProtocolTerms, VerifiedCommitAuthorization} from '../../src/ProtocolTypes.sol';

contract CommitAuthorizationHarness {
  using CommitAuthorization for CommitAuthorization.Layout;

  error SimulatedStateFailure();
  error SimulatedCustodyFailure();

  address public immutable directGateway;
  uint256 public stateEffects;
  uint256 public custodyEffects;
  CommitAuthorization.Layout private authorizations;

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
    CommitAuthorization.PreparedAuthorization memory prepared = authorizations.validate(
      terms, party, directGateway, address(this), lock, msg.sender, evidence, block.timestamp
    );

    ++stateEffects;
    if (failurePoint == 1) revert SimulatedStateFailure();

    ++custodyEffects;
    if (failurePoint == 2) revert SimulatedCustodyFailure();

    authorizations.consume(prepared);
  }

  function validateOnly(
    ProtocolTerms calldata terms,
    bool party,
    bytes32 lock,
    VerifiedCommitAuthorization calldata evidence
  ) external view returns (bytes32 nonceKey) {
    return authorizations.validate(
      terms, party, directGateway, address(this), lock, msg.sender, evidence, block.timestamp
    )
    .nonceKey;
  }

  function isConsumed(bytes32 nonceKey) external view returns (bool) {
    return authorizations.isConsumed(nonceKey);
  }
}
