// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Terms} from '../../../src/legacy/TermsLib.sol';
import {Asset} from '../../../src/protocol/ProtocolTypes.sol';
import {AssetHelper} from '../../utils/AssetHelper.sol';
import {TermsHelper} from '../../utils/TermsHelper.sol';
import {TermsLibTest} from '../TermsLib.t.sol';

/// @title TermsLib totalNative Tests
/// @dev Tests for TermsLib.totalNative
contract TermsLib_totalNative is TermsLibTest {
  using AssetHelper for *;
  using TermsHelper for *;

  // ============ Success Cases ============

  function test_totalNative_singleNativeAsset() public view {
    Terms memory terms = TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      DEFAULT_COMMITMENT_DEADLINE,
      DEFAULT_CLAIM_DEADLINE,
      DEFAULT_RECLAIM_RELEASE,
      _makeNativeAsset(5 ether).toArray()
    );

    uint256 total = harness.exposed_totalNative(terms);
    assertEq(total, 5 ether);
  }

  function test_totalNative_multipleNativeAssets() public view {
    Asset[] memory assets = AssetHelper.toArray(_makeNativeAsset(3 ether), _makeNativeAsset(2 ether));

    Terms memory terms = TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      DEFAULT_COMMITMENT_DEADLINE,
      DEFAULT_CLAIM_DEADLINE,
      DEFAULT_RECLAIM_RELEASE,
      assets
    );

    uint256 total = harness.exposed_totalNative(terms);
    assertEq(total, 5 ether); // 3 + 2
  }

  function test_totalNative_noNativeAssets() public view {
    Terms memory terms = TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      DEFAULT_COMMITMENT_DEADLINE,
      DEFAULT_CLAIM_DEADLINE,
      DEFAULT_RECLAIM_RELEASE,
      _makeERC20Asset(100 ether).toArray()
    );

    uint256 total = harness.exposed_totalNative(terms);
    assertEq(total, 0);
  }

  function test_totalNative_mixedAssets() public view {
    Asset[] memory mixedAssets = new Asset[](4);
    mixedAssets[0] = _makeNativeAsset(1 ether);
    mixedAssets[1] = _makeERC20Asset(100 ether);
    mixedAssets[2] = _makeNativeAsset(2 ether);
    mixedAssets[3] = _makeERC1155Asset(1, 50);

    Terms memory terms = TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      DEFAULT_COMMITMENT_DEADLINE,
      DEFAULT_CLAIM_DEADLINE,
      DEFAULT_RECLAIM_RELEASE,
      mixedAssets
    );

    uint256 total = harness.exposed_totalNative(terms);
    assertEq(total, 3 ether); // 1 + 2
  }

  function test_totalNative_emptyAssets() public view {
    Asset[] memory emptyAssets = new Asset[](0);

    Terms memory terms = TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      DEFAULT_COMMITMENT_DEADLINE,
      DEFAULT_CLAIM_DEADLINE,
      DEFAULT_RECLAIM_RELEASE,
      emptyAssets
    );

    uint256 total = harness.exposed_totalNative(terms);
    assertEq(total, 0);
  }

  // ============ Fuzz Tests ============

  function testFuzz_totalNative_singleNativeAsset(uint256 assetAmount) public view {
    assetAmount = bound(assetAmount, 1, type(uint128).max);

    Terms memory terms = TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      DEFAULT_COMMITMENT_DEADLINE,
      DEFAULT_CLAIM_DEADLINE,
      DEFAULT_RECLAIM_RELEASE,
      _makeNativeAsset(assetAmount).toArray()
    );

    uint256 total = harness.exposed_totalNative(terms);
    assertEq(total, assetAmount);
  }

  function testFuzz_totalNative_twoNativeAssets(uint256 amount1, uint256 amount2) public view {
    amount1 = bound(amount1, 1, type(uint128).max);
    amount2 = bound(amount2, 1, type(uint128).max);

    Asset[] memory assets = AssetHelper.toArray(_makeNativeAsset(amount1), _makeNativeAsset(amount2));

    Terms memory terms = TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      DEFAULT_COMMITMENT_DEADLINE,
      DEFAULT_CLAIM_DEADLINE,
      DEFAULT_RECLAIM_RELEASE,
      assets
    );

    uint256 total = harness.exposed_totalNative(terms);
    assertEq(total, amount1 + amount2);
  }

  function testFuzz_totalNative_nonNativeAssets(uint256 erc20Amount) public view {
    erc20Amount = bound(erc20Amount, 1, type(uint128).max);

    Terms memory terms = TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      DEFAULT_COMMITMENT_DEADLINE,
      DEFAULT_CLAIM_DEADLINE,
      DEFAULT_RECLAIM_RELEASE,
      _makeERC20Asset(erc20Amount).toArray()
    );

    uint256 total = harness.exposed_totalNative(terms);
    assertEq(total, 0); // ERC20 not counted
  }
}
