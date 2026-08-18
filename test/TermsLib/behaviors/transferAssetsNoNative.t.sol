// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Terms, TermsLib} from '../../../src/legacy/TermsLib.sol';
import {Asset} from '../../../src/protocol/ProtocolTypes.sol';
import {FeeOnTransferERC20Mock} from '../../mocks/FeeOnTransferERC20Mock.sol';
import {AssetHelper} from '../../utils/AssetHelper.sol';
import {TermsHelper} from '../../utils/TermsHelper.sol';
import {TermsLibTest} from '../TermsLib.t.sol';

/// @title TermsLib transferAssetsNoNative Tests
/// @dev Tests for TermsLib.transferAssetsNoNative
contract TermsLib_transferAssetsNoNative is TermsLibTest {
  using AssetHelper for *;
  using TermsHelper for *;

  // ============ Helpers ============

  function _makeTermsWithAssets(Asset[] memory assets) internal view returns (Terms memory) {
    return TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      DEFAULT_COMMITMENT_DEADLINE,
      DEFAULT_CLAIM_DEADLINE,
      DEFAULT_RECLAIM_RELEASE,
      assets
    );
  }

  // ============ Success Cases ============

  function test_transferAssetsNoNative_skipsNativeAssets() public {
    Asset[] memory assets = AssetHelper.toArray(_makeNativeAsset(1 ether), _makeERC20Asset(100 ether));
    Terms memory terms = _makeTermsWithAssets(assets);

    uint256 bobNativeBefore = BOB.balance;
    uint256 bobERC20Before = mockERC20.balanceOf(BOB);

    harness.exposed_transferAssetsNoNative(terms, address(harness), BOB);

    assertEq(BOB.balance, bobNativeBefore); // Native not transferred
    assertEq(mockERC20.balanceOf(BOB) - bobERC20Before, 100 ether); // ERC20 transferred
  }

  function test_transferAssetsNoNative_transfersERC20() public {
    Terms memory terms = _makeTermsWithAssets(_makeERC20Asset(100 ether).toArray());
    uint256 bobBefore = mockERC20.balanceOf(BOB);

    harness.exposed_transferAssetsNoNative(terms, address(harness), BOB);

    assertEq(mockERC20.balanceOf(BOB) - bobBefore, 100 ether);
  }

  function test_transferAssetsNoNative_transfersERC721() public {
    Terms memory terms = _makeTermsWithAssets(_makeERC721Asset(5).toArray());

    assertEq(mockERC721.ownerOf(5), address(harness));
    harness.exposed_transferAssetsNoNative(terms, address(harness), BOB);
    assertEq(mockERC721.ownerOf(5), BOB);
  }

  function test_transferAssetsNoNative_transfersERC1155() public {
    Terms memory terms = _makeTermsWithAssets(_makeERC1155Asset(1, 100).toArray());
    uint256 bobBefore = mockERC1155.balanceOf(BOB, 1);

    harness.exposed_transferAssetsNoNative(terms, address(harness), BOB);

    assertEq(mockERC1155.balanceOf(BOB, 1) - bobBefore, 100);
  }

  function test_transferAssetsNoNative_transfersMixedNonNativeAssets() public {
    Asset[] memory assets = AssetHelper.toArray(_makeERC20Asset(100 ether), _makeERC1155Asset(1, 50));
    Terms memory terms = _makeTermsWithAssets(assets);

    uint256 bobERC20Before = mockERC20.balanceOf(BOB);
    uint256 bobERC1155Before = mockERC1155.balanceOf(BOB, 1);

    harness.exposed_transferAssetsNoNative(terms, address(harness), BOB);

    assertEq(mockERC20.balanceOf(BOB) - bobERC20Before, 100 ether);
    assertEq(mockERC1155.balanceOf(BOB, 1) - bobERC1155Before, 50);
  }

  function test_transferAssetsNoNative_handlesOnlyNativeAssets() public {
    Asset[] memory assets = AssetHelper.toArray(_makeNativeAsset(1 ether), _makeNativeAsset(2 ether));
    Terms memory terms = _makeTermsWithAssets(assets);

    uint256 bobNativeBefore = BOB.balance;
    uint256 harnessBefore = address(harness).balance;

    harness.exposed_transferAssetsNoNative(terms, address(harness), BOB);

    assertEq(BOB.balance, bobNativeBefore); // No change
    assertEq(address(harness).balance, harnessBefore); // No change
  }

  function test_transferAssetsNoNative_handlesEmptyArray() public {
    Asset[] memory assets = new Asset[](0);
    Terms memory terms = _makeTermsWithAssets(assets);
    uint256 bobBefore = BOB.balance;

    harness.exposed_transferAssetsNoNative(terms, address(harness), BOB);

    assertEq(BOB.balance, bobBefore);
  }

  // ============ Revert Cases ============

  function test_transferAssetsNoNative_revertsWhen_feeOnTransferUnderDelivers() public {
    FeeOnTransferERC20Mock feeToken = new FeeOnTransferERC20Mock('Fee', 'FEE', 100); // 1% fee
    feeToken.mint(address(harness), 1000 ether);

    Asset[] memory assets = AssetHelper.makeERC20(address(feeToken), 100 ether).toArray();
    Terms memory terms = _makeTermsWithAssets(assets);

    vm.expectRevert(TermsLib.UnexpectedAmountReceived.selector);
    harness.exposed_transferAssetsNoNative(terms, address(harness), BOB);
  }

  // ============ Fuzz Tests ============

  function testFuzz_transferAssetsNoNative_revertsWhen_feeOnTransfer(uint256 feeBps) public {
    feeBps = bound(feeBps, 1, 10_000);
    FeeOnTransferERC20Mock feeToken = new FeeOnTransferERC20Mock('Fee', 'FEE', feeBps);
    feeToken.mint(address(harness), 1000 ether);

    Asset[] memory assets = AssetHelper.makeERC20(address(feeToken), 100 ether).toArray();
    Terms memory terms = _makeTermsWithAssets(assets);

    vm.expectRevert(TermsLib.UnexpectedAmountReceived.selector);
    harness.exposed_transferAssetsNoNative(terms, address(harness), BOB);
  }

  function testFuzz_transferAssetsNoNative_skipsNative(uint256 nativeAmount, uint256 erc20Amount) public {
    nativeAmount = bound(nativeAmount, 1, 10 ether);
    erc20Amount = bound(erc20Amount, 1, mockERC20.balanceOf(address(harness)));

    Asset[] memory assets = AssetHelper.toArray(_makeNativeAsset(nativeAmount), _makeERC20Asset(erc20Amount));
    Terms memory terms = _makeTermsWithAssets(assets);

    uint256 bobNativeBefore = BOB.balance;
    uint256 bobERC20Before = mockERC20.balanceOf(BOB);

    harness.exposed_transferAssetsNoNative(terms, address(harness), BOB);

    assertEq(BOB.balance, bobNativeBefore);
    assertEq(mockERC20.balanceOf(BOB) - bobERC20Before, erc20Amount);
  }
}
