// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Asset} from '../../../src/TermsLib.sol';
import {AssetHelper} from '../../utils/AssetHelper.sol';
import {TermsLibTest} from '../TermsLib.t.sol';

/// @title TermsLib releasePartyCommitment Tests
/// @dev Tests for TermsLib.releasePartyCommitment
contract TermsLib_releasePartyCommitment is TermsLibTest {
  using AssetHelper for *;

  // ============ Success Cases ============

  function test_releasePartyCommitment_transfersAllAssetTypes() public {
    Asset[] memory assets = AssetHelper.toArray(
      _makeNativeAsset(1 ether), _makeERC20Asset(100 ether), _makeERC721Asset(5), _makeERC1155Asset(1, 100)
    );

    uint256 aliceNativeBefore = ALICE.balance;
    uint256 aliceERC20Before = mockERC20.balanceOf(ALICE);
    uint256 aliceERC1155Before = mockERC1155.balanceOf(ALICE, 1);

    assertEq(mockERC721.ownerOf(5), address(harness));

    harness.exposed_releasePartyCommitment(address(harness), ALICE, assets);

    assertEq(ALICE.balance - aliceNativeBefore, 1 ether, 'Native transfer failed');
    assertEq(mockERC20.balanceOf(ALICE) - aliceERC20Before, 100 ether, 'ERC20 transfer failed');
    assertEq(mockERC721.ownerOf(5), ALICE, 'ERC721 transfer failed');
    assertEq(mockERC1155.balanceOf(ALICE, 1) - aliceERC1155Before, 100, 'ERC1155 transfer failed');
  }

  // ============ Fuzz Tests ============

  function testFuzz_releasePartyCommitment_transfersNative(uint256 amount) public {
    amount = bound(amount, 1, address(harness).balance);

    Asset[] memory assets = _makeNativeAsset(amount).toArray();
    uint256 aliceBefore = ALICE.balance;

    harness.exposed_releasePartyCommitment(address(harness), ALICE, assets);

    assertEq(ALICE.balance - aliceBefore, amount);
  }

  function testFuzz_releasePartyCommitment_transfersERC20(uint256 amount) public {
    amount = bound(amount, 1, mockERC20.balanceOf(address(harness)));

    Asset[] memory assets = _makeERC20Asset(amount).toArray();
    uint256 aliceBefore = mockERC20.balanceOf(ALICE);

    harness.exposed_releasePartyCommitment(address(harness), ALICE, assets);

    assertEq(mockERC20.balanceOf(ALICE) - aliceBefore, amount);
  }
}
