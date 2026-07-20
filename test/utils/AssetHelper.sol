// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Asset, AssetType} from '../../src/TermsLib.sol';

/// @title Asset Helper
/// @dev Utility functions for building Asset structs in tests. Address-typed
/// builders convert to the low-20-byte bytes32 convention internally; bytes32
/// overloads exist for foreign-chain (e.g. Solana-style) targets
library AssetHelper {
  /// @notice converts an EVM address to its bytes32 identifier (low 20 bytes)
  /// @param addr the address to widen
  /// @return the bytes32 identifier
  function toBytes32(address addr) internal pure returns (bytes32) {
    return bytes32(uint256(uint160(addr)));
  }

  /// @notice Creates a native asset
  /// @param amount The amount of native currency
  /// @return asset The constructed Asset struct
  function makeNative(uint256 amount) internal pure returns (Asset memory asset) {
    asset = Asset({assetType: AssetType.Native, target: bytes32(0), id: 0, amount: amount});
  }

  /// @notice Creates an ERC20 asset
  /// @param token The token address
  /// @param amount The token amount
  /// @return asset The constructed Asset struct
  function makeERC20(address token, uint256 amount) internal pure returns (Asset memory asset) {
    asset = makeERC20(toBytes32(token), amount);
  }

  /// @notice Creates an ERC20-semantics asset with a raw bytes32 target
  /// @param token The token identifier (e.g. a Solana mint pubkey)
  /// @param amount The token amount
  /// @return asset The constructed Asset struct
  function makeERC20(bytes32 token, uint256 amount) internal pure returns (Asset memory asset) {
    asset = Asset({assetType: AssetType.ERC20, target: token, id: 0, amount: amount});
  }

  /// @notice Creates an ERC721 asset
  /// @param token The token address
  /// @param tokenId The token ID
  /// @return asset The constructed Asset struct
  function makeERC721(address token, uint256 tokenId) internal pure returns (Asset memory asset) {
    asset = makeERC721(toBytes32(token), tokenId);
  }

  /// @notice Creates an ERC721-semantics asset with a raw bytes32 target
  /// @param token The token identifier (e.g. a Solana mint pubkey)
  /// @param tokenId The token ID
  /// @return asset The constructed Asset struct
  function makeERC721(bytes32 token, uint256 tokenId) internal pure returns (Asset memory asset) {
    asset = Asset({assetType: AssetType.ERC721, target: token, id: tokenId, amount: 1});
  }

  /// @notice Creates an ERC1155 asset
  /// @param token The token address
  /// @param tokenId The token ID
  /// @param amount The token amount
  /// @return asset The constructed Asset struct
  function makeERC1155(address token, uint256 tokenId, uint256 amount) internal pure returns (Asset memory asset) {
    asset = makeERC1155(toBytes32(token), tokenId, amount);
  }

  /// @notice Creates an ERC1155-semantics asset with a raw bytes32 target
  /// @param token The token identifier
  /// @param tokenId The token ID
  /// @param amount The token amount
  /// @return asset The constructed Asset struct
  function makeERC1155(bytes32 token, uint256 tokenId, uint256 amount) internal pure returns (Asset memory asset) {
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
