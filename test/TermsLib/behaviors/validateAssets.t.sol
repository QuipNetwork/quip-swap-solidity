// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Terms, TermsLib} from '../../../src/legacy/TermsLib.sol';
import {Asset, AssetType} from '../../../src/protocol/ProtocolTypes.sol';
import {AssetHelper} from '../../utils/AssetHelper.sol';
import {TermsHelper} from '../../utils/TermsHelper.sol';
import {TermsLibTest} from '../TermsLib.t.sol';

/// @title TermsLib validateAssets Tests
/// @dev Tests for TermsLib.validateAssets
contract TermsLib_validateAssets is TermsLibTest {
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

  function test_validateAssets_emptyArray() public view {
    Asset[] memory assets = new Asset[](0);
    Terms memory terms = _makeTermsWithAssets(assets);
    harness.exposed_validateAssets(terms);
  }

  function test_validateAssets_singleNativeAsset() public view {
    Terms memory terms = _makeTermsWithAssets(_makeNativeAsset(1 ether).toArray());
    harness.exposed_validateAssets(terms);
  }

  function test_validateAssets_singleERC20Asset() public view {
    Terms memory terms = _makeTermsWithAssets(_makeERC20Asset(100 ether).toArray());
    harness.exposed_validateAssets(terms);
  }

  function test_validateAssets_singleERC721Asset() public view {
    Terms memory terms = _makeTermsWithAssets(_makeERC721Asset(1).toArray());
    harness.exposed_validateAssets(terms);
  }

  function test_validateAssets_singleERC1155Asset() public view {
    Terms memory terms = _makeTermsWithAssets(_makeERC1155Asset(1, 100).toArray());
    harness.exposed_validateAssets(terms);
  }

  function test_validateAssets_multipleAssetsOfSameType() public view {
    Asset[] memory assets =
      AssetHelper.toArray(_makeNativeAsset(1 ether), _makeNativeAsset(2 ether), _makeNativeAsset(3 ether));
    Terms memory terms = _makeTermsWithAssets(assets);
    harness.exposed_validateAssets(terms);
  }

  function test_validateAssets_mixedAssetTypes() public view {
    Asset[] memory assets = AssetHelper.toArray(
      _makeNativeAsset(1 ether), _makeERC20Asset(100 ether), _makeERC721Asset(1), _makeERC1155Asset(1, 50)
    );
    Terms memory terms = _makeTermsWithAssets(assets);
    harness.exposed_validateAssets(terms);
  }

  // ============ Revert Cases ============

  function test_validateAssets_revertsWhen_singleInvalidAsset() public {
    Asset[] memory assets = new Asset[](1);
    assets[0] = Asset({assetType: AssetType.Native, target: address(0), id: 0, amount: 0});
    Terms memory terms = _makeTermsWithAssets(assets);

    vm.expectRevert(TermsLib.ZeroAmount.selector);
    harness.exposed_validateAssets(terms);
  }

  function test_validateAssets_revertsWhen_firstAssetInvalid() public {
    Asset[] memory assets = new Asset[](2);
    assets[0] = Asset({assetType: AssetType.Native, target: address(1), id: 0, amount: 1 ether}); // invalid: non-zero target
    assets[1] = _makeNativeAsset(1 ether); // valid

    Terms memory terms = _makeTermsWithAssets(assets);

    vm.expectRevert(TermsLib.InvalidNativeAsset.selector);
    harness.exposed_validateAssets(terms);
  }

  function test_validateAssets_revertsWhen_middleAssetInvalid() public {
    Asset[] memory assets = new Asset[](3);
    assets[0] = _makeNativeAsset(1 ether); // valid
    assets[1] = Asset({assetType: AssetType.ERC20, target: address(0), id: 0, amount: 100 ether}); // invalid: zero target
    assets[2] = _makeNativeAsset(2 ether); // valid

    Terms memory terms = _makeTermsWithAssets(assets);

    vm.expectRevert(TermsLib.InvalidERC20Asset.selector);
    harness.exposed_validateAssets(terms);
  }

  function test_validateAssets_revertsWhen_lastAssetInvalid() public {
    Asset[] memory assets = new Asset[](3);
    assets[0] = _makeNativeAsset(1 ether); // valid
    assets[1] = _makeERC20Asset(100 ether); // valid
    assets[2] = Asset({assetType: AssetType.ERC721, target: address(0), id: 1, amount: 1}); // invalid: zero target

    Terms memory terms = _makeTermsWithAssets(assets);

    vm.expectRevert(TermsLib.InvalidERC721Asset.selector);
    harness.exposed_validateAssets(terms);
  }

  function test_validateAssets_revertsWhen_erc1155InvalidInMixedArray() public {
    Asset[] memory assets = new Asset[](4);
    assets[0] = _makeNativeAsset(1 ether);
    assets[1] = _makeERC20Asset(100 ether);
    assets[2] = _makeERC721Asset(1);
    assets[3] = Asset({assetType: AssetType.ERC1155, target: address(0), id: 1, amount: 100}); // invalid: zero target

    Terms memory terms = _makeTermsWithAssets(assets);

    vm.expectRevert(TermsLib.InvalidERC1155Asset.selector);
    harness.exposed_validateAssets(terms);
  }

  // ============ Fuzz Tests ============

  function testFuzz_validateAssets_validNativeAssets(uint8 count, uint256 seed) public view {
    count = uint8(bound(count, 1, 10));
    Asset[] memory assets = new Asset[](count);

    for (uint256 i = 0; i < count; i++) {
      uint256 amount = uint256(keccak256(abi.encode(seed, i))) % 10 ether + 1;
      assets[i] = _makeNativeAsset(amount);
    }

    Terms memory terms = _makeTermsWithAssets(assets);
    harness.exposed_validateAssets(terms);
  }
}
