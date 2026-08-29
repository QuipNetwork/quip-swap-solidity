// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

/// @notice The type of asset exchanged by the protocol.
enum AssetType {
  Native,
  ERC20,
  ERC721,
  ERC1155
}

/// @notice An asset transferred as part of a swap.
/// @dev Native assets use a zero target and id; ERC20 assets use a zero id.
struct Asset {
  AssetType assetType; // Transfer standard used for custody.
  address target; // Token contract, or zero for native currency.
  uint256 id; // Token id for ERC721/ERC1155, otherwise zero.
  uint256 amount; // Native or fungible quantity; one for ERC721.
}

/// @notice Selects the contract boundary that authenticates a commit.
enum AuthorizationMode {
  QuipWallet,
  RegisteredDirect
}

/// @notice Restricts who may transport an authorized commit to its verifier.
enum DelegationPolicy {
  NotAllowed,
  Permissionless,
  SpecificDelegate
}

/// @notice Distinguishes the two deployment and settlement state machines.
enum WrapperMode {
  CrossChain,
  SameChain
}

/// @notice Identifies one side of the ordered protocol terms.
enum SideTag {
  Party,
  Counterparty
}

/// @notice Domain tag for an authorized protocol action.
enum ActionTag {
  Commit
}

/// @notice Operations supported by the direct-user PQ identity registry.
enum RegistryActionTag {
  RotateActive,
  RecoverActive,
  RotateRecovery,
  Revoke
}

/// @notice Identifies the active or recovery key of a direct-user identity.
enum KeyRole {
  Active,
  Recovery
}

/// @notice State that a signed commit expects before it is executed.
enum ExpectedSourceState {
  Unused,
  PartyCommitted
}

/// @notice Lifecycle of one locally escrowed cross-chain leg.
enum CrossChainLegState {
  Unused,
  Committed,
  Claimed,
  Reclaimed
}

/// @notice Lifecycle shared by both legs of a same-chain swap.
enum SameChainState {
  Unused,
  PartyCommitted,
  BothCommitted,
  ClaimPending,
  ReclaimPending,
  Claimed,
  Reclaimed
}

/// @notice Immutable economic, timing, identity, and authorization terms for one side.
/// @dev sideNonce is signed trade uniqueness; actionNonce separately prevents authorization replay.
struct SideTerms {
  uint256 chainId; // Chain on which this payload or side executes.
  Asset[] assets; // Canonically sorted assets escrowed by this side.
  address principal; // Wallet contract or registered direct EOA controlling this side.
  AuthorizationMode authorizationMode; // Authentication boundary selected for commits.
  uint256 principalKeyVersion; // Direct key version, or zero for wallet mode.
  address reclaimRecipient; // Fixed destination when this side reclaims.
  address recipient; // Fixed destination when this side is claimed.
  uint256 commitmentDeadline; // Exclusive upper bound for this side commit.
  uint256 claimDeadline; // Exclusive upper bound for this side claim.
  uint256 reclaimRelease; // Inclusive lower bound for this side reclaim.
  bytes32 commitLock; // Bob progression lock on counterparty cross-chain terms.
  DelegationPolicy delegationPolicy; // Who may transport this side authorization.
  address delegate; // Named broker when policy is SpecificDelegate.
  uint256 delegateKeyVersion; // Registered version required for the named broker.
  bytes32 sideNonce; // Random per-side trade uniqueness used in every run.
}

/// @notice Ordered terms for the party side and counterparty side of one trade.
struct ProtocolTerms {
  SideTerms partySide; // First-committing side, conventionally Alice.
  SideTerms counterpartySide; // Second-committing side, conventionally Bob.
}

/// @notice Canonical signed payload for a commit authorization.
/// @dev Binds authorization to one chain, verifier, wrapper, trade, leg, state, and nonce.
struct CommitPayload {
  uint256 chainId; // Chain on which this payload or side executes.
  WrapperMode mode; // Signed cross-chain or same-chain execution mode.
  address authorizationVerifier; // Wallet or direct gateway that verifies the signature.
  address swapAddress; // Exact wrapper allowed to consume the authorization.
  bytes32 tradeId; // Hash of the complete ordered terms.
  bytes32 lock; // Trade-bound settlement hash lock.
  SideTag side; // Escrow leg authorized by this payload.
  ActionTag action; // Prevents cross-action signature reuse.
  ExpectedSourceState expectedSourceState; // Required state before commit execution.
  bytes32 assetHash; // Hash of the local chain and side asset list.
  address principal; // Wallet contract or registered direct EOA controlling this side.
  uint256 principalKeyVersion; // Direct key version, or zero for wallet mode.
  DelegationPolicy delegationPolicy; // Who may transport this side authorization.
  address delegate; // Named broker when policy is SpecificDelegate.
  uint256 delegateKeyVersion; // Registered version required for the named broker.
  bytes32 actionNonce; // Random authorization replay nonce.
  uint256 commitmentDeadline; // Exclusive upper bound for this side commit.
  uint256 expiry; // Exclusive authorization or operation expiry.
}

/// @notice Evidence produced by an authorization boundary and consumed by a wrapper.
/// @dev The wrapper binds this evidence to msg.sender; it does not verify a PQ signature itself.
struct VerifiedCommitAuthorization {
  bytes32 payloadHash; // Exact commit payload authenticated by the boundary.
  address wrapperCaller; // Boundary address expected as wrapper msg.sender.
  address authenticatedSubmitter; // Actual transport identity under delegation policy.
  uint256 authenticatedSubmitterKeyVersion; // Direct key version, or zero when unkeyed.
  ExpectedSourceState expectedSourceState; // Required state before commit execution.
  bytes32 actionNonce; // Random authorization replay nonce.
  uint256 expiry; // Exclusive authorization or operation expiry.
}

/// @notice Complete request signed and forwarded through a commit authorization boundary.
struct CommitAuthorizationRequest {
  address receiver; // Wrapper receiving the atomic authorized callback.
  ProtocolTerms terms; // Complete ordered protocol terms.
  bool party; // True selects party side; false selects counterparty side.
  bytes32 lock; // Trade-bound settlement hash lock.
  bytes32 actionNonce; // Random authorization replay nonce.
  bytes32 bobCommitSecret; // Cross-chain progression preimage, zero on same-chain.
  uint256 expiry; // Exclusive authorization or operation expiry.
  bytes commitData; // Opaque wrapper-specific data reserved for the callback.
}

/// @notice Versioned active and recovery PQ keys registered for a direct EOA principal.
struct PQIdentity {
  bytes activePQKey; // Verifier-prefixed current active key.
  uint256 activeKeyVersion; // Monotonic active-key version.
  bytes recoveryPQKey; // Verifier-prefixed current recovery key.
  uint256 recoveryKeyVersion; // Monotonic recovery-key version.
  bool active; // False after revocation until recovery.
}

/// @notice Registration request that atomically creates an identity and performs its first commit.
struct InitialRegistration {
  address eoa; // Native account bound to the direct PQ identity.
  bytes activePQKey; // Verifier-prefixed current active key.
  bytes recoveryPQKey; // Verifier-prefixed current recovery key.
  address commitTarget; // Atomic first-commit callback target.
  bytes32 commitPayloadHash; // First commit bound into registration.
  bytes32 operationNonce; // Random registry replay nonce.
  uint256 expiry; // Exclusive authorization or operation expiry.
}

/// @notice Signatures and proofs attached to a registry operation.
struct RegistryAuthorization {
  bytes eoaSignature; // Native EOA consent when the operation requires it.
  bytes authorizingPQSignature; // Active or recovery key authorization.
  bytes activeProofOfPossession; // Proof for newly installed active key.
  bytes recoveryProofOfPossession; // Proof for newly installed recovery key.
}

/// @notice Version-bound request to rotate, recover, or revoke a direct-user identity.
struct RegistryOperation {
  RegistryActionTag action; // Requested identity lifecycle transition.
  address eoa; // Native account bound to the direct PQ identity.
  uint256 expectedActiveKeyVersion; // Optimistic concurrency check for active key.
  uint256 expectedRecoveryKeyVersion; // Optimistic concurrency check for recovery key.
  bytes newActivePQKey; // Replacement active key when the action requires one.
  uint256 newActiveKeyVersion; // Must be exactly the next active version.
  bytes newRecoveryPQKey; // Replacement recovery key when required.
  uint256 newRecoveryKeyVersion; // Must be exactly the next recovery version.
  bytes32 operationNonce; // Random registry replay nonce.
  uint256 expiry; // Exclusive authorization or operation expiry.
  bool recoveryAuthorized; // Selects recovery-key emergency authority.
}
