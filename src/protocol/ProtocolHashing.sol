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
  WrapperMode
} from './ProtocolTypes.sol';
import {Asset, AssetType} from './ProtocolTypes.sol';

/// @title ProtocolHashing
/// @notice Validates protocol terms and computes every domain-separated protocol identifier.
/// @dev Off-chain clients must reproduce these encodings byte-for-byte when building signatures.
library ProtocolHashing {
  string internal constant TERMS_DOMAIN = 'InterlockTerms-v1.1';
  string internal constant GATE_CONTEXT_DOMAIN = 'InterlockBobCommitGateContext-v1.1';
  string internal constant BOB_COMMIT_GATE_DOMAIN = 'InterlockBobCommitGate-v1.1';
  string internal constant SETTLEMENT_LOCK_DOMAIN = 'InterlockSettlementLock-v1.1';
  string internal constant ASSETS_DOMAIN = 'InterlockAssets-v1.1';
  string internal constant SIDE_TERMS_DOMAIN = 'InterlockSideTerms-v1.1';
  string internal constant COMMIT_DOMAIN = 'InterlockCommit-v1.1';

  error InvalidTerms();

  /// @notice Derives the wrapper mode from the two side chain identifiers.
  function mode(ProtocolTerms memory terms) internal pure returns (WrapperMode) {
    return terms.partySide.chainId == terms.counterpartySide.chainId ? WrapperMode.SameChain : WrapperMode.CrossChain;
  }

  /// @notice Converts the ordered-side selector into its signed enum tag.
  function sideTag(bool partySide) internal pure returns (SideTag) {
    return partySide ? SideTag.Party : SideTag.Counterparty;
  }

  /// @notice Hashes complete ordered terms under the supplied domain.
  function hashTerms(string memory domain, ProtocolTerms memory terms) internal pure returns (bytes32) {
    return keccak256(abi.encode(domain, terms));
  }

  /// @notice Computes the canonical identifier for one exact set of ordered terms.
  function tradeId(ProtocolTerms memory terms) internal pure returns (bytes32) {
    return hashTerms(TERMS_DOMAIN, terms);
  }

  /// @notice Returns the terms projection Bob hashes before choosing the commit secret.
  /// @dev Only the counterparty commit lock is cleared; all other fields remain bound.
  function gateTerms(ProtocolTerms memory terms) internal pure returns (ProtocolTerms memory projected) {
    // Deep-copy dynamic asset arrays before clearing the self-referential field.
    projected = abi.decode(abi.encode(terms), (ProtocolTerms));
    projected.counterpartySide.commitLock = bytes32(0);
  }

  /// @notice Computes the Bob-commit gate context without its self-referential commit lock.
  function gateContextId(ProtocolTerms memory terms) internal pure returns (bytes32 contextId) {
    // Save and clear Bob commit lock so the context does not hash itself.
    bytes32 commitLock = terms.counterpartySide.commitLock;
    terms.counterpartySide.commitLock = bytes32(0);
    contextId = hashTerms(GATE_CONTEXT_DOMAIN, terms);
    // Restore the caller-owned memory value before returning.
    terms.counterpartySide.commitLock = commitLock;
  }

  /// @notice Binds the Bob-commit preimage to one projected gate context.
  function commitLock(bytes32 contextId, bytes32 bobCommitSecret) internal pure returns (bytes32) {
    return keccak256(abi.encode(BOB_COMMIT_GATE_DOMAIN, contextId, bobCommitSecret));
  }

  /// @notice Binds the settlement preimage to one trade identifier.
  function settlementLock(bytes32 trade, bytes32 secret) internal pure returns (bytes32) {
    return keccak256(abi.encode(SETTLEMENT_LOCK_DOMAIN, trade, secret));
  }

  /// @notice Hashes the assets escrowed by one side on its named chain.
  function assetHash(SideTerms memory side) internal pure returns (bytes32) {
    return keccak256(abi.encode(ASSETS_DOMAIN, side.chainId, side.assets));
  }

  /// @notice Hashes one complete signed side for binding to its dedicated custody contract.
  function sideTermsHash(SideTerms memory side) internal pure returns (bytes32) {
    return keccak256(abi.encode(SIDE_TERMS_DOMAIN, side));
  }

  /// @notice Returns the state a commit authorization must expect at execution.
  function expectedSourceState(bool party, WrapperMode wrapperMode) internal pure returns (ExpectedSourceState) {
    return
      !party && wrapperMode == WrapperMode.SameChain ? ExpectedSourceState.PartyCommitted : ExpectedSourceState.Unused;
  }

  /// @notice Computes a commit payload hash from terms and the derived trade identifier.
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
    return commitPayloadHashWithTradeId(
      terms, party, authorizationVerifier, swapAddress, tradeId(terms), lock, sourceState, actionNonce, expiry
    );
  }

  /// @notice Computes the exact domain-separated payload authenticated by a commit signature.
  function commitPayloadHashWithTradeId(
    ProtocolTerms memory terms,
    bool party,
    address authorizationVerifier,
    address swapAddress,
    bytes32 trade,
    bytes32 lock,
    ExpectedSourceState sourceState,
    bytes32 actionNonce,
    uint256 expiry
  ) internal pure returns (bytes32) {
    // Select the signed side and assemble every authorization field explicitly.
    SideTerms memory side = party ? terms.partySide : terms.counterpartySide;
    CommitPayload memory payload = CommitPayload({
      chainId: side.chainId,
      mode: mode(terms),
      authorizationVerifier: authorizationVerifier,
      swapAddress: swapAddress,
      tradeId: trade,
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
    // The fixed domain prevents this payload from being reused as another message type.
    return keccak256(abi.encode(COMMIT_DOMAIN, payload));
  }

  /// @notice Encodes the scope used to prevent commit-authorization nonce reuse.
  function encodeAuthorizationNonceKey(
    uint256 chainId,
    address authorizationVerifier,
    address principal,
    uint256 principalKeyVersion,
    bytes32 actionNonce
  ) internal pure returns (bytes memory) {
    return abi.encode(chainId, authorizationVerifier, principal, principalKeyVersion, actionNonce);
  }

  /// @notice Encodes the scope used to prevent identity-operation nonce reuse.
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

  /// @notice Reverts unless both sides and their pairing form canonical valid protocol terms.
  /// @dev Asset arrays must be strictly sorted by identity, which also excludes duplicates.
  function validateTerms(ProtocolTerms memory terms) internal pure {
    // Chain equality selects the validation rules before any state is consulted.
    WrapperMode wrapperMode = mode(terms);
    if (
      terms.partySide.chainId == 0 || terms.counterpartySide.chainId == 0 || terms.partySide.principal == address(0)
        || terms.counterpartySide.principal == address(0)
    ) revert InvalidTerms();

    // Validate each side independently before checking their cross-side schedule.
    _validateSide(terms.partySide);
    _validateSide(terms.counterpartySide);

    // Alice commits first, Bob commits second, and Alice claim opens after both.
    if (!(terms.partySide.commitmentDeadline < terms.counterpartySide.commitmentDeadline
          && terms.counterpartySide.commitmentDeadline < terms.partySide.claimDeadline)) revert InvalidTerms();

    // The progression gate belongs only to the counterparty side.
    if (terms.partySide.commitLock != bytes32(0)) revert InvalidTerms();
    if (wrapperMode == WrapperMode.SameChain) {
      // Same-chain atomic settlement has no progression gate.
      if (terms.counterpartySide.commitLock != bytes32(0)) revert InvalidTerms();
      // Both escrows must remain claimable until the earlier claim deadline.
      uint256 claimDeadline = terms.partySide.claimDeadline < terms.counterpartySide.claimDeadline
        ? terms.partySide.claimDeadline
        : terms.counterpartySide.claimDeadline;
      if (claimDeadline >= terms.partySide.reclaimRelease || claimDeadline >= terms.counterpartySide.reclaimRelease) {
        revert InvalidTerms();
      }
    } else {
      // Cross-chain execution requires Bob trade-bound progression lock.
      if (terms.counterpartySide.commitLock == bytes32(0)) revert InvalidTerms();
      if (
        terms.partySide.claimDeadline > terms.counterpartySide.reclaimRelease
          || terms.counterpartySide.claimDeadline > terms.partySide.reclaimRelease
      ) revert InvalidTerms();
    }
  }

  function _validateSide(SideTerms memory side) private pure {
    // Require payable destinations, at least one asset, and strict local timing.
    if (
      side.recipient == address(0) || side.reclaimRecipient == address(0) || side.assets.length == 0
        || !(side.commitmentDeadline < side.claimDeadline && side.claimDeadline < side.reclaimRelease)
    ) revert InvalidTerms();
    // Wallet keys are internal and version zero; direct keys are registry-versioned.
    if (side.authorizationMode == AuthorizationMode.QuipWallet) {
      if (side.principalKeyVersion != 0) revert InvalidTerms();
    } else if (side.principalKeyVersion == 0) {
      revert InvalidTerms();
    }

    // Canonicalize delegate fields so inactive policies cannot carry ignored values.
    if (side.delegationPolicy == DelegationPolicy.SpecificDelegate) {
      if (side.delegate == address(0) || side.delegateKeyVersion == 0) revert InvalidTerms();
    } else if (side.delegate != address(0) || side.delegateKeyVersion != 0) {
      revert InvalidTerms();
    }

    // Strict identity order rejects duplicates and creates one canonical encoding.
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
}
