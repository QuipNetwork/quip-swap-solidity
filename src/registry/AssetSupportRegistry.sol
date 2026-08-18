// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {IAssetSupportRegistry} from '../interfaces/IAssetSupportRegistry.sol';
import {AssetType} from '../protocol/ProtocolTypes.sol';
import {Ownable, Ownable2Step} from '@openzeppelin-contracts-5.6.0-rc.1/access/Ownable2Step.sol';

///  Commit-admission allowlist for token contracts. Native assets require no entry.
///  Approval asserts that the target follows the exact balance and ownership semantics enforced by AssetCustody.
/// Delisting blocks future commits only; wrappers never consult this registry during claim or reclaim.
contract AssetSupportRegistry is IAssetSupportRegistry, Ownable2Step {
  error InvalidAssetSupportConfiguration();

  event AssetSupportUpdated(AssetType indexed assetType, address indexed target, bool supported);

  mapping(AssetType assetType => mapping(address target => bool supported)) private _supported;

  constructor(address initialOwner) Ownable(initialOwner) {}

  function setAssetSupport(AssetType assetType, address target, bool supported) external onlyOwner {
    if (assetType == AssetType.Native || target == address(0) || (supported && target.code.length == 0)) {
      revert InvalidAssetSupportConfiguration();
    }
    _supported[assetType][target] = supported;
    emit AssetSupportUpdated(assetType, target, supported);
  }

  function isSupported(AssetType assetType, address target) external view returns (bool) {
    return assetType == AssetType.Native || _supported[assetType][target];
  }
}
