// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Asset, AssetType, Terms, TermsLib} from '../../../src/TermsLib.sol';
import {TermsLibTest} from '../TermsLib.t.sol';
import {AssetHelper} from '../../utils/AssetHelper.sol';
import {TermsHelper} from '../../utils/TermsHelper.sol';

/// @title TermsLib validateTerms Tests
/// @dev Tests for TermsLib.validateTerms
contract TermsLib_validateTerms is TermsLibTest {
  using AssetHelper for *;
  using TermsHelper for *;

  // ============ Constants ============

  uint256 constant OTHER_CHAIN_ID = 999;

  // ============ Helpers ============

  function _validTerms() internal view returns (Terms memory) {
    return TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      uint64(block.timestamp + 1 days),
      _makeNativeAsset(1 ether).toArray()
    );
  }

  // ============ Success Cases ============

  function test_validateTerms_validTerms() public view {
    Terms memory terms = _validTerms();
    harness.exposed_validateTerms(terms);
  }

  function test_validateTerms_validWithDifferentChain() public view {
    Terms memory terms = TermsHelper.makeTerms(
      OTHER_CHAIN_ID,
      BOB,
      BOB_RECIPIENT,
      uint64(block.timestamp + 1 days),
      _makeERC20Asset(1 ether).toArray()
    );

    // Should succeed - validateTerms only checks non-zero chainId
    harness.exposed_validateTerms(terms);
  }

  function test_validateTerms_validWithMixedAssetTypes() public view {
    Asset[] memory mixedAssets = new Asset[](4);
    mixedAssets[0] = _makeNativeAsset(1 ether);
    mixedAssets[1] = _makeERC20Asset(100 ether);
    mixedAssets[2] = _makeERC721Asset(1);
    mixedAssets[3] = _makeERC1155Asset(1, 50);

    Terms memory terms = TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      uint64(block.timestamp + 1 days),
      mixedAssets
    );

    harness.exposed_validateTerms(terms);
  }

  // ============ Revert Cases ============

  function test_validateTerms_revertsWhen_emptyAssets() public {
    Asset[] memory emptyAssets = new Asset[](0);

    Terms memory terms = TermsHelper.makeTerms(
      block.chainid, ALICE, ALICE_RECIPIENT, uint64(block.timestamp + 1 days), emptyAssets
    );

    vm.expectRevert(TermsLib.EmptyAssets.selector);
    harness.exposed_validateTerms(terms);
  }

  function test_validateTerms_revertsWhen_chainIdZero() public {
    Terms memory terms = TermsHelper.makeTerms(
      0, // Zero chainId - invalid
      ALICE,
      ALICE_RECIPIENT,
      uint64(block.timestamp + 1 days),
      _makeNativeAsset(1 ether).toArray()
    );

    vm.expectRevert(TermsLib.ZeroChainId.selector);
    harness.exposed_validateTerms(terms);
  }

  function test_validateTerms_revertsWhen_expired() public {
    Terms memory terms = TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      uint64(block.timestamp - 1), // Expired
      _makeNativeAsset(1 ether).toArray()
    );

    vm.expectRevert(TermsLib.TermsExpired.selector);
    harness.exposed_validateTerms(terms);
  }

  function test_validateTerms_revertsWhen_atExactDeadline() public {
    Terms memory terms = TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      uint64(block.timestamp), // At exact deadline - expired
      _makeNativeAsset(1 ether).toArray()
    );

    vm.expectRevert(TermsLib.TermsExpired.selector);
    harness.exposed_validateTerms(terms);
  }

  function test_validateTerms_revertsWhen_invalidAssetZeroAmount() public {
    Asset[] memory invalidAssets = new Asset[](1);
    invalidAssets[0] = Asset({assetType: AssetType.Native, target: address(0), id: 0, amount: 0});

    Terms memory terms = TermsHelper.makeTerms(
      block.chainid, ALICE, ALICE_RECIPIENT, uint64(block.timestamp + 1 days), invalidAssets
    );

    vm.expectRevert(TermsLib.ZeroAmount.selector);
    harness.exposed_validateTerms(terms);
  }

  function test_validateTerms_revertsWhen_invalidNativeAsset() public {
    Asset[] memory invalidAssets = new Asset[](1);
    invalidAssets[0] = Asset({assetType: AssetType.Native, target: address(1), id: 0, amount: 1 ether});

    Terms memory terms = TermsHelper.makeTerms(
      block.chainid, ALICE, ALICE_RECIPIENT, uint64(block.timestamp + 1 days), invalidAssets
    );

    vm.expectRevert(TermsLib.InvalidNativeAsset.selector);
    harness.exposed_validateTerms(terms);
  }

  function test_validateTerms_revertsWhen_invalidERC20Asset() public {
    Asset[] memory invalidAssets = new Asset[](1);
    invalidAssets[0] = Asset({assetType: AssetType.ERC20, target: address(0), id: 0, amount: 1 ether});

    Terms memory terms = TermsHelper.makeTerms(
      block.chainid, ALICE, ALICE_RECIPIENT, uint64(block.timestamp + 1 days), invalidAssets
    );

    vm.expectRevert(TermsLib.InvalidERC20Asset.selector);
    harness.exposed_validateTerms(terms);
  }
}
