// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {AssetType} from '../../src/protocol/ProtocolTypes.sol';
import {AssetSupportRegistry} from '../../src/registry/AssetSupportRegistry.sol';
import {ERC20Mock} from '../mocks/ERC20Mock.sol';
import {Test} from 'forge-std-1.14.0/Test.sol';

contract AssetSupportRegistryTest is Test {
  AssetSupportRegistry internal registry;
  ERC20Mock internal token;

  function setUp() public {
    registry = new AssetSupportRegistry(address(this));
    token = new ERC20Mock('Token', 'TOK', 18);
  }

  function test_nativeAssetsAreAlwaysSupportedWithoutConfiguration() public view {
    assertTrue(registry.isSupported(AssetType.Native, address(0)));
  }

  function test_ownerCanEnableAndDisableSupportByAssetType() public {
    assertFalse(registry.isSupported(AssetType.ERC20, address(token)));
    registry.setAssetSupport(AssetType.ERC20, address(token), true);
    assertTrue(registry.isSupported(AssetType.ERC20, address(token)));
    assertFalse(registry.isSupported(AssetType.ERC721, address(token)));
    registry.setAssetSupport(AssetType.ERC20, address(token), false);
    assertFalse(registry.isSupported(AssetType.ERC20, address(token)));
  }

  function test_supportUpdateEmitsExactScope() public {
    vm.expectEmit(true, true, false, true);
    emit AssetSupportRegistry.AssetSupportUpdated(AssetType.ERC1155, address(token), true);
    registry.setAssetSupport(AssetType.ERC1155, address(token), true);
  }

  function test_onlyOwnerCanChangeSupport() public {
    vm.expectRevert();
    vm.prank(address(0xB0B));
    registry.setAssetSupport(AssetType.ERC20, address(token), true);
    assertFalse(registry.isSupported(AssetType.ERC20, address(token)));
  }

  function test_rejectsNativeZeroAndCodelessConfigurations() public {
    vm.expectRevert(AssetSupportRegistry.InvalidAssetSupportConfiguration.selector);
    registry.setAssetSupport(AssetType.Native, address(token), true);

    vm.expectRevert(AssetSupportRegistry.InvalidAssetSupportConfiguration.selector);
    registry.setAssetSupport(AssetType.ERC20, address(0), true);

    vm.expectRevert(AssetSupportRegistry.InvalidAssetSupportConfiguration.selector);
    registry.setAssetSupport(AssetType.ERC20, address(0xB0B), true);
  }
}
