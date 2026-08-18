// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {ProtocolHashing} from './ProtocolHashing.sol';
import {
  AuthorizationMode,
  DelegationPolicy,
  ExpectedSourceState,
  ProtocolTerms,
  SideTerms,
  VerifiedCommitAuthorization,
  WrapperMode
} from './ProtocolTypes.sol';

library CommitAuthorization {
  error InvalidAuthorizationCaller();
  error InvalidAuthorizationPayload();
  error InvalidAuthenticatedSubmitter();
  error InvalidAuthenticatedSubmitterKeyVersion();
  error InvalidExpectedSourceState();
  error AuthorizationExpired();
  error AuthorizationNonceAlreadyConsumed(bytes32 nonceKey);

  event AuthorizationNonceConsumed(bytes32 indexed nonceKey, bytes32 indexed actionNonce, address indexed principal);

  struct Layout {
    mapping(bytes32 nonceKey => bool consumed) consumedNonces;
  }

  struct PreparedAuthorization {
    bytes32 nonceKey;
    bytes32 actionNonce;
    address principal;
  }

  function validate(
    Layout storage self,
    ProtocolTerms memory terms,
    bool party,
    address configuredDirectGateway,
    address swapAddress,
    bytes32 lock,
    address actualWrapperCaller,
    VerifiedCommitAuthorization memory evidence,
    uint256 currentTime
  ) internal view returns (PreparedAuthorization memory prepared) {
    SideTerms memory side = party ? terms.partySide : terms.counterpartySide;
    address verifier = side.authorizationMode == AuthorizationMode.QuipWallet ? side.principal : configuredDirectGateway;
    if (verifier == address(0) || actualWrapperCaller != verifier || evidence.wrapperCaller != actualWrapperCaller) {
      revert InvalidAuthorizationCaller();
    }

    WrapperMode wrapperMode = ProtocolHashing.mode(terms);
    ExpectedSourceState expectedState = ProtocolHashing.expectedSourceState(party, wrapperMode);
    if (evidence.expectedSourceState != expectedState) revert InvalidExpectedSourceState();
    if (currentTime >= evidence.expiry) revert AuthorizationExpired();
    _validateSubmitter(side, evidence.authenticatedSubmitter, evidence.authenticatedSubmitterKeyVersion);

    bytes32 expectedPayloadHash = ProtocolHashing.commitPayloadHash(
      terms, party, verifier, swapAddress, lock, evidence.expectedSourceState, evidence.actionNonce, evidence.expiry
    );
    if (evidence.payloadHash != expectedPayloadHash) revert InvalidAuthorizationPayload();

    prepared.nonceKey = keccak256(
      ProtocolHashing.encodeAuthorizationNonceKey(
        side.chainId, verifier, side.principal, side.principalKeyVersion, evidence.actionNonce
      )
    );
    if (self.consumedNonces[prepared.nonceKey]) revert AuthorizationNonceAlreadyConsumed(prepared.nonceKey);
    prepared.actionNonce = evidence.actionNonce;
    prepared.principal = side.principal;
  }

  function consume(Layout storage self, PreparedAuthorization memory prepared) internal {
    if (self.consumedNonces[prepared.nonceKey]) revert AuthorizationNonceAlreadyConsumed(prepared.nonceKey);
    self.consumedNonces[prepared.nonceKey] = true;
    emit AuthorizationNonceConsumed(prepared.nonceKey, prepared.actionNonce, prepared.principal);
  }

  function isConsumed(Layout storage self, bytes32 nonceKey) internal view returns (bool) {
    return self.consumedNonces[nonceKey];
  }

  function _validateSubmitter(SideTerms memory side, address submitter, uint256 submitterKeyVersion) private pure {
    if (submitter == address(0)) revert InvalidAuthenticatedSubmitter();
    if (side.delegationPolicy == DelegationPolicy.NotAllowed) {
      if (submitter != side.principal) revert InvalidAuthenticatedSubmitter();
      if (submitterKeyVersion != side.principalKeyVersion) revert InvalidAuthenticatedSubmitterKeyVersion();
    } else if (side.delegationPolicy == DelegationPolicy.SpecificDelegate) {
      if (submitter == side.principal) {
        if (submitterKeyVersion != side.principalKeyVersion) revert InvalidAuthenticatedSubmitterKeyVersion();
      } else if (submitter == side.delegate) {
        if (submitterKeyVersion != side.delegateKeyVersion) revert InvalidAuthenticatedSubmitterKeyVersion();
      } else {
        revert InvalidAuthenticatedSubmitter();
      }
    }
  }
}

library ProgressionGate {
  error InvalidProgressionTerms();
  error MissingBobCommitSecret();
  error InvalidBobCommitSecret();
  error UnexpectedBobCommitSecret();

  function validate(ProtocolTerms memory terms, bool, bytes32 bobCommitSecret) internal pure {
    if (terms.partySide.commitLock != bytes32(0)) revert InvalidProgressionTerms();
    WrapperMode mode = ProtocolHashing.mode(terms);
    if (mode == WrapperMode.SameChain) {
      if (terms.counterpartySide.commitLock != bytes32(0)) revert InvalidProgressionTerms();
      if (bobCommitSecret != bytes32(0)) revert UnexpectedBobCommitSecret();
      return;
    }
    if (terms.counterpartySide.commitLock == bytes32(0)) revert InvalidProgressionTerms();
    if (bobCommitSecret == bytes32(0)) revert MissingBobCommitSecret();
    bytes32 contextId = ProtocolHashing.gateContextId(terms);
    if (ProtocolHashing.commitLock(contextId, bobCommitSecret) != terms.counterpartySide.commitLock) {
      revert InvalidBobCommitSecret();
    }
  }
}
