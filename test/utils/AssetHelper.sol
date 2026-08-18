// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Asset, AssetType} from '../../src/protocol/ProtocolTypes.sol';

/// @title Asset Helper
/// @dev Utility functions for building Asset structs in tests
library AssetHelper {
  /// @notice Creates a native asset
  /// @param amount The amount of native currency
  /// @return asset The constructed Asset struct
  function makeNative(uint256 amount) internal pure returns (Asset memory asset) {
    asset = Asset({assetType: AssetType.Native, target: address(0), id: 0, amount: amount});
  }

  /// @notice Creates an ERC20 asset
  /// @param token The token address
  /// @param amount The token amount
  /// @return asset The constructed Asset struct
  function makeERC20(address token, uint256 amount) internal pure returns (Asset memory asset) {
    asset = Asset({assetType: AssetType.ERC20, target: token, id: 0, amount: amount});
  }

  /// @notice Creates an ERC721 asset
  /// @param token The token address
  /// @param tokenId The token ID
  /// @return asset The constructed Asset struct
  function makeERC721(address token, uint256 tokenId) internal pure returns (Asset memory asset) {
    asset = Asset({assetType: AssetType.ERC721, target: token, id: tokenId, amount: 1});
  }

  /// @notice Creates an ERC1155 asset
  /// @param token The token address
  /// @param tokenId The token ID
  /// @param amount The token amount
  /// @return asset The constructed Asset struct
  function makeERC1155(address token, uint256 tokenId, uint256 amount) internal pure returns (Asset memory asset) {
    asset = Asset({assetType: AssetType.ERC1155, target: token, id: tokenId, amount: amount});
  }

  /// @notice Creates an array with a single asset
  /// @param asset The asset to wrap
  /// @return assets The single-element array
  function toArray(Asset memory asset) internal pure returns (Asset[] memory assets) {
    assets = new Asset[](1);
    assets[0] = asset;
  }

  /// @notice Creates an array with two assets
  /// @param a First asset
  /// @param b Second asset
  /// @return assets The two-element array
  function toArray(Asset memory a, Asset memory b) internal pure returns (Asset[] memory assets) {
    assets = new Asset[](2);
    assets[0] = a;
    assets[1] = b;
  }

  /// @notice Creates an array with three assets
  /// @param a First asset
  /// @param b Second asset
  /// @param c Third asset
  /// @return assets The three-element array
  function toArray(Asset memory a, Asset memory b, Asset memory c) internal pure returns (Asset[] memory assets) {
    assets = new Asset[](3);
    assets[0] = a;
    assets[1] = b;
    assets[2] = c;
  }

  /// @notice Creates an array with four assets
  /// @param a First asset
  /// @param b Second asset
  /// @param c Third asset
  /// @param d Fourth asset
  /// @return assets The four-element array
  function toArray(
    Asset memory a,
    Asset memory b,
    Asset memory c,
    Asset memory d
  ) internal pure returns (Asset[] memory assets) {
    assets = new Asset[](4);
    assets[0] = a;
    assets[1] = b;
    assets[2] = c;
    assets[3] = d;
  }
}
