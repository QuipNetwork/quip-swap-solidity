// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {IERC1155} from '@openzeppelin-contracts-5.6.0-rc.1/token/ERC1155/IERC1155.sol';
import {SafeTransferLib} from 'solady-0.1.26/utils/SafeTransferLib.sol';

import {IERC721} from '@openzeppelin-contracts-5.6.0-rc.1/token/ERC721/IERC721.sol';
/// @notice the type of asset
enum AssetType {
  Native,
  ERC20,
  ERC721,
  ERC1155
}

/// @notice an asset to be transferred as part of a quip
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

library AssetLib {
  /// @notice thrown when an asset has zero amount
  error ZeroAmount();

  /// @notice thrown when a native asset has invalid fields
  error InvalidNativeAsset();

  /// @notice thrown when an erc20 asset has invalid fields
  error InvalidERC20Asset();

  /// @notice thrown when an erc721 asset has invalid fields
  error InvalidERC721Asset();

  /// @notice thrown when an erc1155 asset has invalid fields
  error InvalidERC1155Asset();

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

  /// @notice transfers an array of assets from one address to another
  /// @param assets the assets to transfer
  /// @param from the address to transfer from (ignored for native assets)
  /// @param to the address to transfer to
  function transferAssets(Asset[] memory assets, address from, address to) internal {
    for (uint256 i; i < assets.length; ++i) {
      transferAsset(assets[i], from, to);
    }
  }

  function totalNativeAmount(Asset[] memory assets) internal returns (uint256 total) {
    for (uint256 i; i < assets.length; ++i) {
      if (assets[i].assetType == AssetType.Native) total += assets[i].amount;
    }
  }
}
