// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Asset} from '../../../src/TermsLib.sol';
import {AssetHelper} from '../../utils/AssetHelper.sol';
import {TermsLibTest} from '../TermsLib.t.sol';

/// @title TermsLib executePartyCommitment Tests
/// @dev Tests for TermsLib.executePartyCommitment
contract TermsLib_executePartyCommitment is TermsLibTest {
  using AssetHelper for *;

  // ============ Success Cases ============

  function test_executePartyCommitment_transfersAllAssetTypes() public {
    Asset[] memory assets = AssetHelper.toArray(
      _makeNativeAsset(1 ether), _makeERC20Asset(100 ether), _makeERC721Asset(5), _makeERC1155Asset(1, 100)
    );

    uint256 bobNativeBefore = BOB.balance;
    uint256 bobERC20Before = mockERC20.balanceOf(BOB);
    uint256 bobERC1155Before = mockERC1155.balanceOf(BOB, 1);

    assertEq(mockERC721.ownerOf(5), address(harness));

    harness.exposed_executePartyCommitment(address(harness), BOB, assets);

    assertEq(BOB.balance - bobNativeBefore, 1 ether, 'Native transfer failed');
    assertEq(mockERC20.balanceOf(BOB) - bobERC20Before, 100 ether, 'ERC20 transfer failed');
    assertEq(mockERC721.ownerOf(5), BOB, 'ERC721 transfer failed');
    assertEq(mockERC1155.balanceOf(BOB, 1) - bobERC1155Before, 100, 'ERC1155 transfer failed');
  }

  // ============ Fuzz Tests ============

  function testFuzz_executePartyCommitment_transfersNative(uint256 amount) public {
    amount = bound(amount, 1, address(harness).balance);

    Asset[] memory assets = _makeNativeAsset(amount).toArray();
    uint256 bobBefore = BOB.balance;

    harness.exposed_executePartyCommitment(address(harness), BOB, assets);

    assertEq(BOB.balance - bobBefore, amount);
  }

  function testFuzz_executePartyCommitment_transfersERC20(uint256 amount) public {
    amount = bound(amount, 1, mockERC20.balanceOf(address(harness)));

    Asset[] memory assets = _makeERC20Asset(amount).toArray();
    uint256 bobBefore = mockERC20.balanceOf(BOB);

    harness.exposed_executePartyCommitment(address(harness), BOB, assets);

    assertEq(mockERC20.balanceOf(BOB) - bobBefore, amount);
  }
}
