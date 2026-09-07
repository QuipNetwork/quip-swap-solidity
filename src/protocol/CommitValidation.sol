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

/// @title CommitAuthorization
/// @notice Validates authorization-boundary evidence before a wrapper accepts escrow.
/// @dev Signature verification and action-nonce consumption belong to the wallet or direct gateway.
library CommitAuthorization {
  error InvalidAuthorizationCaller();
  error InvalidAuthorizationPayload();
  error InvalidAuthenticatedSubmitter();
  error InvalidAuthenticatedSubmitterKeyVersion();
  error InvalidExpectedSourceState();
  error AuthorizationExpired();

  /// @notice Checks the expected caller address, payload, submitter policy, expiry, and signed source-state tag.
  /// @dev Wallet mode checks the principal address, not approved wallet implementation provenance.
  ///      The wrapper's state-machine transition separately enforces the actual stored source state.
  function validate(
    ProtocolTerms memory terms,
    bool party,
    address configuredDirectGateway,
    address swapAddress,
    bytes32 lock,
    address actualWrapperCaller,
    VerifiedCommitAuthorization memory evidence,
    uint256 currentTime
  ) internal pure returns (bytes32 tradeId) {
    // Derive the expected boundary address; wallet implementation provenance is not checked here.
    SideTerms memory side = party ? terms.partySide : terms.counterpartySide;
    address verifier = side.authorizationMode == AuthorizationMode.QuipWallet ? side.principal : configuredDirectGateway;
    if (verifier == address(0) || actualWrapperCaller != verifier || evidence.wrapperCaller != actualWrapperCaller) {
      revert InvalidAuthorizationCaller();
    }

    // Require the signed source-state tag for this side and mode; no stored state is read here.
    ExpectedSourceState expectedState = ProtocolHashing.expectedSourceState(party, ProtocolHashing.mode(terms));
    if (evidence.expectedSourceState != expectedState) revert InvalidExpectedSourceState();
    // Authorization expiry is an exclusive upper bound.
    if (currentTime >= evidence.expiry) revert AuthorizationExpired();
    // Enforce the signed delegation policy against the boundary-authenticated transport.
    _validateSubmitter(side, evidence.authenticatedSubmitter, evidence.authenticatedSubmitterKeyVersion);

    // Recompute the exact payload rather than trusting fields supplied in evidence.
    tradeId = ProtocolHashing.tradeId(terms);
    bytes32 expectedPayloadHash = ProtocolHashing.commitPayloadHashWithTradeId(
      terms,
      party,
      verifier,
      swapAddress,
      tradeId,
      lock,
      evidence.expectedSourceState,
      evidence.actionNonce,
      evidence.expiry
    );
    if (evidence.payloadHash != expectedPayloadHash) revert InvalidAuthorizationPayload();
  }

  function _validateSubmitter(SideTerms memory side, address submitter, uint256 submitterKeyVersion) private pure {
    // Every policy requires a nonzero transport identity.
    if (submitter == address(0)) revert InvalidAuthenticatedSubmitter();
    if (side.delegationPolicy == DelegationPolicy.NotAllowed) {
      // Only the principal at its signed key version may transport.
      if (submitter != side.principal) revert InvalidAuthenticatedSubmitter();
      if (submitterKeyVersion != side.principalKeyVersion) revert InvalidAuthenticatedSubmitterKeyVersion();
    } else if (side.delegationPolicy == DelegationPolicy.SpecificDelegate) {
      // Principal remains valid; otherwise require the exact registered delegate version.
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

/// @title ProgressionGate
/// @notice Verifies the trade-bound Bob-commit preimage carried by cross-chain commits.
/// @dev Same-chain commits must carry no Bob-commit secret.
library ProgressionGate {
  error MissingBobCommitSecret();
  error InvalidBobCommitSecret();
  error UnexpectedBobCommitSecret();

  /// @notice Enforces the cross-chain gate or the same-chain zero-secret rule.
  function validate(ProtocolTerms memory terms, bytes32 bobCommitSecret) internal pure {
    // Same-chain progression is the second ordered commit, not a secret.
    if (ProtocolHashing.mode(terms) == WrapperMode.SameChain) {
      if (bobCommitSecret != bytes32(0)) revert UnexpectedBobCommitSecret();
      return;
    }
    // Cross-chain commits reveal a nonzero preimage for the signed commit lock.
    if (bobCommitSecret == bytes32(0)) revert MissingBobCommitSecret();
    // Reconstruct the projected context before checking the trade-bound lock.
    bytes32 contextId = ProtocolHashing.gateContextId(terms);
    if (ProtocolHashing.commitLock(contextId, bobCommitSecret) != terms.counterpartySide.commitLock) {
      revert InvalidBobCommitSecret();
    }
  }
}
