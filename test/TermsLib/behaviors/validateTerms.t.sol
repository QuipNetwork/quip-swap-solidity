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

  function _validPartyTerms() internal view returns (Terms memory) {
    return TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      uint64(block.timestamp + 1 days),
      _makeNativeAsset(0.1 ether),
      _makeNativeAsset(1 ether).toArray()
    );
  }

  function _validCounterpartyTerms() internal view returns (Terms memory) {
    return TermsHelper.makeTerms(
      block.chainid,
      BOB,
      BOB_RECIPIENT,
      uint64(block.timestamp + 1 days),
      _makeNativeAsset(0.1 ether),
      _makeERC20Asset(1 ether).toArray()
    );
  }

  // ============ Success Cases ============

  function test_validateTerms_sameChainValid() public view {
    Terms memory party = _validPartyTerms();
    Terms memory counterparty = _validCounterpartyTerms();

    harness.exposed_validateTerms(party, counterparty);
  }

  function test_validateTerms_crossChainValid() public view {
    Terms memory party = _validPartyTerms();
    Terms memory counterparty = TermsHelper.makeTerms(
      OTHER_CHAIN_ID, // Different chain
      BOB,
      BOB_RECIPIENT,
      uint64(block.timestamp + 1 days),
      _makeNativeAsset(0.1 ether),
      _makeERC20Asset(1 ether).toArray()
    );

    // Should succeed - counterparty chainId not enforced
    harness.exposed_validateTerms(party, counterparty);
  }

  // ============ Revert Cases ============

  function test_validateTerms_revertsWhen_partyChainMismatch() public {
    Terms memory party = TermsHelper.makeTerms(
      OTHER_CHAIN_ID, // Wrong chain
      ALICE,
      ALICE_RECIPIENT,
      uint64(block.timestamp + 1 days),
      _makeNativeAsset(0.1 ether),
      _makeNativeAsset(1 ether).toArray()
    );
    Terms memory counterparty = _validCounterpartyTerms();

    vm.expectRevert(TermsLib.InvalidChainId.selector);
    harness.exposed_validateTerms(party, counterparty);
  }

  function test_validateTerms_revertsWhen_partyChainIdZero() public {
    Terms memory party = TermsHelper.makeTerms(
      0, // Zero chainId - invalid
      ALICE,
      ALICE_RECIPIENT,
      uint64(block.timestamp + 1 days),
      _makeNativeAsset(0.1 ether),
      _makeNativeAsset(1 ether).toArray()
    );
    Terms memory counterparty = _validCounterpartyTerms();

    // First check fails (party.chainId != block.chainid)
    vm.expectRevert(TermsLib.InvalidChainId.selector);
    harness.exposed_validateTerms(party, counterparty);
  }

  function test_validateTerms_revertsWhen_counterpartyChainIdZero() public {
    Terms memory party = _validPartyTerms();
    Terms memory counterparty = TermsHelper.makeTerms(
      0, // Zero chainId - invalid
      BOB,
      BOB_RECIPIENT,
      uint64(block.timestamp + 1 days),
      _makeNativeAsset(0.1 ether),
      _makeERC20Asset(1 ether).toArray()
    );

    vm.expectRevert(TermsLib.InvalidChainId.selector);
    harness.exposed_validateTerms(party, counterparty);
  }

  function test_validateTerms_revertsWhen_partyExpired() public {
    Terms memory party = TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      uint64(block.timestamp - 1), // Expired
      _makeNativeAsset(0.1 ether),
      _makeNativeAsset(1 ether).toArray()
    );
    Terms memory counterparty = _validCounterpartyTerms();

    vm.expectRevert(TermsLib.TermsExpired.selector);
    harness.exposed_validateTerms(party, counterparty);
  }

  function test_validateTerms_revertsWhen_counterpartyExpired() public {
    Terms memory party = _validPartyTerms();
    Terms memory counterparty = TermsHelper.makeTerms(
      block.chainid,
      BOB,
      BOB_RECIPIENT,
      uint64(block.timestamp - 1), // Expired
      _makeNativeAsset(0.1 ether),
      _makeERC20Asset(1 ether).toArray()
    );

    vm.expectRevert(TermsLib.TermsExpired.selector);
    harness.exposed_validateTerms(party, counterparty);
  }

  function test_validateTerms_revertsWhen_invalidCollateral() public {
    // Zero amount collateral
    Asset memory invalidCollateral = Asset({assetType: AssetType.Native, target: address(0), id: 0, amount: 0});

    Terms memory party = TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      uint64(block.timestamp + 1 days),
      invalidCollateral,
      _makeNativeAsset(1 ether).toArray()
    );
    Terms memory counterparty = _validCounterpartyTerms();

    vm.expectRevert(TermsLib.ZeroAmount.selector);
    harness.exposed_validateTerms(party, counterparty);
  }

  function test_validateTerms_revertsWhen_invalidAsset() public {
    // Zero amount asset
    Asset[] memory invalidAssets = new Asset[](1);
    invalidAssets[0] = Asset({assetType: AssetType.Native, target: address(0), id: 0, amount: 0});

    Terms memory party = TermsHelper.makeTerms(
      block.chainid, ALICE, ALICE_RECIPIENT, uint64(block.timestamp + 1 days), _makeNativeAsset(0.1 ether), invalidAssets
    );
    Terms memory counterparty = _validCounterpartyTerms();

    vm.expectRevert(TermsLib.ZeroAmount.selector);
    harness.exposed_validateTerms(party, counterparty);
  }

  function test_validateTerms_revertsWhen_counterpartyInvalidCollateral() public {
    Terms memory party = _validPartyTerms();

    // Counterparty has invalid collateral
    Asset memory invalidCollateral = Asset({assetType: AssetType.Native, target: address(0), id: 0, amount: 0});

    Terms memory counterparty = TermsHelper.makeTerms(
      block.chainid,
      BOB,
      BOB_RECIPIENT,
      uint64(block.timestamp + 1 days),
      invalidCollateral,
      _makeERC20Asset(1 ether).toArray()
    );

    vm.expectRevert(TermsLib.ZeroAmount.selector);
    harness.exposed_validateTerms(party, counterparty);
  }

  function test_validateTerms_revertsWhen_counterpartyInvalidAsset() public {
    Terms memory party = _validPartyTerms();

    // Counterparty has invalid asset
    Asset[] memory invalidAssets = new Asset[](1);
    invalidAssets[0] = Asset({assetType: AssetType.Native, target: address(0), id: 0, amount: 0});

    Terms memory counterparty = TermsHelper.makeTerms(
      block.chainid, BOB, BOB_RECIPIENT, uint64(block.timestamp + 1 days), _makeNativeAsset(0.1 ether), invalidAssets
    );

    vm.expectRevert(TermsLib.ZeroAmount.selector);
    harness.exposed_validateTerms(party, counterparty);
  }

  // ============ Edge Cases ============

  function test_validateTerms_validWithMixedAssetTypes() public view {
    Asset[] memory mixedAssets = new Asset[](4);
    mixedAssets[0] = _makeNativeAsset(1 ether);
    mixedAssets[1] = _makeERC20Asset(100 ether);
    mixedAssets[2] = _makeERC721Asset(1);
    mixedAssets[3] = _makeERC1155Asset(1, 50);

    Terms memory party = TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      uint64(block.timestamp + 1 days),
      _makeNativeAsset(0.1 ether),
      mixedAssets
    );
    Terms memory counterparty = _validCounterpartyTerms();

    harness.exposed_validateTerms(party, counterparty);
  }
}
