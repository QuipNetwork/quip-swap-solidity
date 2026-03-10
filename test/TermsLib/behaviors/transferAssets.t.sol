// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Asset, Terms} from '../../../src/TermsLib.sol';
import {AssetHelper} from '../../utils/AssetHelper.sol';
import {TermsHelper} from '../../utils/TermsHelper.sol';
import {TermsLibTest} from '../TermsLib.t.sol';

/// @title TermsLib transferAssets Tests
/// @dev Tests for TermsLib.transferAssets
contract TermsLib_transferAssets is TermsLibTest {
  using AssetHelper for *;
  using TermsHelper for *;

  // ============ Helpers ============

  function _makeTermsWithAssets(Asset[] memory assets) internal view returns (Terms memory) {
    return TermsHelper.makeTerms(block.chainid, ALICE, ALICE_RECIPIENT, DEFAULT_DEADLINE, assets);
  }

  // ============ Success Cases ============

  function test_transferAssets_transfersSingleNativeAsset() public {
    Terms memory terms = _makeTermsWithAssets(_makeNativeAsset(1 ether).toArray());
    uint256 bobBefore = BOB.balance;

    harness.exposed_transferAssets(terms, address(harness), BOB);

    assertEq(BOB.balance - bobBefore, 1 ether);
  }

  function test_transferAssets_transfersMultipleNativeAssets() public {
    Asset[] memory assets = AssetHelper.toArray(_makeNativeAsset(1 ether), _makeNativeAsset(2 ether));
    Terms memory terms = _makeTermsWithAssets(assets);

    uint256 bobBefore = BOB.balance;

    harness.exposed_transferAssets(terms, address(harness), BOB);

    assertEq(BOB.balance - bobBefore, 3 ether);
  }

  function test_transferAssets_transfersMixedAssets() public {
    Asset[] memory assets =
      AssetHelper.toArray(_makeNativeAsset(1 ether), _makeERC20Asset(100 ether), _makeERC1155Asset(1, 50));
    Terms memory terms = _makeTermsWithAssets(assets);

    uint256 bobNativeBefore = BOB.balance;
    uint256 bobERC20Before = mockERC20.balanceOf(BOB);
    uint256 bobERC1155Before = mockERC1155.balanceOf(BOB, 1);

    harness.exposed_transferAssets(terms, address(harness), BOB);

    assertEq(BOB.balance - bobNativeBefore, 1 ether);
    assertEq(mockERC20.balanceOf(BOB) - bobERC20Before, 100 ether);
    assertEq(mockERC1155.balanceOf(BOB, 1) - bobERC1155Before, 50);
  }

  function test_transferAssets_transfersEmptyArray() public {
    Asset[] memory assets = new Asset[](0);
    Terms memory terms = _makeTermsWithAssets(assets);
    uint256 bobBefore = BOB.balance;

    harness.exposed_transferAssets(terms, address(harness), BOB);

    assertEq(BOB.balance, bobBefore);
  }

  function test_transferAssets_transfersERC721() public {
    Terms memory terms = _makeTermsWithAssets(_makeERC721Asset(5).toArray());

    assertEq(mockERC721.ownerOf(5), address(harness));
    harness.exposed_transferAssets(terms, address(harness), BOB);
    assertEq(mockERC721.ownerOf(5), BOB);
  }

  // ============ Edge Cases ============

  function test_transferAssets_handlesLargeArray() public {
    uint256 count = 10;
    Asset[] memory assets = new Asset[](count);
    for (uint256 i = 0; i < count; i++) {
      assets[i] = _makeNativeAsset(0.1 ether);
    }
    Terms memory terms = _makeTermsWithAssets(assets);

    uint256 bobBefore = BOB.balance;

    harness.exposed_transferAssets(terms, address(harness), BOB);

    assertEq(BOB.balance - bobBefore, 1 ether);
  }

  // ============ Fuzz Tests ============

  function testFuzz_transferAssets_singleNativeAsset(uint256 amount) public {
    amount = bound(amount, 1, address(harness).balance);

    Terms memory terms = _makeTermsWithAssets(_makeNativeAsset(amount).toArray());
    uint256 bobBefore = BOB.balance;

    harness.exposed_transferAssets(terms, address(harness), BOB);

    assertEq(BOB.balance - bobBefore, amount);
  }
}
