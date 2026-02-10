// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Asset, AssetType} from '../../../src/TermsLib.sol';
import {AssetHelper} from '../../utils/AssetHelper.sol';
import {TermsLibTest} from '../TermsLib.t.sol';

/// @title TermsLib transferAsset Tests
/// @dev Tests for TermsLib.transferAsset
contract TermsLib_transferAsset is TermsLibTest {
  using AssetHelper for *;

  // ============ Native Asset Tests ============

  function test_transferAsset_nativeTransfersCorrectAmount() public {
    Asset memory asset = _makeNativeAsset(1 ether);
    uint256 recipientBefore = BOB.balance;

    harness.exposed_transferAsset(asset, address(0), BOB);

    assertEq(BOB.balance - recipientBefore, 1 ether);
  }

  function test_transferAsset_nativeReducesHarnessBalance() public {
    Asset memory asset = _makeNativeAsset(1 ether);
    uint256 harnessBefore = address(harness).balance;

    harness.exposed_transferAsset(asset, address(0), BOB);

    assertEq(harnessBefore - address(harness).balance, 1 ether);
  }

  // ============ ERC20 Asset Tests ============

  function test_transferAsset_erc20TransfersFromExternalAddress() public {
    Asset memory asset = _makeERC20Asset(100 ether);
    uint256 aliceBefore = mockERC20.balanceOf(ALICE);
    uint256 bobBefore = mockERC20.balanceOf(BOB);

    vm.prank(ALICE);
    mockERC20.approve(address(harness), 100 ether);

    harness.exposed_transferAsset(asset, ALICE, BOB);

    assertEq(aliceBefore - mockERC20.balanceOf(ALICE), 100 ether);
    assertEq(mockERC20.balanceOf(BOB) - bobBefore, 100 ether);
  }

  function test_transferAsset_erc20TransfersFromSelf() public {
    Asset memory asset = _makeERC20Asset(100 ether);
    uint256 harnessBefore = mockERC20.balanceOf(address(harness));
    uint256 bobBefore = mockERC20.balanceOf(BOB);

    harness.exposed_transferAsset(asset, address(harness), BOB);

    assertEq(harnessBefore - mockERC20.balanceOf(address(harness)), 100 ether);
    assertEq(mockERC20.balanceOf(BOB) - bobBefore, 100 ether);
  }

  // ============ ERC721 Asset Tests ============

  function test_transferAsset_erc721TransfersToken() public {
    Asset memory asset = _makeERC721Asset(1);

    vm.prank(ALICE);
    mockERC721.approve(address(harness), 1);

    assertEq(mockERC721.ownerOf(1), ALICE);
    harness.exposed_transferAsset(asset, ALICE, BOB);
    assertEq(mockERC721.ownerOf(1), BOB);
  }

  function test_transferAsset_erc721TransfersFromSelf() public {
    Asset memory asset = _makeERC721Asset(5);

    assertEq(mockERC721.ownerOf(5), address(harness));
    harness.exposed_transferAsset(asset, address(harness), BOB);
    assertEq(mockERC721.ownerOf(5), BOB);
  }

  // ============ ERC1155 Asset Tests ============

  function test_transferAsset_erc1155TransfersTokens() public {
    Asset memory asset = _makeERC1155Asset(1, 100);
    uint256 aliceBefore = mockERC1155.balanceOf(ALICE, 1);
    uint256 bobBefore = mockERC1155.balanceOf(BOB, 1);

    vm.prank(ALICE);
    mockERC1155.setApprovalForAll(address(harness), true);

    harness.exposed_transferAsset(asset, ALICE, BOB);

    assertEq(aliceBefore - mockERC1155.balanceOf(ALICE, 1), 100);
    assertEq(mockERC1155.balanceOf(BOB, 1) - bobBefore, 100);
  }

  function test_transferAsset_erc1155TransfersFromSelf() public {
    Asset memory asset = _makeERC1155Asset(1, 100);
    uint256 harnessBefore = mockERC1155.balanceOf(address(harness), 1);
    uint256 bobBefore = mockERC1155.balanceOf(BOB, 1);

    harness.exposed_transferAsset(asset, address(harness), BOB);

    assertEq(harnessBefore - mockERC1155.balanceOf(address(harness), 1), 100);
    assertEq(mockERC1155.balanceOf(BOB, 1) - bobBefore, 100);
  }

  // ============ Fuzz Tests ============

  function testFuzz_transferAsset_nativeWithVariousAmounts(uint256 amount) public {
    amount = bound(amount, 1, address(harness).balance);

    Asset memory asset = _makeNativeAsset(amount);
    uint256 bobBefore = BOB.balance;

    harness.exposed_transferAsset(asset, address(0), BOB);

    assertEq(BOB.balance - bobBefore, amount);
  }

  function testFuzz_transferAsset_erc20WithVariousAmounts(uint256 amount) public {
    amount = bound(amount, 1, mockERC20.balanceOf(address(harness)));

    Asset memory asset = _makeERC20Asset(amount);
    uint256 bobBefore = mockERC20.balanceOf(BOB);

    harness.exposed_transferAsset(asset, address(harness), BOB);

    assertEq(mockERC20.balanceOf(BOB) - bobBefore, amount);
  }
}
