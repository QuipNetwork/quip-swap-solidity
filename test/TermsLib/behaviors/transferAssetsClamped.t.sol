// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {IERC721Errors} from '@openzeppelin-contracts-5.7.0/interfaces/draft-IERC6093.sol';
import {SafeTransferLib} from 'solady-0.1.26/utils/SafeTransferLib.sol';

import {Asset, Terms} from '../../../src/TermsLib.sol';
import {AssetHelper} from '../../utils/AssetHelper.sol';
import {TermsHelper} from '../../utils/TermsHelper.sol';
import {TermsLibTest} from '../TermsLib.t.sol';

/// @title TermsLib transferAssetsClamped Tests
/// @dev Tests for TermsLib.transferAssetsClamped: fungible (ERC20/ERC1155) amounts are
///      clamped to the balance the harness actually holds; native and ERC721 stay strict.
///      The clamp is the reclaim escape hatch for balance-mutable tokens — a shrunk pooled
///      escrow pays the remainder instead of reverting forever.
contract TermsLib_transferAssetsClamped is TermsLibTest {
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

  /// @dev burns the harness's mockERC20 balance down to exactly `target`
  function _shrinkERC20HoldingsTo(uint256 target) internal {
    mockERC20.burn(address(harness), mockERC20.balanceOf(address(harness)) - target);
  }

  // ============ Success Cases (fully funded: clamp is a no-op) ============

  function test_transferAssetsClamped_transfersDeclaredERC20WhenFullyFunded() public {
    Terms memory terms = _makeTermsWithAssets(_makeERC20Asset(100 ether).toArray());
    uint256 bobBefore = mockERC20.balanceOf(BOB);

    harness.exposed_transferAssetsClamped(terms, BOB);

    assertEq(mockERC20.balanceOf(BOB) - bobBefore, 100 ether);
  }

  function test_transferAssetsClamped_transfersNative() public {
    Terms memory terms = _makeTermsWithAssets(_makeNativeAsset(1 ether).toArray());
    uint256 bobBefore = BOB.balance;

    harness.exposed_transferAssetsClamped(terms, BOB);

    assertEq(BOB.balance - bobBefore, 1 ether);
  }

  function test_transferAssetsClamped_transfersERC721() public {
    Terms memory terms = _makeTermsWithAssets(_makeERC721Asset(5).toArray());

    assertEq(mockERC721.ownerOf(5), address(harness));
    harness.exposed_transferAssetsClamped(terms, BOB);
    assertEq(mockERC721.ownerOf(5), BOB);
  }

  // ============ Clamping (shrunk holdings) ============

  function test_transferAssetsClamped_clampsERC20ToHeldBalance() public {
    Terms memory terms = _makeTermsWithAssets(_makeERC20Asset(100 ether).toArray());
    _shrinkERC20HoldingsTo(60 ether);
    uint256 bobBefore = mockERC20.balanceOf(BOB);

    harness.exposed_transferAssetsClamped(terms, BOB);

    assertEq(mockERC20.balanceOf(BOB) - bobBefore, 60 ether);
    assertEq(mockERC20.balanceOf(address(harness)), 0);
  }

  function test_transferAssetsClamped_clampsERC1155ToHeldBalance() public {
    Terms memory terms = _makeTermsWithAssets(_makeERC1155Asset(1, 100).toArray());
    mockERC1155.burn(address(harness), 1, 1000 - 40); // harness holds 1000 of id 1 from setUp
    uint256 bobBefore = mockERC1155.balanceOf(BOB, 1);

    harness.exposed_transferAssetsClamped(terms, BOB);

    assertEq(mockERC1155.balanceOf(BOB, 1) - bobBefore, 40);
  }

  function test_transferAssetsClamped_clampsToZeroWithoutReverting() public {
    Terms memory terms = _makeTermsWithAssets(_makeERC20Asset(100 ether).toArray());
    _shrinkERC20HoldingsTo(0);
    uint256 bobBefore = mockERC20.balanceOf(BOB);

    harness.exposed_transferAssetsClamped(terms, BOB);

    assertEq(mockERC20.balanceOf(BOB), bobBefore);
  }

  function test_transferAssetsClamped_clampsSequentiallyForRepeatedToken() public {
    // two entries of the same token: the first is paid in full, the second gets the remainder
    Asset[] memory assets = AssetHelper.toArray(_makeERC20Asset(100 ether), _makeERC20Asset(100 ether));
    Terms memory terms = _makeTermsWithAssets(assets);
    _shrinkERC20HoldingsTo(150 ether);
    uint256 bobBefore = mockERC20.balanceOf(BOB);

    harness.exposed_transferAssetsClamped(terms, BOB);

    assertEq(mockERC20.balanceOf(BOB) - bobBefore, 150 ether);
    assertEq(mockERC20.balanceOf(address(harness)), 0);
  }

  function test_transferAssetsClamped_clampedERC20DoesNotBlockNativeInSameTerms() public {
    Asset[] memory assets = AssetHelper.toArray(_makeERC20Asset(100 ether), _makeNativeAsset(1 ether));
    Terms memory terms = _makeTermsWithAssets(assets);
    _shrinkERC20HoldingsTo(60 ether);
    uint256 bobNativeBefore = BOB.balance;
    uint256 bobERC20Before = mockERC20.balanceOf(BOB);

    harness.exposed_transferAssetsClamped(terms, BOB);

    assertEq(mockERC20.balanceOf(BOB) - bobERC20Before, 60 ether);
    assertEq(BOB.balance - bobNativeBefore, 1 ether);
  }

  // ============ Reverts (native and ERC721 stay strict) ============

  function test_transferAssetsClamped_revertsWhen_nativeUnderfunded() public {
    // the native pool cannot shrink in place; a shortfall would be a contract bug and
    // must revert loudly, never be clamped
    Terms memory terms = _makeTermsWithAssets(_makeNativeAsset(200 ether).toArray()); // harness holds 100
    vm.expectRevert(SafeTransferLib.ETHTransferFailed.selector);
    harness.exposed_transferAssetsClamped(terms, BOB);
  }

  function test_transferAssetsClamped_revertsWhen_erc721NotHeld() public {
    // a specific NFT is either held or the transfer must revert; nothing to clamp
    Terms memory terms = _makeTermsWithAssets(_makeERC721Asset(1).toArray()); // owned by ALICE
    vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, address(harness), 1));
    harness.exposed_transferAssetsClamped(terms, BOB);
  }
}
