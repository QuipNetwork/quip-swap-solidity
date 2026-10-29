// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Asset, AssetType, Terms, TermsLib} from '../../../src/TermsLib.sol';
import {ERC20Mock} from '../../mocks/ERC20Mock.sol';
import {ERC721Mock} from '../../mocks/ERC721Mock.sol';
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

  /// @notice an ERC20-declared leg pointing at a stock ERC721 is rejected at deposit.
  /// Without the guard this collision reconciles cleanly (transferFrom moves token id
  /// `amount`=1, balanceOf delta reads 1 == amount) yet every later payout via
  /// transfer() reverts forever — so it must be blocked here.
  function test_transferAssetsNoNative_revertsWhen_erc20TargetIsERC721() public {
    // fresh NFT so the harness owns token id 1 (base setUp gives token 1 to ALICE)
    ERC721Mock nft = new ERC721Mock('Collide', 'CLD');
    nft.mint(address(harness), 1);

    // declared ERC20, target is the ERC721, amount 1 == the token id that gets moved
    Asset memory trap = Asset({assetType: AssetType.ERC20, target: address(nft), id: 0, amount: 1});
    Terms memory terms = _makeTermsWithAssets(trap.toArray());

    vm.expectRevert(TermsLib.AssetTypeMismatch.selector);
    harness.exposed_transferAssetsNoNative(terms, address(harness), BOB);
  }

  /// @notice the reverse mis-typing fails CLOSED at deposit on its own: an ERC721-declared
  /// leg pointing at an ERC20 calls ERC721.safeTransferFrom (selector 0x42842e0e), which a
  /// stock ERC20 does not implement, so the deposit reverts before any escrow is recorded.
  /// No AssetTypeMismatch guard is needed for this direction (documents the asymmetry).
  function test_transferAssetsNoNative_erc721TargetIsERC20_failsClosed() public {
    ERC20Mock token = new ERC20Mock('Plain', 'PLN', 18);
    token.mint(address(harness), 1000 ether);

    Asset memory trap = Asset({assetType: AssetType.ERC721, target: address(token), id: 1, amount: 1});
    Terms memory terms = _makeTermsWithAssets(trap.toArray());

    // the deposit calls ERC721.safeTransferFrom(address,address,uint256) = selector
    // 0x42842e0e, which a stock ERC20 does not implement and has no fallback for, so the
    // dispatcher reverts with EMPTY data. Pin that exact reason (not "any revert") so a
    // future change that made this path revert for some other cause would be caught.
    vm.expectRevert(bytes(''));
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
