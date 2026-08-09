// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Asset} from './TermsLib.sol';

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
  bytes32 timingPolicyId;
  SideTerms partySide;
  SideTerms counterpartySide;
}

struct TimingPolicy {
  uint256 policyVersion;
  WrapperMode mode;
  uint256 partyChainId;
  uint256 counterpartyChainId;
  uint256 partyToCounterpartyDelay;
  uint256 counterpartyToPartyDelay;
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
