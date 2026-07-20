// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {IERC1155} from '@openzeppelin-contracts-5.6.0-rc.1/token/ERC1155/IERC1155.sol';
import {IERC721} from '@openzeppelin-contracts-5.6.0-rc.1/token/ERC721/IERC721.sol';
import {EfficientHashLib} from 'solady-0.1.26/utils/EfficientHashLib.sol';
import {SafeTransferLib} from 'solady-0.1.26/utils/SafeTransferLib.sol';

/// @notice the type of asset
enum AssetType {
  Native,
  ERC20,
  ERC721,
  ERC1155
}

/// @notice an asset to be transferred as part of a swap
struct Asset {
  /// @notice the type of asset
  AssetType assetType;
  /// @notice the token identifier on the leg's own chain: zero for native; an
  /// EVM token address in the LOW 20 bytes for EVM legs; a full 32-byte
  /// identifier (e.g. an SPL mint pubkey) for non-EVM legs
  bytes32 target;
  /// @notice the token id, only used for erc721 and erc1155
  uint256 id;
  /// @notice the amount, only used for native, erc20, and erc1155
  uint256 amount;
}

/// @notice the terms for a single party in an Omnibus swap
struct Terms {
  /// @notice the chain where the assets of these terms are held
  uint256 chainId;
  /// @notice account receiving this leg's own assets back upon reclaim; lives
  /// on THIS leg's chain (an EVM address in the low 20 bytes when the leg is
  /// local)
  bytes32 reclaimRecipient;
  /// @notice account receiving the counterparty's assets upon claim; lives on
  /// the COUNTERPARTY's chain — may be a foreign 32-byte pubkey when the
  /// counterparty leg is non-EVM
  bytes32 recipient;
  /// @notice timestamp after which commitment is forbidden
  uint256 commitmentDeadline;
  /// @notice timestamp after which claiming is forbidden
  uint256 claimDeadline;
  /// @notice timestamp after which reclaim is permitted
  uint256 reclaimRelease;
  /// @notice when BOTH sides set true, the LOWER bounds of the commit and claim
  /// windows are waived (no forced sequencing waits); upper bounds and
  /// reclaimRelease are always enforced
  bool optimistic;
  /// @notice the assets offered by the party
  Asset[] assets;
}

library TermsLib {
  // ============ Errors ============

  /// @notice thrown when an asset has zero amount
  error ZeroAmount();

  /// @notice thrown when chainId is zero
  error ZeroChainId();

  /// @notice thrown when chainId does not match expected chain
  error ChainIdMismatch();

  /// @notice thrown when deadlines are not strictly increasing
  error DisordedDeadlines();

  /// @notice thrown when the two sides' optimistic flags differ
  error OptimismMismatch();

  /// @notice thrown when a native asset has invalid fields
  error InvalidNativeAsset();

  /// @notice thrown when an erc20 asset has invalid fields
  error InvalidERC20Asset();

  /// @notice thrown when an erc721 asset has invalid fields
  error InvalidERC721Asset();

  /// @notice thrown when an erc1155 asset has invalid fields
  error InvalidERC1155Asset();

  /// @notice thrown when terms have no assets
  error EmptyAssets();

  /// @notice thrown when a lifecycle deadline is zero
  error ZeroDeadline();

  /// @notice thrown when a pulled fungible asset delivers less than its declared amount
  error UnexpectedAmountReceived();

  /// @notice thrown when the current timestamp falls outside an action's window
  /// (before its lower bound or at/after its upper bound)
  error WindowViolated();

  /// @notice thrown when either recipient or reclaimRecipient is zero
  error ZeroRecipient();

  /// @notice thrown when a window's bounds are degenerate (lower >= upper)
  error InvalidRange();

  /// @notice thrown when narrowing a bytes32 identifier that does not fit an
  /// EVM address (any of the upper 12 bytes set)
  error NotEvmAddress(bytes32 value);

  // ============ Addressing ============

  /// @notice narrows a 32-byte account/token identifier to an EVM address
  /// @dev identifiers use LayerZero-style alignment: an EVM address occupies the
  /// LOW 20 bytes — bytes32(uint256(uint160(addr))), matching abi.encode(address)
  /// so EVM-only terms digests are unchanged by the bytes32 widening. NEVER
  /// left-align (bytes32(bytes20(addr))); that changes every digest. Values with
  /// upper bits set are foreign-chain identifiers and revert here
  /// @param value the 32-byte identifier
  /// @return the narrowed EVM address
  function toEvmAddress(bytes32 value) internal pure returns (address) {
    if (uint256(value) >> 160 != 0) revert NotEvmAddress(value);
    return address(uint160(uint256(value)));
  }

  // ============ Hashing ============

  /// @notice computes the digest of a single side's terms
  /// @param terms the side's terms
  /// @return digest the sub-digest used for ordering and posted tracking
  function digestTerms(Terms calldata terms) internal pure returns (bytes32 digest) {
    digest = EfficientHashLib.hash(
      abi.encode(
        terms.chainId,
        terms.reclaimRecipient,
        terms.recipient,
        terms.commitmentDeadline,
        terms.claimDeadline,
        terms.reclaimRelease,
        terms.optimistic,
        terms.assets
      )
    );
  }

  /// @notice computes a canonical digest of terms regardless of party/counterparty order
  /// @dev same hash regardless of which party is passed first
  /// @param party the first party's terms
  /// @param counterparty the second party's terms
  /// @return canonicalDigest the canonical hash (smaller digest first)
  function digestTermsCanonically(
    Terms calldata party,
    Terms calldata counterparty
  ) internal pure returns (bytes32 canonicalDigest) {
    bytes32 partyDigest = digestTerms(party);
    bytes32 counterpartyDigest = digestTerms(counterparty);
    // canonical ordering: smaller digest first
    if (uint256(partyDigest) < uint256(counterpartyDigest)) {
      canonicalDigest = EfficientHashLib.hash(partyDigest, counterpartyDigest);
    } else {
      canonicalDigest = EfficientHashLib.hash(counterpartyDigest, partyDigest);
    }
  }

  // ============ Validation / Enforcement ============

  /// @notice validates that an asset's fields are consistent with its type
  /// @param asset the asset to validate
  function validateAsset(Asset memory asset) internal pure {
    if (asset.amount == 0) {
      revert ZeroAmount();
    }

    bool isNative = asset.assetType == AssetType.Native;
    bool isERC20 = asset.assetType == AssetType.ERC20;
    bool isERC721 = asset.assetType == AssetType.ERC721;
    bool isERC1155 = asset.assetType == AssetType.ERC1155;
    bool isZeroId = asset.id == 0;
    bool isZeroTarget = asset.target == bytes32(0);

    if (isNative && (!isZeroTarget || !isZeroId)) {
      revert InvalidNativeAsset();
    }

    if (isERC20 && (isZeroTarget || !isZeroId)) {
      revert InvalidERC20Asset();
    }

    // ERC721/ERC1155 token id 0 is valid; only a zero target is rejected
    if (isERC721 && isZeroTarget) {
      revert InvalidERC721Asset();
    }

    if (isERC1155 && isZeroTarget) {
      revert InvalidERC1155Asset();
    }
  }

  /// @notice validates terms for commit
  /// @param terms the terms to validate
  function validateTerms(Terms calldata terms) internal pure {
    if (terms.assets.length == 0) revert EmptyAssets();
    if (terms.reclaimRecipient == bytes32(0) || terms.recipient == bytes32(0)) {
      revert ZeroRecipient();
    }
    // deadlines are only sanity-checked as non-zero here; actual freshness (a deadline still
    // lying in the future) is enforced per-action by the commit/claim/reclaim windows via
    // TermsLib.enforceWithin. validateTerms must NOT reject elapsed deadlines, because commit
    // validates both sides and the taker commits only AFTER the proposer's commitment deadline
    // has passed — a freshness check here would wrongly reject the proposer's (counterparty's)
    // already-elapsed deadline. strict ordering below then makes claim and reclaim non-zero too
    if (terms.commitmentDeadline == 0) revert ZeroDeadline();
    // lifecycle deadlines must be strictly increasing: commitment < claim < reclaim
    if (!(terms.commitmentDeadline < terms.claimDeadline && terms.claimDeadline < terms.reclaimRelease)) {
      revert DisordedDeadlines();
    }
    enforceNonZeroChainId(terms);
    validateAssets(terms);
  }

  /// @notice validates that a leg's locally-dereferenced identifiers are EVM addresses
  /// @dev call on the leg being escrowed on THIS chain: its asset targets are pulled
  /// into escrow now and its reclaimRecipient is paid here on reclaim. the leg's
  /// `recipient` is NOT checked — it receives on the COUNTERPARTY's chain and may be
  /// a foreign pubkey. validateTerms stays chain-agnostic (it runs on both sides)
  /// @param terms the local leg's terms
  function validateLocalLeg(Terms calldata terms) internal pure {
    toEvmAddress(terms.reclaimRecipient);
    uint256 length = terms.assets.length;
    for (uint256 i; i < length; ++i) {
      toEvmAddress(terms.assets[i].target);
    }
  }

  /// @notice reverts if the terms chainId is zero
  /// @param terms the terms to check
  function enforceNonZeroChainId(Terms calldata terms) internal pure {
    if (terms.chainId == 0) revert ZeroChainId();
  }

  /// @notice reverts if the terms chainId does not match the expected chainId
  /// @param terms the terms to check
  /// @param chainId the expected chainId
  function enforceChainId(Terms calldata terms, uint256 chainId) internal pure {
    if (terms.chainId != chainId) revert ChainIdMismatch();
  }

  /// @notice enforces that `timestamp` falls within the half-open window [lower, upper)
  /// @dev lower bound is inclusive, upper bound is EXCLUSIVE. The exclusive upper is
  ///      deliberate: adjacent windows share a boundary (one window's upper is the
  ///      next window's lower), and exclusivity ensures exactly one window accepts the
  ///      shared instant — preserving the "one action per window" invariant. Do not
  ///      relax `upper <= timestamp` to `<`.
  /// @param lower the window's lower bound (inclusive)
  /// @param upper the window's upper bound (exclusive)
  /// @param timestamp the time to check (caller passes block.timestamp)
  function enforceWithin(uint256 lower, uint256 upper, uint256 timestamp) internal pure {
    if (lower >= upper) {
      revert InvalidRange();
    }
    if (lower > timestamp || upper <= timestamp) {
      revert WindowViolated();
    }
  }

  // ============ Transfer ============

  /// @notice transfers a single asset from one address to another
  /// @param asset the asset to transfer
  /// @param from the address to transfer from (ignored for native)
  /// @param to the address to transfer to
  function transferAsset(Asset memory asset, address from, address to) internal {
    if (asset.assetType == AssetType.Native) {
      return SafeTransferLib.safeTransferETH(to, asset.amount);
    }

    // single choke point narrowing token identifiers for local dereference;
    // commit-time validateLocalLeg guarantees escrowed targets narrow cleanly
    address target = toEvmAddress(asset.target);

    if (asset.assetType == AssetType.ERC20) {
      return from == address(this)
        ? SafeTransferLib.safeTransfer(target, to, asset.amount)
        : SafeTransferLib.safeTransferFrom(target, from, to, asset.amount);
    }

    if (asset.assetType == AssetType.ERC721) {
      return IERC721(target).safeTransferFrom(from, to, asset.id);
    }

    IERC1155(target).safeTransferFrom(from, to, asset.id, asset.amount, '');
  }

  /// @notice transfers all assets from terms
  /// @param terms the terms containing assets to transfer
  /// @param from the address to transfer from (ignored for native assets)
  /// @param to the address to transfer to
  function transferAssets(Terms calldata terms, address from, address to) internal {
    uint256 length = terms.assets.length;
    for (uint256 i; i < length; ++i) {
      transferAsset(terms.assets[i], from, to);
    }
  }

  /// @notice transfers assets from terms excluding native assets, reverting if a
  /// fungible asset delivers less than its declared amount
  /// @dev reconciles the recipient balance for ERC20/ERC1155 so fee-on-transfer or
  /// deflationary tokens cannot under-fund the escrow; the declared amount is part of
  /// the cross-chain terms digest, so anything other than exact receipt must revert
  /// @param terms the terms containing assets to transfer
  /// @param from the address to transfer from
  /// @param to the address to transfer to
  function transferAssetsNoNative(Terms calldata terms, address from, address to) internal {
    uint256 length = terms.assets.length;
    for (uint256 i; i < length; ++i) {
      Asset memory asset = terms.assets[i];
      if (asset.assetType == AssetType.Native) {
        continue;
      }
      if (asset.assetType == AssetType.ERC721) {
        // a single specific token; no fungible amount to reconcile
        transferAsset(asset, from, to);
        continue;
      }
      // ERC20 / ERC1155: require exactly `amount` to be received
      uint256 balanceBefore = heldBalance(asset, to);
      transferAsset(asset, from, to);
      if (heldBalance(asset, to) - balanceBefore != asset.amount) revert UnexpectedAmountReceived();
    }
  }

  /// @notice calculates total native amount from terms
  /// @param terms the party's terms
  /// @return total the total native amount required
  function totalNative(Terms calldata terms) internal pure returns (uint256 total) {
    uint256 length = terms.assets.length;
    for (uint256 i; i < length; ++i) {
      if (terms.assets[i].assetType == AssetType.Native) total += terms.assets[i].amount;
    }
  }

  // ============ Private ============

  /// @notice reads the held balance of a fungible asset for an account
  /// @param asset the asset (ERC20 or ERC1155)
  /// @param account the account whose balance to read
  /// @return balance the account's balance of the asset
  function heldBalance(Asset memory asset, address account) internal view returns (uint256 balance) {
    address target = toEvmAddress(asset.target);
    balance = asset.assetType == AssetType.ERC1155
      ? IERC1155(target).balanceOf(account, asset.id)
      : SafeTransferLib.balanceOf(target, account);
  }

  /// @notice validates assets in terms
  /// @param terms the terms to validate
  function validateAssets(Terms calldata terms) internal pure {
    uint256 length = terms.assets.length;
    for (uint256 i; i < length; ++i) {
      validateAsset(terms.assets[i]);
    }
  }

  /// @notice enforces that two sides' lifecycle deadlines strictly interleave
  /// and that their optimistic flags match
  /// @dev whichever side proposes terms must precede the other at every stage;
  ///      requires either (A proposes)
  ///      A.commitmentDeadline < B.commitmentDeadline < A.claimDeadline <
  ///      B.claimDeadline < A.reclaimRelease < B.reclaimRelease,
  ///      or the same chain with A and B swapped (B proposes). reverts otherwise.
  ///      optimistic mode is a bilateral opt-in: both flags must be equal
  /// @param A one side's terms
  /// @param B the other side's terms
  function validateTermPairing(Terms calldata A, Terms calldata B) internal pure {
    bool aProposes = A.commitmentDeadline < B.commitmentDeadline && B.commitmentDeadline < A.claimDeadline
      && A.claimDeadline < B.claimDeadline && B.claimDeadline < A.reclaimRelease && A.reclaimRelease < B.reclaimRelease;

    bool bProposes = B.commitmentDeadline < A.commitmentDeadline && A.commitmentDeadline < B.claimDeadline
      && B.claimDeadline < A.claimDeadline && A.claimDeadline < B.reclaimRelease && B.reclaimRelease < A.reclaimRelease;

    if (!(aProposes || bProposes)) {
      revert DisordedDeadlines();
    }

    if (A.optimistic != B.optimistic) {
      revert OptimismMismatch();
    }
  }

  /// @notice identifies which side proposed in a validated pairing
  /// @dev the proposer is the side that commits first; only meaningful after
  ///      validateTermPairing has passed, which guarantees the commitment
  ///      deadlines are strictly ordered and never equal
  /// @param party the first side's terms
  /// @param counterparty the second side's terms
  /// @return partyProposed true if `party` proposed, false if `counterparty` did
  function proposedByParty(
    Terms calldata party,
    Terms calldata counterparty
  ) internal pure returns (bool partyProposed) {
    partyProposed = party.commitmentDeadline < counterparty.commitmentDeadline;
  }
}

