// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Asset, AssetType, TermsLib} from '../../../src/TermsLib.sol';
import {TermsLibTest} from '../TermsLib.t.sol';

/// @title TermsLib validateAsset Tests
/// @dev Tests for TermsLib.validateAsset
contract TermsLib_validateAsset is TermsLibTest {
  // ============ Success Cases ============

  function test_validateAsset_nativeAsset() public view {
    Asset memory asset = _makeNativeAsset(1 ether);
    harness.exposed_validateAsset(asset);
  }

  function test_validateAsset_erc20Asset() public view {
    Asset memory asset = _makeERC20Asset(1 ether);
    harness.exposed_validateAsset(asset);
  }

  function test_validateAsset_erc721Asset() public view {
    Asset memory asset = _makeERC721Asset(1);
    harness.exposed_validateAsset(asset);
  }

  function test_validateAsset_erc1155Asset() public view {
    Asset memory asset = _makeERC1155Asset(1, 100);
    harness.exposed_validateAsset(asset);
  }

  function test_validateAsset_erc721WithZeroId() public view {
    // token id 0 is a valid ERC721 token and must be accepted
    Asset memory asset = Asset({assetType: AssetType.ERC721, target: address(mockERC721), id: 0, amount: 1});
    harness.exposed_validateAsset(asset);
  }

  function test_validateAsset_erc1155WithZeroId() public view {
    // token id 0 is a valid ERC1155 token and must be accepted
    Asset memory asset = Asset({assetType: AssetType.ERC1155, target: address(mockERC1155), id: 0, amount: 100});
    harness.exposed_validateAsset(asset);
  }

  // ============ Fuzz Tests ============

  function testFuzz_validateAsset_nativeWithVariousAmounts(uint256 amount) public view {
    vm.assume(amount > 0);
    Asset memory asset = Asset({assetType: AssetType.Native, target: address(0), id: 0, amount: amount});
    harness.exposed_validateAsset(asset);
  }

  function testFuzz_validateAsset_erc20WithVariousAmounts(uint256 amount) public view {
    vm.assume(amount > 0);
    Asset memory asset = Asset({assetType: AssetType.ERC20, target: address(mockERC20), id: 0, amount: amount});
    harness.exposed_validateAsset(asset);
  }

  function testFuzz_validateAsset_erc721WithVariousIds(uint256 tokenId) public view {
    // id 0 is now valid, so no assumption on tokenId
    Asset memory asset = Asset({assetType: AssetType.ERC721, target: address(mockERC721), id: tokenId, amount: 1});
    harness.exposed_validateAsset(asset);
  }

  function testFuzz_validateAsset_erc1155WithVariousParams(uint256 tokenId, uint256 amount) public view {
    // id 0 is now valid; only amount must be non-zero
    vm.assume(amount > 0);
    Asset memory asset =
      Asset({assetType: AssetType.ERC1155, target: address(mockERC1155), id: tokenId, amount: amount});
    harness.exposed_validateAsset(asset);
  }

  // ============ Revert Cases ============

  function test_validateAsset_revertsWhen_zeroAmount() public {
    Asset memory asset = Asset({assetType: AssetType.Native, target: address(0), id: 0, amount: 0});
    vm.expectRevert(TermsLib.ZeroAmount.selector);
    harness.exposed_validateAsset(asset);
  }

  function test_validateAsset_revertsWhen_nativeWithNonZeroTarget() public {
    Asset memory asset = Asset({assetType: AssetType.Native, target: address(1), id: 0, amount: 1 ether});
    vm.expectRevert(TermsLib.InvalidNativeAsset.selector);
    harness.exposed_validateAsset(asset);
  }

  function test_validateAsset_revertsWhen_nativeWithNonZeroId() public {
    Asset memory asset = Asset({assetType: AssetType.Native, target: address(0), id: 1, amount: 1 ether});
    vm.expectRevert(TermsLib.InvalidNativeAsset.selector);
    harness.exposed_validateAsset(asset);
  }

  function test_validateAsset_revertsWhen_erc20WithZeroTarget() public {
    Asset memory asset = Asset({assetType: AssetType.ERC20, target: address(0), id: 0, amount: 1 ether});
    vm.expectRevert(TermsLib.InvalidERC20Asset.selector);
    harness.exposed_validateAsset(asset);
  }

  function test_validateAsset_revertsWhen_erc20WithNonZeroId() public {
    Asset memory asset = Asset({assetType: AssetType.ERC20, target: address(mockERC20), id: 1, amount: 1 ether});
    vm.expectRevert(TermsLib.InvalidERC20Asset.selector);
    harness.exposed_validateAsset(asset);
  }

  function test_validateAsset_revertsWhen_erc721WithZeroTarget() public {
    Asset memory asset = Asset({assetType: AssetType.ERC721, target: address(0), id: 1, amount: 1});
    vm.expectRevert(TermsLib.InvalidERC721Asset.selector);
    harness.exposed_validateAsset(asset);
  }

  function test_validateAsset_revertsWhen_erc1155WithZeroTarget() public {
    Asset memory asset = Asset({assetType: AssetType.ERC1155, target: address(0), id: 1, amount: 100});
    vm.expectRevert(TermsLib.InvalidERC1155Asset.selector);
    harness.exposed_validateAsset(asset);
  }
}
