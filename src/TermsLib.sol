// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.33;

import {IERC1155} from '@openzeppelin-contracts-5.7.0/token/ERC1155/IERC1155.sol';
import {IERC721} from '@openzeppelin-contracts-5.7.0/token/ERC721/IERC721.sol';
import {ERC165Checker} from '@openzeppelin-contracts-5.7.0/utils/introspection/ERC165Checker.sol';
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
  /// @notice the contract address of the asset, zero for native
  address target;
  /// @notice the token id, only used for erc721 and erc1155
  uint256 id;
  /// @notice the amount, only used for native, erc20, and erc1155
  uint256 amount;
}

/// @notice the terms for a single party in an Omnibus swap
struct Terms {
  /// @notice the chain where the assets of these terms are held
  uint256 chainId;
  /// @notice address which will receive committed assets upon reclaim
  address reclaimRecipient;
  /// @notice the address that receives the counterparty's assets
  address recipient;
  /// @notice timestamp after which commitment is forbidden
  uint256 commitmentDeadline;
  /// @notice timestamp after which claiming is forbidden
  uint256 claimDeadline;
  /// @notice timestamp after which reclaim is permitted
  uint256 reclaimRelease;
  /// @notice the assets offered by the party
  Asset[] assets;
}

library TermsLib {
  // ============ Constants ============

  /// @notice the maximum number of assets permitted in a single side's terms
  /// @dev bounds the per-side `assets` array so the combined cost of settling BOTH
  /// sides together (same-chain `claim`, which moves both legs in one call) always
  /// fits well within the block gas limit of every chain Omnibus is deployed to.
  /// Without this cap a leg could be padded (e.g. thousands of one-wei native
  /// entries) to commit within one block yet make every subsequent claim/reclaim
  /// exceed the block gas limit forever — a permanent freeze, and cross-chain a
  /// theft (the padded leg's chain can never settle while the healthy leg pays out).
  /// A low-tens bound is ample for any realistic basket swap.
  uint256 internal constant MAX_ASSETS_PER_SIDE = 20;

  // ============ Errors ============

  /// @notice thrown when an asset has zero amount
  error ZeroAmount();

  /// @notice thrown when chainId is zero
  error ZeroChainId();

  /// @notice thrown when chainId does not match expected chain
  error ChainIdMismatch();

  /// @notice thrown when deadlines are not strictly increasing
  error DisordedDeadlines();

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

  /// @notice thrown when a side's terms carry more than MAX_ASSETS_PER_SIDE assets
  error TooManyAssets();

  /// @notice thrown when a lifecycle deadline is zero
  error ZeroDeadline();

  /// @notice thrown when reclaimRelease is type(uint256).max, which would make the reclaim
  /// window [reclaimRelease, type(uint256).max) degenerate and revert on every reclaim
  error InvalidReclaimRelease();

  /// @notice thrown when a pulled fungible asset delivers less than its declared amount
  error UnexpectedAmountReceived();

  /// @notice thrown at deposit when an ERC20-declared target also answers as an ERC721
  /// (ERC165). ERC20 transferFrom/balanceOf share selectors with ERC721, so a stock NFT
  /// passes the deposit reconciliation but every payout via transfer() reverts forever.
  error AssetTypeMismatch();

  /// @notice thrown when the current timestamp falls outside an action's window
  /// (before its lower bound or at/after its upper bound)
  error WindowViolated();

  /// @notice thrown when either recipient or reclaimRecipient is the zero address
  error ZeroAddressRecipient();

  /// @notice thrown when a window's bounds are degenerate (lower >= upper)
  error InvalidRange();

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
    bool isZeroTarget = asset.target == address(0);

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
    // cap the per-side asset count so settling both legs together always fits the
    // block gas limit (see MAX_ASSETS_PER_SIDE) — blocks the gas-griefing padded leg
    if (terms.assets.length > MAX_ASSETS_PER_SIDE) revert TooManyAssets();
    if (terms.reclaimRecipient == address(0) || terms.recipient == address(0)) {
      revert ZeroAddressRecipient();
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
    // reclaim's window is [reclaimRelease, type(uint256).max); a reclaimRelease of max makes it
    // degenerate otherwise
    if (terms.reclaimRelease == type(uint256).max) revert InvalidReclaimRelease();
    enforceNonZeroChainId(terms);
    validateAssets(terms);
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

    if (asset.assetType == AssetType.ERC20) {
      return from == address(this)
        ? SafeTransferLib.safeTransfer(asset.target, to, asset.amount)
        : SafeTransferLib.safeTransferFrom(asset.target, from, to, asset.amount);
    }

    if (asset.assetType == AssetType.ERC721) {
      return IERC721(asset.target).safeTransferFrom(from, to, asset.id);
    }

    IERC1155(asset.target).safeTransferFrom(from, to, asset.id, asset.amount, '');
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
      // an ERC20-declared target that also answers as an ERC721 is a selector-collision
      // trap: transferFrom/balanceOf collide, so the deposit reconciles as a 1-unit ERC20,
      // but every payout settles via transfer(address,uint256) — which no ERC721 implements —
      // and reverts forever (same-chain freeze, cross-chain theft). reject it at deposit,
      // on the chain where the token actually lives. A custom contract that lies on ERC165
      // still slips through: that is the "malicious token is UNSUPPORTED — vet the counter-leg"
      // case documented on commit, not something an on-chain probe can settle.
      if (
        asset.assetType == AssetType.ERC20 && ERC165Checker.supportsInterface(asset.target, type(IERC721).interfaceId)
      ) {
        revert AssetTypeMismatch();
      }
      // ERC20 / ERC1155: require exactly `amount` to be received
      uint256 balanceBefore = heldBalance(asset, to);
      transferAsset(asset, from, to);
      if (heldBalance(asset, to) - balanceBefore != asset.amount) revert UnexpectedAmountReceived();
    }
  }

  /// @notice transfers all assets from this contract to `to`, clamping fungible
  /// amounts to the balance actually held
  /// @dev escape hatch for balance-mutable tokens (rebasing/slashable): if the pooled
  /// escrow was externally reduced below the declared amount, transferring the declared
  /// amount would revert forever and permanently freeze every asset in the terms. Used
  /// by reclaim only; claim must stay exact-or-revert so a shortfall can never buy the
  /// secret at a discount. Native and ERC721 are never clamped: a specific NFT is either
  /// held or the transfer should revert, and the native pool cannot shrink in place.
  /// Loss allocation across swaps pooled in the same token is first-come-first-served:
  /// earlier reclaims are paid in full and the last is paid the remainder.
  /// @param terms the terms containing assets to transfer
  /// @param to the address to transfer to
  function transferAssetsClamped(Terms calldata terms, address to) internal {
    uint256 length = terms.assets.length;
    for (uint256 i; i < length; ++i) {
      Asset memory asset = terms.assets[i];
      if (asset.assetType == AssetType.ERC20 || asset.assetType == AssetType.ERC1155) {
        uint256 held = heldBalance(asset, address(this));
        if (held < asset.amount) asset.amount = held;
      }
      transferAsset(asset, address(this), to);
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
    balance = asset.assetType == AssetType.ERC1155
      ? IERC1155(asset.target).balanceOf(account, asset.id)
      : SafeTransferLib.balanceOf(asset.target, account);
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
  /// @dev whichever side proposes terms must precede the other at every stage;
  ///      requires either (A proposes)
  ///      A.commitmentDeadline < B.commitmentDeadline < A.claimDeadline <
  ///      B.claimDeadline < A.reclaimRelease < B.reclaimRelease,
  ///      or the same chain with A and B swapped (B proposes). reverts otherwise
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

