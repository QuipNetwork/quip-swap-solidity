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
  /// @notice the contract address of the asset, zero for native
  address target;
  /// @notice the token id, only used for erc721 and erc1155
  uint256 id;
  /// @notice the amount, only used for native, erc20, and erc1155
  uint256 amount;
}

/// @notice the terms for a single party in an Omnibus swap
struct Terms {
  /// @notice the chain where these terms are valid
  uint256 chainId;
  /// @notice the address of the party (commits assets)
  address signatory;
  /// @notice the address that receives the counterparty's assets
  address recipient;
  /// @notice the deadline timestamp
  uint64 deadline;
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

  /// @notice thrown when a native asset has invalid fields
  error InvalidNativeAsset();

  /// @notice thrown when an erc20 asset has invalid fields
  error InvalidERC20Asset();

  /// @notice thrown when an erc721 asset has invalid fields
  error InvalidERC721Asset();

  /// @notice thrown when an erc1155 asset has invalid fields
  error InvalidERC1155Asset();

  /// @notice thrown when the terms have expired
  error TermsExpired();

  /// @notice thrown when the terms have not yet expired
  error TermsNotExpired();

  // ============ Hashing ============

  /// @notice computes a canonical digest of terms regardless of party/counterparty order
  /// @dev same hash regardless of which party is passed first
  /// @param party the first party's terms
  /// @param counterparty the second party's terms
  /// @return canonicalDigest the canonical hash (smaller digest first)
  function digestTermsCanonically(
    Terms calldata party,
    Terms calldata counterparty
  ) internal pure returns (bytes32 canonicalDigest) {
    bytes32 partyDigest = EfficientHashLib.hash(
      abi.encode(party.chainId, party.signatory, party.recipient, party.deadline, party.assets)
    );
    bytes32 counterpartyDigest = EfficientHashLib.hash(
      abi.encode(counterparty.chainId, counterparty.signatory, counterparty.recipient, counterparty.deadline, counterparty.assets)
    );
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

    if (isERC721 && (isZeroTarget || isZeroId)) {
      revert InvalidERC721Asset();
    }

    if (isERC1155 && (isZeroTarget || isZeroId)) {
      revert InvalidERC1155Asset();
    }
  }

  /// @notice validates terms for commit
  /// @dev if isParty is true, chainId must match current chain
  /// @param terms the terms to validate
  /// @param isParty whether these are the committing party's terms (enforces current chain)
  function validateTerms(Terms calldata terms, bool isParty) internal view {
    if (isParty) {
      enforceChainId(terms, block.chainid);
    }
    enforceNonZeroChainId(terms);
    enforceTermFreshness(terms);
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

  /// @notice reverts if the terms deadline has passed
  /// @param terms the terms to check
  function enforceTermFreshness(Terms calldata terms) internal view {
    if (block.timestamp >= terms.deadline) {
      revert TermsExpired();
    }
  }

  /// @notice reverts if the terms deadline has not passed
  /// @param terms the terms to check
  function enforceTermStaleness(Terms calldata terms) internal view {
    if (block.timestamp < terms.deadline) {
      revert TermsNotExpired();
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

  /// @notice transfers assets from terms excluding native assets
  /// @param terms the terms containing assets to transfer
  /// @param from the address to transfer from
  /// @param to the address to transfer to
  function transferAssetsNoNative(Terms calldata terms, address from, address to) internal {
    uint256 length = terms.assets.length;
    for (uint256 i; i < length; ++i) {
      if (terms.assets[i].assetType != AssetType.Native) {
        transferAsset(terms.assets[i], from, to);
      }
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

  /// @notice validates assets in terms
  /// @param terms the terms to validate
  function validateAssets(Terms calldata terms) internal pure {
    uint256 length = terms.assets.length;
    for (uint256 i; i < length; ++i) {
      validateAsset(terms.assets[i]);
    }
  }
}
