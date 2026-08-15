// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {AssetType} from '../TermsLib.sol';

interface IAssetSupportRegistry {
  function isSupported(AssetType assetType, address target) external view returns (bool);
}
