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
struct Asset {
  AssetType assetType;
  address target;
  uint256 id;
  uint256 amount;
}

enum AuthorizationMode {
  QuipWallet,
  RegisteredDirect
}

enum DelegationPolicy {
  NotAllowed,
  Permissionless,
  SpecificDelegate
}

enum WrapperMode {
  CrossChain,
  SameChain
}

enum SideTag {
  Party,
  Counterparty
}

enum ActionTag {
  Commit
}

enum RegistryActionTag {
  RotateActive,
  RecoverActive,
  RotateRecovery,
  Revoke
}

enum KeyRole {
  Active,
  Recovery
}

enum ExpectedSourceState {
  Unused,
  PartyCommitted
}

enum CrossChainLegState {
  Unused,
  Committed,
  Claimed,
  Reclaimed
}

enum SameChainState {
  Unused,
  PartyCommitted,
  BothCommitted,
  Claimed,
  Reclaimed
}

struct SideTerms {
  uint256 chainId;
  Asset[] assets;
  address principal;
  AuthorizationMode authorizationMode;
  uint256 principalKeyVersion;
  address reclaimRecipient;
  address recipient;
  uint256 commitmentDeadline;
  uint256 claimDeadline;
  uint256 reclaimRelease;
  bytes32 commitLock;
  DelegationPolicy delegationPolicy;
  address delegate;
  uint256 delegateKeyVersion;
  bytes32 sideNonce;
}

struct ProtocolTerms {
  SideTerms partySide;
  SideTerms counterpartySide;
}

struct CommitPayload {
  uint256 chainId;
  WrapperMode mode;
  address authorizationVerifier;
  address swapAddress;
  bytes32 tradeId;
  bytes32 lock;
  SideTag side;
  ActionTag action;
  ExpectedSourceState expectedSourceState;
  bytes32 assetHash;
  address principal;
  uint256 principalKeyVersion;
  DelegationPolicy delegationPolicy;
  address delegate;
  uint256 delegateKeyVersion;
  bytes32 actionNonce;
  uint256 commitmentDeadline;
  uint256 expiry;
}

struct VerifiedCommitAuthorization {
  bytes32 payloadHash;
  address wrapperCaller;
  address authenticatedSubmitter;
  uint256 authenticatedSubmitterKeyVersion;
  ExpectedSourceState expectedSourceState;
  bytes32 actionNonce;
  uint256 expiry;
}

struct CommitAuthorizationRequest {
  address receiver;
  ProtocolTerms terms;
  bool party;
  bytes32 lock;
  bytes32 actionNonce;
  bytes32 bobCommitSecret;
  uint256 expiry;
  bytes commitData;
}

struct PQIdentity {
  bytes activePQKey;
  uint256 activeKeyVersion;
  bytes recoveryPQKey;
  uint256 recoveryKeyVersion;
  bool active;
}

struct InitialRegistration {
  address eoa;
  bytes activePQKey;
  bytes recoveryPQKey;
  address commitTarget;
  bytes32 commitPayloadHash;
  bytes32 operationNonce;
  uint256 expiry;
}

struct RegistryAuthorization {
  bytes eoaSignature;
  bytes authorizingPQSignature;
  bytes activeProofOfPossession;
  bytes recoveryProofOfPossession;
}

struct RegistryOperation {
  RegistryActionTag action;
  address eoa;
  uint256 expectedActiveKeyVersion;
  uint256 expectedRecoveryKeyVersion;
  bytes newActivePQKey;
  uint256 newActiveKeyVersion;
  bytes newRecoveryPQKey;
  uint256 newRecoveryKeyVersion;
  bytes32 operationNonce;
  uint256 expiry;
  bool recoveryAuthorized;
}
