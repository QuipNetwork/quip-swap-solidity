// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {IAssetSupportRegistry} from '../interfaces/IAssetSupportRegistry.sol';
import {AssetType} from '../protocol/ProtocolTypes.sol';
import {Ownable, Ownable2Step} from '@openzeppelin-contracts-5.6.0-rc.1/access/Ownable2Step.sol';

/// @title AssetSupportRegistry
/// @notice Owner-managed commit-admission allowlist for token contracts.
/// @dev Native assets require no entry. Approval asserts exact balance and ownership semantics
///      compatible with AssetCustody. Delisting blocks future commits, not claim or reclaim.
contract AssetSupportRegistry is IAssetSupportRegistry, Ownable2Step {
  error InvalidAssetSupportConfiguration();

  event AssetSupportUpdated(AssetType indexed assetType, address indexed target, bool supported);

  mapping(AssetType assetType => mapping(address target => bool supported)) private _supported;

  /// @notice Sets the owner responsible for token compatibility review.
  constructor(address initialOwner) Ownable(initialOwner) {}

  /// @notice Adds or removes a deployed non-native token target from commit admission.
  function setAssetSupport(AssetType assetType, address target, bool supported) external onlyOwner {
    // Native support is implicit; token entries require a deployed nonzero target.
    if (assetType == AssetType.Native || target == address(0) || (supported && target.code.length == 0)) {
      revert InvalidAssetSupportConfiguration();
    }
    // The new policy affects admission of future commits only.
    _supported[assetType][target] = supported;
    emit AssetSupportUpdated(assetType, target, supported);
  }

  /// @inheritdoc IAssetSupportRegistry
  function isSupported(AssetType assetType, address target) external view returns (bool) {
    return assetType == AssetType.Native || _supported[assetType][target];
  }
}
