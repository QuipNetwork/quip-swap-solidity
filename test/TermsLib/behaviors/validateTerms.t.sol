// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Terms, TermsLib} from '../../../src/legacy/TermsLib.sol';
import {Asset, AssetType} from '../../../src/protocol/ProtocolTypes.sol';
import {AssetHelper} from '../../utils/AssetHelper.sol';
import {TermsHelper} from '../../utils/TermsHelper.sol';
import {TermsLibTest} from '../TermsLib.t.sol';

/// @title TermsLib validateTerms Tests
/// @dev Tests for TermsLib.validateTerms
contract TermsLib_validateTerms is TermsLibTest {
  using AssetHelper for *;
  using TermsHelper for *;

  // ============ Constants ============

  uint256 constant OTHER_CHAIN_ID = 999;

  // ============ Helpers ============

  function _validTerms() internal view returns (Terms memory) {
    return TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      DEFAULT_COMMITMENT_DEADLINE,
      DEFAULT_CLAIM_DEADLINE,
      DEFAULT_RECLAIM_RELEASE,
      _makeNativeAsset(1 ether).toArray()
    );
  }

  // ============ Success Cases ============

  function test_validateTerms_validTerms() public view {
    Terms memory terms = _validTerms();
    harness.exposed_validateTerms(terms);
  }

  function test_validateTerms_validWithDifferentChain() public view {
    Terms memory terms = TermsHelper.makeTerms(
      OTHER_CHAIN_ID,
      BOB,
      BOB_RECIPIENT,
      DEFAULT_COMMITMENT_DEADLINE,
      DEFAULT_CLAIM_DEADLINE,
      DEFAULT_RECLAIM_RELEASE,
      _makeERC20Asset(1 ether).toArray()
    );

    // Should succeed - validateTerms only checks non-zero chainId
    harness.exposed_validateTerms(terms);
  }

  function test_validateTerms_validWithMixedAssetTypes() public view {
    Asset[] memory mixedAssets = new Asset[](4);
    mixedAssets[0] = _makeNativeAsset(1 ether);
    mixedAssets[1] = _makeERC20Asset(100 ether);
    mixedAssets[2] = _makeERC721Asset(1);
    mixedAssets[3] = _makeERC1155Asset(1, 50);

    Terms memory terms = TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      DEFAULT_COMMITMENT_DEADLINE,
      DEFAULT_CLAIM_DEADLINE,
      DEFAULT_RECLAIM_RELEASE,
      mixedAssets
    );

    harness.exposed_validateTerms(terms);
  }

  // ============ Revert Cases ============

  function test_validateTerms_revertsWhen_emptyAssets() public {
    Asset[] memory emptyAssets = new Asset[](0);

    Terms memory terms = TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      DEFAULT_COMMITMENT_DEADLINE,
      DEFAULT_CLAIM_DEADLINE,
      DEFAULT_RECLAIM_RELEASE,
      emptyAssets
    );

    vm.expectRevert(TermsLib.EmptyAssets.selector);
    harness.exposed_validateTerms(terms);
  }

  function test_validateTerms_revertsWhen_zeroReclaimRecipient() public {
    Terms memory terms = TermsHelper.makeTerms(
      block.chainid,
      address(0), // zero reclaimRecipient - invalid
      ALICE_RECIPIENT,
      DEFAULT_COMMITMENT_DEADLINE,
      DEFAULT_CLAIM_DEADLINE,
      DEFAULT_RECLAIM_RELEASE,
      _makeNativeAsset(1 ether).toArray()
    );

    vm.expectRevert(TermsLib.ZeroAddressRecipient.selector);
    harness.exposed_validateTerms(terms);
  }

  function test_validateTerms_revertsWhen_zeroRecipient() public {
    Terms memory terms = TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      address(0), // zero recipient - invalid
      DEFAULT_COMMITMENT_DEADLINE,
      DEFAULT_CLAIM_DEADLINE,
      DEFAULT_RECLAIM_RELEASE,
      _makeNativeAsset(1 ether).toArray()
    );

    vm.expectRevert(TermsLib.ZeroAddressRecipient.selector);
    harness.exposed_validateTerms(terms);
  }

  // ============ Deadline Ordering ============

  function test_validateTerms_revertsWhen_commitmentEqualsClaim() public {
    Terms memory terms = TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      DEFAULT_CLAIM_DEADLINE, // commitment == claim breaks strict ordering
      DEFAULT_CLAIM_DEADLINE,
      DEFAULT_RECLAIM_RELEASE,
      _makeNativeAsset(1 ether).toArray()
    );

    vm.expectRevert(TermsLib.DisordedDeadlines.selector);
    harness.exposed_validateTerms(terms);
  }

  function test_validateTerms_revertsWhen_commitmentAfterClaim() public {
    Terms memory terms = TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      DEFAULT_CLAIM_DEADLINE + 1, // commitment > claim
      DEFAULT_CLAIM_DEADLINE,
      DEFAULT_RECLAIM_RELEASE,
      _makeNativeAsset(1 ether).toArray()
    );

    vm.expectRevert(TermsLib.DisordedDeadlines.selector);
    harness.exposed_validateTerms(terms);
  }

  function test_validateTerms_revertsWhen_claimEqualsReclaim() public {
    Terms memory terms = TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      DEFAULT_COMMITMENT_DEADLINE,
      DEFAULT_RECLAIM_RELEASE, // claim == reclaim breaks strict ordering
      DEFAULT_RECLAIM_RELEASE,
      _makeNativeAsset(1 ether).toArray()
    );

    vm.expectRevert(TermsLib.DisordedDeadlines.selector);
    harness.exposed_validateTerms(terms);
  }

  function test_validateTerms_revertsWhen_claimAfterReclaim() public {
    Terms memory terms = TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      DEFAULT_COMMITMENT_DEADLINE,
      DEFAULT_RECLAIM_RELEASE + 1, // claim > reclaim
      DEFAULT_RECLAIM_RELEASE,
      _makeNativeAsset(1 ether).toArray()
    );

    vm.expectRevert(TermsLib.DisordedDeadlines.selector);
    harness.exposed_validateTerms(terms);
  }

  // ============ Deadline Non-Zero ============
  // validateTerms only sanity-checks deadlines as non-zero; per-action freshness is enforced
  // by the commit/claim/reclaim windows, NOT here (see validateTerms NatSpec)

  function test_validateTerms_revertsWhen_commitmentDeadlineZero() public {
    Terms memory terms = TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      0, // zero commitment deadline - invalid
      DEFAULT_CLAIM_DEADLINE,
      DEFAULT_RECLAIM_RELEASE,
      _makeNativeAsset(1 ether).toArray()
    );

    vm.expectRevert(TermsLib.ZeroDeadline.selector);
    harness.exposed_validateTerms(terms);
  }

  function test_validateTerms_succeedsWhen_deadlinesElapsedButNonZero() public {
    // an elapsed (past) commitment deadline still validates: freshness is not checked here.
    // this is the case the taker hits when committing after the proposer's commit deadline
    vm.warp(DEFAULT_RECLAIM_RELEASE + 1);
    harness.exposed_validateTerms(_validTerms());
  }

  function test_validateTerms_revertsWhen_chainIdZero() public {
    Terms memory terms = TermsHelper.makeTerms(
      0, // Zero chainId - invalid
      ALICE,
      ALICE_RECIPIENT,
      DEFAULT_COMMITMENT_DEADLINE,
      DEFAULT_CLAIM_DEADLINE,
      DEFAULT_RECLAIM_RELEASE,
      _makeNativeAsset(1 ether).toArray()
    );

    vm.expectRevert(TermsLib.ZeroChainId.selector);
    harness.exposed_validateTerms(terms);
  }

  function test_validateTerms_revertsWhen_invalidAssetZeroAmount() public {
    Asset[] memory invalidAssets = new Asset[](1);
    invalidAssets[0] = Asset({assetType: AssetType.Native, target: address(0), id: 0, amount: 0});

    Terms memory terms = TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      DEFAULT_COMMITMENT_DEADLINE,
      DEFAULT_CLAIM_DEADLINE,
      DEFAULT_RECLAIM_RELEASE,
      invalidAssets
    );

    vm.expectRevert(TermsLib.ZeroAmount.selector);
    harness.exposed_validateTerms(terms);
  }

  function test_validateTerms_revertsWhen_invalidNativeAsset() public {
    Asset[] memory invalidAssets = new Asset[](1);
    invalidAssets[0] = Asset({assetType: AssetType.Native, target: address(1), id: 0, amount: 1 ether});

    Terms memory terms = TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      DEFAULT_COMMITMENT_DEADLINE,
      DEFAULT_CLAIM_DEADLINE,
      DEFAULT_RECLAIM_RELEASE,
      invalidAssets
    );

    vm.expectRevert(TermsLib.InvalidNativeAsset.selector);
    harness.exposed_validateTerms(terms);
  }

  function test_validateTerms_revertsWhen_invalidERC20Asset() public {
    Asset[] memory invalidAssets = new Asset[](1);
    invalidAssets[0] = Asset({assetType: AssetType.ERC20, target: address(0), id: 0, amount: 1 ether});

    Terms memory terms = TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      DEFAULT_COMMITMENT_DEADLINE,
      DEFAULT_CLAIM_DEADLINE,
      DEFAULT_RECLAIM_RELEASE,
      invalidAssets
    );

    vm.expectRevert(TermsLib.InvalidERC20Asset.selector);
    harness.exposed_validateTerms(terms);
  }
}
