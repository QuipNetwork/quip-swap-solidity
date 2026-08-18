// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {
  ActionTag,
  AuthorizationMode,
  CommitPayload,
  DelegationPolicy,
  ExpectedSourceState,
  ProtocolTerms,
  SideTag,
  SideTerms,
  TimingPolicy,
  WrapperMode
} from './ProtocolTypes.sol';
import {Asset, AssetType} from './ProtocolTypes.sol';

library ProtocolHashing {
  string internal constant TERMS_DOMAIN = 'InterlockTerms-v1.1';
  string internal constant GATE_CONTEXT_DOMAIN = 'InterlockBobCommitGateContext-v1.1';
  string internal constant BOB_COMMIT_GATE_DOMAIN = 'InterlockBobCommitGate-v1.1';
  string internal constant SETTLEMENT_LOCK_DOMAIN = 'InterlockSettlementLock-v1.1';
  string internal constant TIMING_POLICY_DOMAIN = 'InterlockTimingPolicy-v1.1';
  string internal constant ASSETS_DOMAIN = 'InterlockAssets-v1.1';
  string internal constant COMMIT_DOMAIN = 'InterlockCommit-v1.1';

  error InvalidTerms();

  function mode(ProtocolTerms memory terms) internal pure returns (WrapperMode) {
    return terms.partySide.chainId == terms.counterpartySide.chainId ? WrapperMode.SameChain : WrapperMode.CrossChain;
  }

  function sideTag(bool partySide) internal pure returns (SideTag) {
    return partySide ? SideTag.Party : SideTag.Counterparty;
  }

  function hashTerms(string memory domain, ProtocolTerms memory terms) internal pure returns (bytes32) {
    return keccak256(abi.encode(domain, terms));
  }

  function tradeId(ProtocolTerms memory terms) internal pure returns (bytes32) {
    return hashTerms(TERMS_DOMAIN, terms);
  }

  function gateTerms(ProtocolTerms memory terms) internal pure returns (ProtocolTerms memory projected) {
    projected = abi.decode(abi.encode(terms), (ProtocolTerms));
    projected.counterpartySide.commitLock = bytes32(0);
  }

  function gateContextId(ProtocolTerms memory terms) internal pure returns (bytes32) {
    return hashTerms(GATE_CONTEXT_DOMAIN, gateTerms(terms));
  }

  function commitLock(bytes32 contextId, bytes32 bobCommitSecret) internal pure returns (bytes32) {
    return keccak256(abi.encode(BOB_COMMIT_GATE_DOMAIN, contextId, bobCommitSecret));
  }

  function settlementLock(bytes32 trade, bytes32 secret) internal pure returns (bytes32) {
    return keccak256(abi.encode(SETTLEMENT_LOCK_DOMAIN, trade, secret));
  }

  function timingPolicyId(TimingPolicy memory policy) internal pure returns (bytes32) {
    return keccak256(abi.encode(TIMING_POLICY_DOMAIN, policy));
  }

  function assetHash(SideTerms memory side) internal pure returns (bytes32) {
    return keccak256(abi.encode(ASSETS_DOMAIN, side.chainId, side.assets));
  }

  function expectedSourceState(bool party, WrapperMode wrapperMode) internal pure returns (ExpectedSourceState) {
    return
      !party && wrapperMode == WrapperMode.SameChain ? ExpectedSourceState.PartyCommitted : ExpectedSourceState.Unused;
  }

  function commitPayloadHash(
    ProtocolTerms memory terms,
    bool party,
    address authorizationVerifier,
    address swapAddress,
    bytes32 lock,
    ExpectedSourceState sourceState,
    bytes32 actionNonce,
    uint256 expiry
  ) internal pure returns (bytes32) {
    SideTerms memory side = party ? terms.partySide : terms.counterpartySide;
    CommitPayload memory payload = CommitPayload({
      chainId: side.chainId,
      mode: mode(terms),
      authorizationVerifier: authorizationVerifier,
      swapAddress: swapAddress,
      tradeId: tradeId(terms),
      lock: lock,
      side: sideTag(party),
      action: ActionTag.Commit,
      expectedSourceState: sourceState,
      assetHash: assetHash(side),
      principal: side.principal,
      principalKeyVersion: side.principalKeyVersion,
      delegationPolicy: side.delegationPolicy,
      delegate: side.delegate,
      delegateKeyVersion: side.delegateKeyVersion,
      actionNonce: actionNonce,
      commitmentDeadline: side.commitmentDeadline,
      expiry: expiry
    });
    return keccak256(abi.encode(COMMIT_DOMAIN, payload));
  }

  function encodeAuthorizationNonceKey(
    uint256 chainId,
    address authorizationVerifier,
    address principal,
    uint256 principalKeyVersion,
    bytes32 actionNonce
  ) internal pure returns (bytes memory) {
    return abi.encode(chainId, authorizationVerifier, principal, principalKeyVersion, actionNonce);
  }

  function encodeRegistryNonceKey(
    uint256 chainId,
    address registryAddress,
    address eoa,
    uint8 authorizingKeyRole,
    uint256 authorizingKeyVersion,
    bytes32 operationNonce
  ) internal pure returns (bytes memory) {
    return abi.encode(chainId, registryAddress, eoa, authorizingKeyRole, authorizingKeyVersion, operationNonce);
  }

  function validateTerms(ProtocolTerms memory terms, TimingPolicy memory policy) internal pure {
    WrapperMode wrapperMode = mode(terms);
    if (
      terms.partySide.chainId == 0 || terms.counterpartySide.chainId == 0 || terms.partySide.principal == address(0)
        || terms.counterpartySide.principal == address(0) || timingPolicyId(policy) != terms.timingPolicyId
        || policy.mode != wrapperMode || policy.partyChainId != terms.partySide.chainId
        || policy.counterpartyChainId != terms.counterpartySide.chainId
    ) revert InvalidTerms();

    _validateSide(terms.partySide);
    _validateSide(terms.counterpartySide);

    if (!(terms.partySide.commitmentDeadline < terms.counterpartySide.commitmentDeadline
          && terms.counterpartySide.commitmentDeadline < terms.partySide.claimDeadline)) revert InvalidTerms();

    if (terms.partySide.commitLock != bytes32(0)) revert InvalidTerms();
    if (wrapperMode == WrapperMode.SameChain) {
      if (
        terms.counterpartySide.commitLock != bytes32(0) || policy.partyToCounterpartyDelay != 0
          || policy.counterpartyToPartyDelay != 0
      ) revert InvalidTerms();
      uint256 claimDeadline = terms.partySide.claimDeadline < terms.counterpartySide.claimDeadline
        ? terms.partySide.claimDeadline
        : terms.counterpartySide.claimDeadline;
      if (claimDeadline >= terms.partySide.reclaimRelease || claimDeadline >= terms.counterpartySide.reclaimRelease) {
        revert InvalidTerms();
      }
    } else {
      if (terms.counterpartySide.commitLock == bytes32(0)) revert InvalidTerms();
      if (
        !_sumLte(terms.partySide.claimDeadline, policy.partyToCounterpartyDelay, terms.counterpartySide.reclaimRelease)
          || !_sumLte(
            terms.counterpartySide.claimDeadline, policy.counterpartyToPartyDelay, terms.partySide.reclaimRelease
          )
      ) revert InvalidTerms();
    }
  }

  function _validateSide(SideTerms memory side) private pure {
    if (
      side.recipient == address(0) || side.reclaimRecipient == address(0) || side.assets.length == 0
        || !(side.commitmentDeadline < side.claimDeadline && side.claimDeadline < side.reclaimRelease)
    ) revert InvalidTerms();
    if (side.authorizationMode == AuthorizationMode.QuipWallet) {
      if (side.principalKeyVersion != 0) revert InvalidTerms();
    } else if (side.principalKeyVersion == 0) {
      revert InvalidTerms();
    }

    if (side.delegationPolicy == DelegationPolicy.SpecificDelegate) {
      if (side.delegate == address(0) || side.delegateKeyVersion == 0) revert InvalidTerms();
    } else if (side.delegate != address(0) || side.delegateKeyVersion != 0) {
      revert InvalidTerms();
    }

    for (uint256 i; i < side.assets.length; ++i) {
      Asset memory asset = side.assets[i];
      if (!_validAsset(asset)) revert InvalidTerms();
      if (i != 0 && !_assetIdentityLess(side.assets[i - 1], asset)) revert InvalidTerms();
    }
  }

  function _validAsset(Asset memory asset) private pure returns (bool) {
    if (asset.amount == 0) return false;
    if (asset.assetType == AssetType.Native) return asset.target == address(0) && asset.id == 0;
    if (asset.assetType == AssetType.ERC20) return asset.target != address(0) && asset.id == 0;
    if (asset.assetType == AssetType.ERC721) return asset.target != address(0) && asset.amount == 1;
    if (asset.assetType == AssetType.ERC1155) return asset.target != address(0);
    return false;
  }

  function _assetIdentityLess(Asset memory a, Asset memory b) private pure returns (bool) {
    if (uint8(a.assetType) != uint8(b.assetType)) return uint8(a.assetType) < uint8(b.assetType);
    if (a.target != b.target) return uint160(a.target) < uint160(b.target);
    return a.id < b.id;
  }

  function _sumLte(uint256 a, uint256 b, uint256 upper) private pure returns (bool) {
    return b <= type(uint256).max - a && a + b <= upper;
  }
}
