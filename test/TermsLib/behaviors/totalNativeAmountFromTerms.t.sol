// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Asset, Terms} from '../../../src/TermsLib.sol';
import {TermsLibTest} from '../TermsLib.t.sol';
import {AssetHelper} from '../../utils/AssetHelper.sol';
import {TermsHelper} from '../../utils/TermsHelper.sol';

/// @title TermsLib totalNativeAmountFromTerms Tests
/// @dev Tests for TermsLib.totalNativeAmountFromTerms
contract TermsLib_totalNativeAmountFromTerms is TermsLibTest {
  using AssetHelper for *;
  using TermsHelper for *;

  // ============ Success Cases ============

  function test_totalNativeAmountFromTerms_nativeCollateralOnly() public view {
    Terms memory terms = TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      DEFAULT_DEADLINE,
      _makeNativeAsset(1 ether), // Native collateral
      _makeERC20Asset(100 ether).toArray() // Non-native assets
    );

    uint256 total = harness.exposed_totalNativeAmountFromTerms(terms);
    assertEq(total, 1 ether);
  }

  function test_totalNativeAmountFromTerms_nativeAssetsOnly() public view {
    Terms memory terms = TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      DEFAULT_DEADLINE,
      _makeERC20Asset(1 ether), // Non-native collateral
      _makeNativeAsset(5 ether).toArray() // Native assets
    );

    uint256 total = harness.exposed_totalNativeAmountFromTerms(terms);
    assertEq(total, 5 ether);
  }

  function test_totalNativeAmountFromTerms_nativeCollateralAndAssets() public view {
    Asset[] memory assets = AssetHelper.toArray(_makeNativeAsset(3 ether), _makeNativeAsset(2 ether));

    Terms memory terms = TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      DEFAULT_DEADLINE,
      _makeNativeAsset(1 ether), // Native collateral
      assets // Native assets
    );

    uint256 total = harness.exposed_totalNativeAmountFromTerms(terms);
    assertEq(total, 6 ether); // 1 + 3 + 2
  }

  function test_totalNativeAmountFromTerms_noNative() public view {
    Terms memory terms = TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      DEFAULT_DEADLINE,
      _makeERC20Asset(1 ether), // Non-native collateral
      _makeERC20Asset(100 ether).toArray() // Non-native assets
    );

    uint256 total = harness.exposed_totalNativeAmountFromTerms(terms);
    assertEq(total, 0);
  }

  function test_totalNativeAmountFromTerms_nonNativeCollateral() public view {
    Asset[] memory assets = _makeNativeAsset(5 ether).toArray();

    Terms memory terms = TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      DEFAULT_DEADLINE,
      _makeERC20Asset(10 ether), // ERC20 collateral - not counted
      assets
    );

    uint256 total = harness.exposed_totalNativeAmountFromTerms(terms);
    assertEq(total, 5 ether); // Only assets counted
  }

  function test_totalNativeAmountFromTerms_mixedAssets() public view {
    Asset[] memory mixedAssets = new Asset[](4);
    mixedAssets[0] = _makeNativeAsset(1 ether);
    mixedAssets[1] = _makeERC20Asset(100 ether);
    mixedAssets[2] = _makeNativeAsset(2 ether);
    mixedAssets[3] = _makeERC1155Asset(1, 50);

    Terms memory terms = TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      DEFAULT_DEADLINE,
      _makeNativeAsset(0.5 ether), // Native collateral
      mixedAssets
    );

    uint256 total = harness.exposed_totalNativeAmountFromTerms(terms);
    assertEq(total, 3.5 ether); // 0.5 + 1 + 2
  }

  function test_totalNativeAmountFromTerms_emptyAssets() public view {
    Asset[] memory emptyAssets = new Asset[](0);

    Terms memory terms = TermsHelper.makeTerms(
      block.chainid, ALICE, ALICE_RECIPIENT, DEFAULT_DEADLINE, _makeNativeAsset(1 ether), emptyAssets
    );

    uint256 total = harness.exposed_totalNativeAmountFromTerms(terms);
    assertEq(total, 1 ether); // Only collateral
  }

  // ============ Fuzz Tests ============

  function testFuzz_totalNativeAmountFromTerms_nativeCollateralAndAssets(
    uint256 collateralAmount,
    uint256 assetAmount
  ) public view {
    collateralAmount = bound(collateralAmount, 1, type(uint128).max);
    assetAmount = bound(assetAmount, 1, type(uint128).max);

    Terms memory terms = TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      DEFAULT_DEADLINE,
      _makeNativeAsset(collateralAmount),
      _makeNativeAsset(assetAmount).toArray()
    );

    uint256 total = harness.exposed_totalNativeAmountFromTerms(terms);
    assertEq(total, collateralAmount + assetAmount);
  }

  function testFuzz_totalNativeAmountFromTerms_nonNativeCollateral(
    uint256 collateralAmount,
    uint256 assetAmount
  ) public view {
    collateralAmount = bound(collateralAmount, 1, type(uint128).max);
    assetAmount = bound(assetAmount, 1, type(uint128).max);

    Terms memory terms = TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      DEFAULT_DEADLINE,
      _makeERC20Asset(collateralAmount), // Not counted
      _makeNativeAsset(assetAmount).toArray()
    );

    uint256 total = harness.exposed_totalNativeAmountFromTerms(terms);
    assertEq(total, assetAmount); // Only native assets
  }
}
