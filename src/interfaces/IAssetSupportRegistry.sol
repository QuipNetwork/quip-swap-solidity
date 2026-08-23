// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {AssetType} from '../protocol/ProtocolTypes.sol';

/// @notice Read-only token admission policy used when wrappers collect new escrow.
interface IAssetSupportRegistry {
  /// @notice Reports whether an asset type and target may enter protocol custody.
  function isSupported(AssetType assetType, address target) external view returns (bool);
}
