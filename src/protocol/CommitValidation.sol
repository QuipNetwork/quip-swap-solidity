// SPDX-License-Identifier: UNLICENSE
// Pin the compiler version used for these encodings and contract semantics.
pragma solidity 0.8.33;

// Import canonical term validation and domain-separated identifiers.
import {ProtocolHashing} from './ProtocolHashing.sol';
// Import the canonical types used by this protocol component.
import {

  // Wallet-versus-direct authentication selection.
  AuthorizationMode,

  // Principal-only, permissionless, or named-delegate transport policy.
  DelegationPolicy,

  // Lifecycle source-state tag authenticated by the commit.
  ExpectedSourceState,

  // Ordered Alice and Bob side terms.
  ProtocolTerms,

  // One side's signed assets, identities, destinations, and deadlines.
  SideTerms,

  // Evidence passed from a wallet or direct gateway to the wrapper.
  VerifiedCommitAuthorization,

  // Cross-chain or same-chain execution discriminator.
  WrapperMode
} from './ProtocolTypes.sol';

/// @title CommitAuthorization
/// @notice Validates authorization-boundary evidence before a wrapper accepts escrow.
/// @dev Signature verification and action-nonce consumption belong to the wallet or direct gateway.
library CommitAuthorization {
  // The caller or evidence source is not the expected authorization boundary.
  error InvalidAuthorizationCaller();
  // The authenticated payload does not match the reconstructed commit.
  error InvalidAuthorizationPayload();
  // The transport identity is zero or disallowed by the signed policy.
  error InvalidAuthenticatedSubmitter();
  // The transport key version differs from the signed principal or delegate version.
  error InvalidAuthenticatedSubmitterKeyVersion();
  // The signed source-state tag does not match this side and mode.
  error InvalidExpectedSourceState();
  // The exclusive authorization expiry has been reached.
  error AuthorizationExpired();

  /// @notice Checks the expected caller address, payload, submitter policy, expiry, and signed source-state tag.
  /// @dev Wallet mode checks the principal address, not approved wallet implementation provenance.
  ///      The wrapper's state-machine transition separately enforces the actual stored source state.
  function validate(
    // Complete ordered terms whose hash binds the stored record.
    ProtocolTerms memory terms,
    // True selects Alice's party side; false selects Bob's counterparty side.
    bool party,
    // Deployment-pinned gateway used for RegisteredDirect mode.
    address configuredDirectGateway,
    // Exact wrapper permitted to consume the authorization.
    address swapAddress,
    // Trade-bound settlement hash lock.
    bytes32 lock,
    // Actual msg.sender observed by the receiving wrapper.
    address actualWrapperCaller,
    // Caller, submitter, and payload evidence produced by the authorization boundary.
    VerifiedCommitAuthorization memory evidence,
    // Caller-supplied current time used for the exclusive authorization expiry.
    uint256 currentTime
    // Compute and return the verified trade identifier without reading or changing storage.
  ) internal pure returns (bytes32 tradeId) {
    // Derive the expected boundary address; wallet implementation provenance is not checked here.
    SideTerms memory side = party ? terms.partySide : terms.counterpartySide;
    // Select the wallet principal or configured direct gateway as the only valid evidence source.
    address verifier = side.authorizationMode == AuthorizationMode.QuipWallet ? side.principal : configuredDirectGateway;
    // Bind the evidence source to both the expected verifier and the actual callback caller.
    if (verifier == address(0) || actualWrapperCaller != verifier || evidence.wrapperCaller != actualWrapperCaller) {
      // The caller or evidence source is not the expected authorization boundary.
      revert InvalidAuthorizationCaller();
    }

    // Require the signed source-state tag for this side and mode; no stored state is read here.
    ExpectedSourceState expectedState = ProtocolHashing.expectedSourceState(party, ProtocolHashing.mode(terms));
    // The signed source-state tag does not match this side and mode.
    if (evidence.expectedSourceState != expectedState) revert InvalidExpectedSourceState();

    // Authorization expiry is an exclusive upper bound.
    if (currentTime >= evidence.expiry) revert AuthorizationExpired();

    // Enforce the signed delegation policy against the boundary-authenticated transport.
    _validateSubmitter(side, evidence.authenticatedSubmitter, evidence.authenticatedSubmitterKeyVersion);

    // Recompute the exact payload rather than trusting fields supplied in evidence.
    tradeId = ProtocolHashing.tradeId(terms);
    // Reconstruct the signed payload using the trade identifier computed above.
    bytes32 expectedPayloadHash = ProtocolHashing.commitPayloadHashWithTradeId(
      // Complete ordered terms whose hash binds the stored record.
      terms,
      // True selects Alice's party side; false selects Bob's counterparty side.
      party,
      // Use the verifier selected from the signed authorization mode.
      verifier,
      // Exact wrapper permitted to consume the authorization.
      swapAddress,
      // Hash of the complete ordered terms.
      tradeId,
      // Trade-bound settlement hash lock.
      lock,
      // Bind the source-state tag authenticated by the boundary.
      evidence.expectedSourceState,
      // Bind the nonce already consumed by the authorization boundary.
      evidence.actionNonce,
      // Bind the exclusive expiry authenticated by the boundary.
      evidence.expiry
    );

    // The authenticated payload does not match the reconstructed commit.
    if (evidence.payloadHash != expectedPayloadHash) revert InvalidAuthorizationPayload();
  }

  // Check transport identity and key version against the signed delegation policy.
  function _validateSubmitter(SideTerms memory side, address submitter, uint256 submitterKeyVersion) private pure {
    // Every policy requires a nonzero transport identity.
    if (submitter == address(0)) revert InvalidAuthenticatedSubmitter();

    // Take the nondelegated branch when only the principal may submit.
    if (side.delegationPolicy == DelegationPolicy.NotAllowed) {
      // Only the principal at its signed key version may transport.
      if (submitter != side.principal) revert InvalidAuthenticatedSubmitter();
      // The transport key version differs from the signed principal or delegate version.
      if (submitterKeyVersion != side.principalKeyVersion) revert InvalidAuthenticatedSubmitterKeyVersion();
      // For a named delegate, accept either the principal or that exact registered delegate.
    } else if (side.delegationPolicy == DelegationPolicy.SpecificDelegate) {
      // Principal remains valid; otherwise require the exact registered delegate version.
      if (submitter == side.principal) {
        // The transport key version differs from the signed principal or delegate version.
        if (submitterKeyVersion != side.principalKeyVersion) revert InvalidAuthenticatedSubmitterKeyVersion();
        // Apply the named delegate key-version constraint when the delegate transports the commit.
      } else if (submitter == side.delegate) {
        // The transport key version differs from the signed principal or delegate version.
        if (submitterKeyVersion != side.delegateKeyVersion) revert InvalidAuthenticatedSubmitterKeyVersion();
        // Reject any transport identity that is neither the principal nor the named delegate.
      } else {
        // The transport identity is zero or disallowed by the signed policy.
        revert InvalidAuthenticatedSubmitter();
      }
    }
  }
}

/// @title ProgressionGate
/// @notice Verifies the trade-bound Bob-commit preimage carried by cross-chain commits.
/// @dev Same-chain commits must carry no Bob-commit secret.
library ProgressionGate {
  // Cross-chain progression requires a nonzero preimage.
  error MissingBobCommitSecret();
  // The progression preimage does not open Bob's trade-bound commit lock.
  error InvalidBobCommitSecret();
  // Same-chain commits must not carry a progression preimage.
  error UnexpectedBobCommitSecret();

  /// @notice Enforces the cross-chain gate or the same-chain zero-secret rule.
  function validate(ProtocolTerms memory terms, bytes32 bobCommitSecret) internal pure {
    // Same-chain progression is the second ordered commit, not a secret.
    if (ProtocolHashing.mode(terms) == WrapperMode.SameChain) {
      // Same-chain commits must not carry a progression preimage.
      if (bobCommitSecret != bytes32(0)) revert UnexpectedBobCommitSecret();
      // Same-chain progression needs no preimage after the zero-secret check succeeds.
      return;
    }

    // Cross-chain commits reveal a nonzero preimage for the signed commit lock.
    if (bobCommitSecret == bytes32(0)) revert MissingBobCommitSecret();

    // Reconstruct the projected context before checking the trade-bound lock.
    bytes32 contextId = ProtocolHashing.gateContextId(terms);
    // Compare the recomputed progression lock with Bob's signed lock.
    if (ProtocolHashing.commitLock(contextId, bobCommitSecret) != terms.counterpartySide.commitLock) {
      // The progression preimage does not open Bob's trade-bound commit lock.
      revert InvalidBobCommitSecret();
    }
  }
}
