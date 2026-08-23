// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {IAssetSupportRegistry} from '../interfaces/IAssetSupportRegistry.sol';
import {Asset, AssetType, SideTerms} from '../protocol/ProtocolTypes.sol';
import {IERC1155} from '@openzeppelin-contracts-5.6.0-rc.1/token/ERC1155/IERC1155.sol';
import {IERC721} from '@openzeppelin-contracts-5.6.0-rc.1/token/ERC721/IERC721.sol';
import {SafeTransferLib} from 'solady-0.1.26/utils/SafeTransferLib.sol';

/// @title AssetCustody
/// @notice Collects, reserves, and releases native, ERC20, ERC721, and ERC1155 swap assets.
/// @dev Fungible-token transfers must change balances by the exact term amount; fee-on-transfer
///      and rebasing behavior is therefore rejected unless it preserves those exact semantics.
library AssetCustody {
  error IncorrectNativeAmount();
  error UnexpectedAmountReceived();
  error UnexpectedERC721Owner(address expected, address actual);
  error InsufficientReservedBalance();

  /// @notice Aggregate liabilities by asset type, token address, and token id.
  struct Layout {
    mapping(bytes32 assetKey => uint256 amount) reserved;
  }

  /// @notice Collects a side's assets, pulling tokens from its principal and accounting native value.
  /// @dev The caller supplies msg.value as nativeValue; it must equal the native assets exactly.
  function collect(Layout storage self, SideTerms memory side, uint256 nativeValue) internal {
    // Sum native liabilities while each non-native asset is pulled immediately.
    uint256 expectedNative;
    for (uint256 i; i < side.assets.length; ++i) {
      Asset memory asset = side.assets[i];
      bytes32 key = assetKey(asset);
      if (asset.assetType == AssetType.Native) {
        // Native value arrives once as msg.value, so only reserve it during iteration.
        expectedNative += asset.amount;
        self.reserved[key] += asset.amount;
      } else if (asset.assetType == AssetType.ERC721) {
        // Ownership, rather than a fungible balance delta, proves exact NFT receipt.
        _transferAsset(asset, side.principal, address(this));
        _requireERC721Owner(asset, address(this));
        self.reserved[key] += 1;
      } else {
        // Reject fee-on-transfer or otherwise non-exact fungible deposits.
        uint256 beforeBalance = _balance(asset);
        _transferAsset(asset, side.principal, address(this));
        if (_balance(asset) - beforeBalance != asset.amount) revert UnexpectedAmountReceived();
        self.reserved[key] += asset.amount;
      }
    }
    // Prevent both native underfunding and accidental excess value.
    if (nativeValue != expectedNative) revert IncorrectNativeAmount();
  }

  /// @notice Decreases liabilities and sends one side assets to the terms-fixed recipient.
  function release(Layout storage self, SideTerms memory side, address recipient) internal {
    for (uint256 i; i < side.assets.length; ++i) {
      Asset memory asset = side.assets[i];
      uint256 amount = asset.assetType == AssetType.ERC721 ? 1 : asset.amount;
      bytes32 key = assetKey(asset);
      // Ensure this transfer cannot consume funds reserved for unrelated trades.
      uint256 reserved = self.reserved[key];
      if (reserved < amount || _balance(asset) < reserved) revert InsufficientReservedBalance();
      // Effects precede the external transfer; a revert restores this accounting.
      self.reserved[key] = reserved - amount;
      if (asset.assetType == AssetType.ERC20 || asset.assetType == AssetType.ERC1155) {
        // Verify the recipient receives the exact fungible amount.
        uint256 beforeBalance = asset.assetType == AssetType.ERC1155
          ? IERC1155(asset.target).balanceOf(recipient, asset.id)
          : SafeTransferLib.balanceOf(asset.target, recipient);
        _transferAsset(asset, address(this), recipient);
        uint256 afterBalance = asset.assetType == AssetType.ERC1155
          ? IERC1155(asset.target).balanceOf(recipient, asset.id)
          : SafeTransferLib.balanceOf(asset.target, recipient);
        if (afterBalance - beforeBalance != amount) revert UnexpectedAmountReceived();
      } else if (asset.assetType == AssetType.ERC721) {
        // Verify the intended recipient becomes the NFT owner.
        _transferAsset(asset, address(this), recipient);
        _requireERC721Owner(asset, recipient);
      } else {
        _transferAsset(asset, address(this), recipient);
      }
    }
  }

  /// @notice Returns the aggregate reserved amount for an asset identity.
  function reservedAmount(Layout storage self, Asset memory asset) internal view returns (uint256) {
    return self.reserved[assetKey(asset)];
  }

  /// @notice Derives the reserve key; amount is intentionally excluded from asset identity.
  function assetKey(Asset memory asset) internal pure returns (bytes32) {
    return keccak256(abi.encode(asset.assetType, asset.target, asset.id));
  }

  function _transferAsset(Asset memory asset, address from, address to) private {
    if (asset.assetType == AssetType.Native) {
      SafeTransferLib.safeTransferETH(to, asset.amount);
    } else if (asset.assetType == AssetType.ERC20) {
      if (from == address(this)) {
        SafeTransferLib.safeTransfer(asset.target, to, asset.amount);
      } else {
        SafeTransferLib.safeTransferFrom(asset.target, from, to, asset.amount);
      }
    } else if (asset.assetType == AssetType.ERC721) {
      IERC721(asset.target).safeTransferFrom(from, to, asset.id);
    } else {
      IERC1155(asset.target).safeTransferFrom(from, to, asset.id, asset.amount, '');
    }
  }

  function _requireERC721Owner(Asset memory asset, address expected) private view {
    try IERC721(asset.target).ownerOf(asset.id) returns (address actual) {
      if (actual != expected) revert UnexpectedERC721Owner(expected, actual);
    } catch {
      revert UnexpectedERC721Owner(expected, address(0));
    }
  }

  function _balance(Asset memory asset) private view returns (uint256) {
    if (asset.assetType == AssetType.Native) return address(this).balance;
    if (asset.assetType == AssetType.ERC1155) return IERC1155(asset.target).balanceOf(address(this), asset.id);
    if (asset.assetType == AssetType.ERC721) {
      try IERC721(asset.target).ownerOf(asset.id) returns (address owner) {
        return owner == address(this) ? 1 : 0;
      } catch {
        return 0;
      }
    }
    return SafeTransferLib.balanceOf(asset.target, address(this));
  }
}

/// @title AssetSupport
/// @notice Enforces token-contract admission before a wrapper collects assets.
library AssetSupport {
  error UnsupportedAsset(AssetType assetType, address target);

  /// @notice Reverts if any distinct non-native token target is not allowlisted.
  function requireSupported(SideTerms memory side, IAssetSupportRegistry registry) internal view {
    AssetType previousType;
    address previousTarget;
    bool checkedPrevious;

    // Terms sorting makes repeated token targets adjacent, so one lookup can be reused.
    for (uint256 i; i < side.assets.length; ++i) {
      Asset memory asset = side.assets[i];
      // Native currency is always supported and has no registry target.
      if (asset.assetType == AssetType.Native) continue;
      // Skip duplicate target checks for multiple ids of the same token contract.
      if (checkedPrevious && asset.assetType == previousType && asset.target == previousTarget) continue;
      if (!registry.isSupported(asset.assetType, asset.target)) {
        revert UnsupportedAsset(asset.assetType, asset.target);
      }
      previousType = asset.assetType;
      previousTarget = asset.target;
      checkedPrevious = true;
    }
  }
}
