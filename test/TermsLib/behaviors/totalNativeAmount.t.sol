// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Asset} from '../../../src/TermsLib.sol';
import {AssetHelper} from '../../utils/AssetHelper.sol';
import {TermsLibTest} from '../TermsLib.t.sol';

/// @title TermsLib totalNativeAmount Tests
/// @dev Tests for TermsLib.totalNativeAmount
contract TermsLib_totalNativeAmount is TermsLibTest {
  using AssetHelper for *;

  // ============ Success Cases ============

  function test_totalNativeAmount_singleNativeAsset() public view {
    Asset[] memory assets = _makeNativeAsset(1 ether).toArray();
    uint256 total = harness.exposed_totalNativeAmount(assets);
    assertEq(total, 1 ether);
  }

  function test_totalNativeAmount_multipleNativeAssets() public view {
    Asset[] memory assets = AssetHelper.toArray(_makeNativeAsset(1 ether), _makeNativeAsset(2 ether));

    uint256 total = harness.exposed_totalNativeAmount(assets);
    assertEq(total, 3 ether);
  }

  function test_totalNativeAmount_mixedAssets() public view {
    Asset[] memory assets =
      AssetHelper.toArray(_makeNativeAsset(1 ether), _makeERC20Asset(100 ether), _makeNativeAsset(2 ether));

    uint256 total = harness.exposed_totalNativeAmount(assets);
    assertEq(total, 3 ether);
  }

  function test_totalNativeAmount_noNativeAssets() public view {
    Asset[] memory assets = AssetHelper.toArray(_makeERC20Asset(100 ether), _makeERC1155Asset(1, 50));

    uint256 total = harness.exposed_totalNativeAmount(assets);
    assertEq(total, 0);
  }

  function test_totalNativeAmount_emptyArray() public view {
    Asset[] memory assets = new Asset[](0);
    uint256 total = harness.exposed_totalNativeAmount(assets);
    assertEq(total, 0);
  }

  function test_totalNativeAmount_onlyNonNativeAssets() public view {
    Asset[] memory assets = _makeERC20Asset(100 ether).toArray();
    uint256 total = harness.exposed_totalNativeAmount(assets);
    assertEq(total, 0);
  }

  // ============ Edge Cases ============

  function test_totalNativeAmount_largeAmounts() public view {
    Asset[] memory assets =
      AssetHelper.toArray(_makeNativeAsset(type(uint128).max), _makeNativeAsset(type(uint128).max));

    uint256 total = harness.exposed_totalNativeAmount(assets);
    assertEq(total, uint256(type(uint128).max) * 2);
  }

  function test_totalNativeAmount_manySmallAmounts() public view {
    uint256 count = 10;
    Asset[] memory assets = new Asset[](count);
    for (uint256 i = 0; i < count; i++) {
      assets[i] = _makeNativeAsset(0.1 ether);
    }

    uint256 total = harness.exposed_totalNativeAmount(assets);
    assertEq(total, 1 ether);
  }

  // ============ Fuzz Tests ============

  function testFuzz_totalNativeAmount_singleAsset(uint256 amount) public view {
    Asset[] memory assets = _makeNativeAsset(amount).toArray();
    uint256 total = harness.exposed_totalNativeAmount(assets);
    assertEq(total, amount);
  }

  function testFuzz_totalNativeAmount_twoAssets(uint256 amount1, uint256 amount2) public view {
    vm.assume(amount1 <= type(uint128).max);
    vm.assume(amount2 <= type(uint128).max);

    Asset[] memory assets = AssetHelper.toArray(_makeNativeAsset(amount1), _makeNativeAsset(amount2));

    uint256 total = harness.exposed_totalNativeAmount(assets);
    assertEq(total, amount1 + amount2);
  }

  function testFuzz_totalNativeAmount_mixedWithERC20(uint256 nativeAmount, uint256 erc20Amount) public view {
    Asset[] memory assets = AssetHelper.toArray(_makeNativeAsset(nativeAmount), _makeERC20Asset(erc20Amount));

    uint256 total = harness.exposed_totalNativeAmount(assets);
    assertEq(total, nativeAmount);
  }
}
