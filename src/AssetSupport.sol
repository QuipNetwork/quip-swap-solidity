// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {SideTerms} from './ProtocolTypes.sol';
import {AssetType} from './TermsLib.sol';
import {IAssetSupportRegistry} from './interfaces/IAssetSupportRegistry.sol';

library AssetSupport {
  error UnsupportedAsset(AssetType assetType, address target);

  function requireSupported(SideTerms memory side, IAssetSupportRegistry registry) internal view {
    for (uint256 i; i < side.assets.length; ++i) {
      if (
        side.assets[i].assetType != AssetType.Native
          && !registry.isSupported(side.assets[i].assetType, side.assets[i].target)
      ) {
        revert UnsupportedAsset(side.assets[i].assetType, side.assets[i].target);
      }
    }
  }
}
