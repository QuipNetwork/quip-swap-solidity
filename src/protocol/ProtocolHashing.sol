// SPDX-License-Identifier: UNLICENSE
// Pin the compiler version used for these encodings and contract semantics.
pragma solidity 0.8.33;

// Import the canonical types used by this protocol component.
import {

  // Signed protocol-action discriminator.
  ActionTag,

  // Wallet-versus-direct authentication selection.
  AuthorizationMode,

  // Complete domain-bound structure authenticated by commit signatures.
  CommitPayload,

  // Principal-only, permissionless, or named-delegate transport policy.
  DelegationPolicy,

  // Lifecycle source-state tag authenticated by the commit.
  ExpectedSourceState,

  // Ordered Alice and Bob side terms.
  ProtocolTerms,

  // Canonical party and counterparty side tags.
  SideTag,

  // One side's signed assets, identities, destinations, and deadlines.
  SideTerms,

  // Cross-chain or same-chain execution discriminator.
  WrapperMode
} from './ProtocolTypes.sol';
// Import canonical token identity and quantity representation; Supported native, fungible, and NFT transfer-standard
// tags.
import {Asset, AssetType} from './ProtocolTypes.sol';

/// @title ProtocolHashing
/// @notice Validates protocol terms and computes every domain-separated protocol identifier.
/// @dev Off-chain clients must reproduce these encodings byte-for-byte when building signatures.
library ProtocolHashing {
  // Separate terms domain hashes from other protocol messages.
  string internal constant TERMS_DOMAIN = 'InterlockTerms-v1.1';
  // Separate gate context domain hashes from other protocol messages.
  string internal constant GATE_CONTEXT_DOMAIN = 'InterlockBobCommitGateContext-v1.1';
  // Separate bob commit gate domain hashes from other protocol messages.
  string internal constant BOB_COMMIT_GATE_DOMAIN = 'InterlockBobCommitGate-v1.1';
  // Separate settlement lock domain hashes from other protocol messages.
  string internal constant SETTLEMENT_LOCK_DOMAIN = 'InterlockSettlementLock-v1.1';
  // Separate assets domain hashes from other protocol messages.
  string internal constant ASSETS_DOMAIN = 'InterlockAssets-v1.1';
  // Separate side terms domain hashes from other protocol messages.
  string internal constant SIDE_TERMS_DOMAIN = 'InterlockSideTerms-v1.1';
  // Separate commit domain hashes from other protocol messages.
  string internal constant COMMIT_DOMAIN = 'InterlockCommit-v1.1';

  // A field or pairing violates structural term validity.
  error InvalidTerms();
  // A local payout destination is the executing wrapper.
  error InvalidLocalPayoutRecipient();

  /// @notice Rejects this wrapper as a destination for any side on the committing chain.
  function validateLocalPayouts(ProtocolTerms memory terms, bool party, address wrapper) internal pure {
    // Choose the committing side's chain when checking local payout addresses.
    uint256 localChain = party ? terms.partySide.chainId : terms.counterpartySide.chainId;

    // Check Alice's destinations only if her side belongs to the committing chain.
    _validateLocalPayout(terms.partySide, localChain, wrapper);
    // Check Bob's destinations only if his side belongs to the committing chain.
    _validateLocalPayout(terms.counterpartySide, localChain, wrapper);
  }

  // Apply wrapper-recipient rejection only to a side on the committing chain.
  function _validateLocalPayout(SideTerms memory side, uint256 localChain, address wrapper) private pure {
    // Reject the wrapper address only when the side executes on the committing chain.
    if (side.chainId == localChain && (side.recipient == wrapper || side.reclaimRecipient == wrapper)) {
      // A local payout destination is the executing wrapper.
      revert InvalidLocalPayoutRecipient();
    }
  }

  /// @notice Derives the wrapper mode from the two side chain identifiers.
  function mode(ProtocolTerms memory terms) internal pure returns (WrapperMode) {
    // Equal chain identifiers select joint settlement; distinct identifiers select independent legs.
    return terms.partySide.chainId == terms.counterpartySide.chainId ? WrapperMode.SameChain : WrapperMode.CrossChain;
  }

  /// @notice Converts the ordered-side selector into its signed enum tag.
  function sideTag(bool partySide) internal pure returns (SideTag) {
    // Keep the boolean-to-enum mapping identical to off-chain signing encodings.
    return partySide ? SideTag.Party : SideTag.Counterparty;
  }

  /// @notice Hashes complete ordered terms under the supplied domain.
  function hashTerms(string memory domain, ProtocolTerms memory terms) internal pure returns (bytes32) {
    // Hash the domain and complete terms together using canonical ABI encoding.
    return keccak256(abi.encode(domain, terms));
  }

  /// @notice Computes the canonical identifier for one exact set of ordered terms.
  function tradeId(ProtocolTerms memory terms) internal pure returns (bytes32) {
    // Use the terms domain to separate trade identity from other protocol hashes.
    return hashTerms(TERMS_DOMAIN, terms);
  }

  /// @notice Returns the terms projection Bob hashes before choosing the commit secret.
  /// @dev Only the counterparty commit lock is cleared; all other fields remain bound.
  function gateTerms(ProtocolTerms memory terms) internal pure returns (ProtocolTerms memory projected) {
    // Deep-copy dynamic asset arrays before clearing the self-referential field.
    projected = abi.decode(abi.encode(terms), (ProtocolTerms));
    // Remove only Bob's self-referential gate lock from the projection.
    projected.counterpartySide.commitLock = bytes32(0);
  }

  /// @notice Computes the Bob-commit gate context without its self-referential commit lock.
  function gateContextId(ProtocolTerms memory terms) internal pure returns (bytes32 contextId) {
    // Save and clear Bob commit lock so the context does not hash itself.
    bytes32 originalCommitLock = terms.counterpartySide.commitLock;
    // Remove only Bob's self-referential gate lock from the projection.
    terms.counterpartySide.commitLock = bytes32(0);

    // Hash the projected terms under the dedicated gate-context domain.
    contextId = hashTerms(GATE_CONTEXT_DOMAIN, terms);

    // Restore the caller-owned memory value before returning.
    terms.counterpartySide.commitLock = originalCommitLock;
  }

  /// @notice Binds the Bob-commit preimage to one projected gate context.
  function commitLock(bytes32 contextId, bytes32 bobCommitSecret) internal pure returns (bytes32) {
    // Bind the progression preimage to this projected trade context and message domain.
    return keccak256(abi.encode(BOB_COMMIT_GATE_DOMAIN, contextId, bobCommitSecret));
  }

  /// @notice Binds the settlement preimage to one trade identifier.
  function settlementLock(bytes32 trade, bytes32 secret) internal pure returns (bytes32) {
    // Bind the settlement preimage to the complete trade and settlement domain.
    return keccak256(abi.encode(SETTLEMENT_LOCK_DOMAIN, trade, secret));
  }

  /// @notice Hashes the assets escrowed by one side on its named chain.
  function assetHash(SideTerms memory side) internal pure returns (bytes32) {
    // Bind the asset list to its chain as well as the asset-hash domain.
    return keccak256(abi.encode(ASSETS_DOMAIN, side.chainId, side.assets));
  }

  /// @notice Hashes one complete signed side for binding to its dedicated custody contract.
  function sideTermsHash(SideTerms memory side) internal pure returns (bytes32) {
    // Bind all side fields to the custody-specific side-terms domain.
    return keccak256(abi.encode(SIDE_TERMS_DOMAIN, side));
  }

  /// @notice Returns the state a commit authorization must expect at execution.
  function expectedSourceState(bool party, WrapperMode wrapperMode) internal pure returns (ExpectedSourceState) {
    // Only Bob's same-chain commit expects an already committed party record.
    return
      // Only Bob's same-chain commit expects an already committed party record.
      !party && wrapperMode == WrapperMode.SameChain ? ExpectedSourceState.PartyCommitted : ExpectedSourceState.Unused;
  }

  /// @notice Computes a commit payload hash from terms and the derived trade identifier.
  function commitPayloadHash(
    // Complete ordered terms whose hash binds the stored record.
    ProtocolTerms memory terms,
    // True selects Alice's party side; false selects Bob's counterparty side.
    bool party,
    // Authorization boundary bound into the replay and signature domain.
    address authorizationVerifier,
    // Exact wrapper permitted to consume the authorization.
    address swapAddress,
    // Trade-bound settlement hash lock.
    bytes32 lock,
    // Source-state tag bound into the signed commit payload.
    ExpectedSourceState sourceState,
    // Nonce consumed by the authorization boundary to prevent replay.
    bytes32 actionNonce,
    // Exclusive upper bound for authorization validity.
    uint256 expiry
    // Return a deterministic hash without reading or changing storage.
  ) internal pure returns (bytes32) {
    // Delegate encoding to the shared payload builder after deriving the complete trade identifier.
    return commitPayloadHashWithTradeId(
      // Pass every authorization field along with the freshly derived trade identifier.
      terms,
      party,
      authorizationVerifier,
      swapAddress,
      tradeId(terms),
      lock,
      sourceState,
      actionNonce,
      expiry
    );
  }

  /// @notice Computes the exact domain-separated payload authenticated by a commit signature.
  function commitPayloadHashWithTradeId(
    // Complete ordered terms whose hash binds the stored record.
    ProtocolTerms memory terms,
    // True selects Alice's party side; false selects Bob's counterparty side.
    bool party,
    // Authorization boundary bound into the replay and signature domain.
    address authorizationVerifier,
    // Exact wrapper permitted to consume the authorization.
    address swapAddress,
    // Identifier of the exact complete trade terms.
    bytes32 trade,
    // Trade-bound settlement hash lock.
    bytes32 lock,
    // Source-state tag bound into the signed commit payload.
    ExpectedSourceState sourceState,
    // Nonce consumed by the authorization boundary to prevent replay.
    bytes32 actionNonce,
    // Exclusive upper bound for authorization validity.
    uint256 expiry
    // Return a deterministic hash without reading or changing storage.
  ) internal pure returns (bytes32) {
    // Select the signed side and assemble every authorization field explicitly.
    SideTerms memory side = party ? terms.partySide : terms.counterpartySide;

    // Assemble the signed commit payload with no omitted identity or replay fields.
    CommitPayload memory payload = CommitPayload({
      // Chain on which the signed side executes.
      chainId: side.chainId,
      // Settlement mode derived from the two signed chain identifiers.
      mode: mode(terms),
      // Authorization boundary bound into the replay and signature domain.
      authorizationVerifier: authorizationVerifier,
      // Exact wrapper permitted to consume the authorization.
      swapAddress: swapAddress,
      // Hash of the complete ordered terms.
      tradeId: trade,
      // Trade-bound settlement hash lock.
      lock: lock,
      // Ordered side whose assets or state this operation addresses.
      side: sideTag(party),
      // Commit action tag prevents reuse for another operation.
      action: ActionTag.Commit,
      // Signed lifecycle state required before this commit.
      expectedSourceState: sourceState,
      // Chain-bound hash of this side's exact asset list.
      assetHash: assetHash(side),
      // Wallet or registered direct account controlling this side.
      principal: side.principal,
      // Signed principal key version; zero for wallet mode.
      principalKeyVersion: side.principalKeyVersion,
      // Signed restriction on who may transport the commit.
      delegationPolicy: side.delegationPolicy,
      // Named transport identity when specific delegation is enabled.
      delegate: side.delegate,
      // Signed registered version of the named delegate.
      delegateKeyVersion: side.delegateKeyVersion,
      // Nonce consumed by the authorization boundary to prevent replay.
      actionNonce: actionNonce,
      // Exclusive upper bound for admitting this side's commit.
      commitmentDeadline: side.commitmentDeadline,
      // Exclusive upper bound for authorization validity.
      expiry: expiry
    });
    // The fixed domain prevents this payload from being reused as another message type.
    return keccak256(abi.encode(COMMIT_DOMAIN, payload));
  }

  /// @notice Encodes the scope used to prevent commit-authorization nonce reuse.
  function encodeAuthorizationNonceKey(
    // Chain on which the signed side executes.
    uint256 chainId,
    // Authorization boundary bound into the replay and signature domain.
    address authorizationVerifier,
    // Wallet or registered direct account controlling this side.
    address principal,
    // Signed principal key version; zero for wallet mode.
    uint256 principalKeyVersion,
    // Nonce consumed by the authorization boundary to prevent replay.
    bytes32 actionNonce
    // Return canonical ABI bytes without reading or changing storage.
  ) internal pure returns (bytes memory) {
    // Scope replay protection to the chain, verifier, principal, key version, and action nonce.
    return abi.encode(chainId, authorizationVerifier, principal, principalKeyVersion, actionNonce);
  }

  /// @notice Encodes the scope used to prevent identity-operation nonce reuse.
  function encodeRegistryNonceKey(
    // Chain that scopes identity-operation replay protection.
    uint256 chainId,
    // Registry instance that scopes the identity-operation nonce.
    address registryAddress,
    // Direct-user account whose registry nonce is being scoped.
    address eoa,
    // Active or recovery key role that authorizes this identity operation.
    uint8 authorizingKeyRole,
    // Version of the key authorizing this identity operation.
    uint256 authorizingKeyVersion,
    // Registry replay nonce scoped to the authorizing identity and key.
    bytes32 operationNonce
    // Return canonical ABI bytes without reading or changing storage.
  ) internal pure returns (bytes memory) {
    // Scope registry replay protection to the chain, registry, identity, key role, version, and nonce.
    return abi.encode(chainId, registryAddress, eoa, authorizingKeyRole, authorizingKeyVersion, operationNonce);
  }

  /// @notice Reverts unless both sides and their pairing satisfy structural term validity.
  /// @dev Asset arrays must be strictly sorted by identity, which also excludes duplicates.
  ///      Client timing-policy margins and supported remote routes are not enforced here.
  ///      Mutable asset admission, local-chain checks, and wrapper payout guards run at commit.
  function validateTerms(ProtocolTerms memory terms) internal pure {
    // Chain equality selects the validation rules before any state is consulted.
    WrapperMode wrapperMode = mode(terms);
    // Reject missing chain or principal identities before inspecting side details.
    if (
      // Require nonzero chain identifiers and a nonzero party principal.
      terms.partySide.chainId == 0 || terms.counterpartySide.chainId == 0 || terms.partySide.principal == address(0)
        // Require a nonzero counterparty principal as well.
        || terms.counterpartySide.principal == address(0)
      // A field or pairing violates structural term validity.
    ) revert InvalidTerms();

    // Validate each side independently before checking their cross-side schedule.
    _validateSide(terms.partySide);
    // Validate Bob's side independently of Alice's fields.
    _validateSide(terms.counterpartySide);

    // Order commit deadlines before the party claim deadline; this adds no claim-opening time gate.
    if (!(terms.partySide.commitmentDeadline < terms.counterpartySide.commitmentDeadline
          // A field or pairing violates structural term validity.
          && terms.counterpartySide.commitmentDeadline < terms.partySide.claimDeadline)) revert InvalidTerms();

    // The progression gate belongs only to the counterparty side.
    if (terms.partySide.commitLock != bytes32(0)) revert InvalidTerms();

    // Apply joint-state progression and shared settlement rules when the chains match.
    if (wrapperMode == WrapperMode.SameChain) {
      // Same-chain progression uses local state; outcome selection and resumable payouts need no gate secret.
      if (terms.counterpartySide.commitLock != bytes32(0)) revert InvalidTerms();

      // Both escrows must remain claimable until the earlier claim deadline.
      uint256 claimDeadline = terms.partySide.claimDeadline < terms.counterpartySide.claimDeadline
        // Use Alice's deadline when it is the earlier claim cutoff.
        ? terms.partySide.claimDeadline
        // Otherwise use Bob's deadline as the joint claim cutoff.
        : terms.counterpartySide.claimDeadline;
      // Require the shared claim cutoff to precede either reclaim release.
      if (claimDeadline >= terms.partySide.reclaimRelease || claimDeadline >= terms.counterpartySide.reclaimRelease) {
        // A field or pairing violates structural term validity.
        revert InvalidTerms();
      }
      // Apply the progression-lock and cross-side reclaim-horizon rules for distinct chains.
    } else {
      // Cross-chain execution requires Bob trade-bound progression lock.
      if (terms.counterpartySide.commitLock == bytes32(0)) revert InvalidTerms();
      // Require each claim horizon to stay within the opposite reclaim horizon.
      if (
        // Reject a party claim horizon extending past Bob's reclaim release.
        terms.partySide.claimDeadline > terms.counterpartySide.reclaimRelease
          // Likewise reject a Bob claim horizon extending past Alice's reclaim release.
          || terms.counterpartySide.claimDeadline > terms.partySide.reclaimRelease
        // A field or pairing violates structural term validity.
      ) revert InvalidTerms();
    }
  }

  // Check a single side's destinations, nonce, timing, key fields, and canonical assets.
  function _validateSide(SideTerms memory side) private pure {
    // Require nonzero destinations and side nonce, at least one asset, and strict local timing.
    if (
      // Require both payout destinations and at least one asset on this side.
      side.recipient == address(0) || side.reclaimRecipient == address(0) || side.assets.length == 0
        // Reject an obvious side-nonce generation failure; nonzero does not establish entropy.
        || side.sideNonce == bytes32(0)
        // Require strict commit, claim, and reclaim ordering within this side.
        || !(side.commitmentDeadline < side.claimDeadline && side.claimDeadline < side.reclaimRelease)
      // A field or pairing violates structural term validity.
    ) revert InvalidTerms();
    // Wallet keys are internal and version zero; direct keys are registry-versioned.
    if (side.authorizationMode == AuthorizationMode.QuipWallet) {
      // A field or pairing violates structural term validity.
      if (side.principalKeyVersion != 0) revert InvalidTerms();
      // Direct-user authorization must name a nonzero registered principal key version.
    } else if (side.principalKeyVersion == 0) {
      // A field or pairing violates structural term validity.
      revert InvalidTerms();
    }

    // Canonicalize delegate fields so inactive policies cannot carry ignored values.
    if (side.delegationPolicy == DelegationPolicy.SpecificDelegate) {
      // A field or pairing violates structural term validity.
      if (side.delegate == address(0) || side.delegateKeyVersion == 0) revert InvalidTerms();
      // Inactive delegation fields must be zero to avoid ambiguous signed encodings.
    } else if (side.delegate != address(0) || side.delegateKeyVersion != 0) {
      // A field or pairing violates structural term validity.
      revert InvalidTerms();
    }

    // Strict identity order rejects duplicates and creates one canonical encoding.
    for (uint256 i; i < side.assets.length; ++i) {
      // Inspect the next asset in the canonical list.
      Asset memory asset = side.assets[i];
      // A field or pairing violates structural term validity.
      if (!_validAsset(asset)) revert InvalidTerms();
      // A field or pairing violates structural term validity.
      if (i != 0 && !_assetIdentityLess(side.assets[i - 1], asset)) revert InvalidTerms();
    }
  }

  // Check the identity and quantity rules for the declared asset standard.
  function _validAsset(Asset memory asset) private pure returns (bool) {
    // Reject zero quantities for every supported asset standard.
    if (asset.amount == 0) return false;

    // Native assets use no token address or token identifier.
    if (asset.assetType == AssetType.Native) return asset.target == address(0) && asset.id == 0;
    // ERC-20 entries require a token address and have no token identifier.
    if (asset.assetType == AssetType.ERC20) return asset.target != address(0) && asset.id == 0;
    // ERC-721 entries represent exactly one token at a nonzero contract address.
    if (asset.assetType == AssetType.ERC721) return asset.target != address(0) && asset.amount == 1;
    // ERC-1155 entries require a contract; their identifier and positive amount were already admitted.
    if (asset.assetType == AssetType.ERC1155) return asset.target != address(0);

    // Reject any unsupported asset kind.
    return false;
  }

  // Compare asset identities lexicographically to enforce strict canonical ordering.
  function _assetIdentityLess(Asset memory a, Asset memory b) private pure returns (bool) {
    // Sort first by transfer standard.
    if (uint8(a.assetType) != uint8(b.assetType)) return uint8(a.assetType) < uint8(b.assetType);

    // Within a standard, sort by numeric token-contract address.
    if (a.target != b.target) return uint160(a.target) < uint160(b.target);

    // Within a token contract, sort by token identifier; equality rejects duplicates.
    return a.id < b.id;
  }
}
