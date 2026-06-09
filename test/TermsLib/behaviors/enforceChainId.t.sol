// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Terms, TermsLib} from '../../../src/TermsLib.sol';
import {AssetHelper} from '../../utils/AssetHelper.sol';
import {TermsHelper} from '../../utils/TermsHelper.sol';
import {TermsLibTest} from '../TermsLib.t.sol';

/// @title TermsLib enforceChainId Tests
/// @dev Tests for TermsLib.enforceChainId
contract TermsLib_enforceChainId is TermsLibTest {
  using AssetHelper for *;
  using TermsHelper for *;

  // ============ Constants ============

  uint256 constant OTHER_CHAIN_ID = 999;

  // ============ Success Cases ============

  function test_enforceChainId_succeedsWhenMatches() public view {
    Terms memory terms = TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      DEFAULT_COMMITMENT_DEADLINE,
      DEFAULT_CLAIM_DEADLINE,
      DEFAULT_RECLAIM_RELEASE,
      _makeNativeAsset(1 ether).toArray()
    );

    harness.exposed_enforceChainId(terms, block.chainid);
  }

  function test_enforceChainId_succeedsWithAnyMatchingChainId() public view {
    Terms memory terms = TermsHelper.makeTerms(
      OTHER_CHAIN_ID,
      ALICE,
      ALICE_RECIPIENT,
      DEFAULT_COMMITMENT_DEADLINE,
      DEFAULT_CLAIM_DEADLINE,
      DEFAULT_RECLAIM_RELEASE,
      _makeNativeAsset(1 ether).toArray()
    );

    harness.exposed_enforceChainId(terms, OTHER_CHAIN_ID);
  }

  // ============ Revert Cases ============

  function test_enforceChainId_revertsWhen_chainMismatch() public {
    Terms memory terms = TermsHelper.makeTerms(
      OTHER_CHAIN_ID,
      ALICE,
      ALICE_RECIPIENT,
      DEFAULT_COMMITMENT_DEADLINE,
      DEFAULT_CLAIM_DEADLINE,
      DEFAULT_RECLAIM_RELEASE,
      _makeNativeAsset(1 ether).toArray()
    );

    vm.expectRevert(TermsLib.ChainIdMismatch.selector);
    harness.exposed_enforceChainId(terms, block.chainid);
  }

  function test_enforceChainId_revertsWhen_expectedZero() public {
    Terms memory terms = TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      DEFAULT_COMMITMENT_DEADLINE,
      DEFAULT_CLAIM_DEADLINE,
      DEFAULT_RECLAIM_RELEASE,
      _makeNativeAsset(1 ether).toArray()
    );

    vm.expectRevert(TermsLib.ChainIdMismatch.selector);
    harness.exposed_enforceChainId(terms, 0);
  }

  // ============ Fuzz Tests ============

  function testFuzz_enforceChainId_succeedsWhenMatches(uint256 chainId) public view {
    vm.assume(chainId != 0);

    Terms memory terms = TermsHelper.makeTerms(
      chainId,
      ALICE,
      ALICE_RECIPIENT,
      DEFAULT_COMMITMENT_DEADLINE,
      DEFAULT_CLAIM_DEADLINE,
      DEFAULT_RECLAIM_RELEASE,
      _makeNativeAsset(1 ether).toArray()
    );

    harness.exposed_enforceChainId(terms, chainId);
  }

  function testFuzz_enforceChainId_revertsWhenMismatch(uint256 termsChainId, uint256 expectedChainId) public {
    vm.assume(termsChainId != expectedChainId);

    Terms memory terms = TermsHelper.makeTerms(
      termsChainId,
      ALICE,
      ALICE_RECIPIENT,
      DEFAULT_COMMITMENT_DEADLINE,
      DEFAULT_CLAIM_DEADLINE,
      DEFAULT_RECLAIM_RELEASE,
      _makeNativeAsset(1 ether).toArray()
    );

    vm.expectRevert(TermsLib.ChainIdMismatch.selector);
    harness.exposed_enforceChainId(terms, expectedChainId);
  }
}
