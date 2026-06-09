// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Terms, TermsLib} from '../../../src/TermsLib.sol';
import {AssetHelper} from '../../utils/AssetHelper.sol';
import {TermsHelper} from '../../utils/TermsHelper.sol';
import {TermsLibTest} from '../TermsLib.t.sol';

/// @title TermsLib enforceNonZeroChainId Tests
/// @dev Tests for TermsLib.enforceNonZeroChainId
contract TermsLib_enforceNonZeroChainId is TermsLibTest {
  using AssetHelper for *;
  using TermsHelper for *;

  // ============ Success Cases ============

  function test_enforceNonZeroChainId_succeeds() public view {
    Terms memory terms = TermsHelper.makeTerms(
      block.chainid, // Non-zero chainId
      ALICE,
      ALICE_RECIPIENT,
      DEFAULT_COMMITMENT_DEADLINE,
      DEFAULT_CLAIM_DEADLINE,
      DEFAULT_RECLAIM_RELEASE,
      _makeNativeAsset(1 ether).toArray()
    );

    // Should not revert
    harness.exposed_enforceNonZeroChainId(terms);
  }

  function test_enforceNonZeroChainId_withChainIdOne() public view {
    Terms memory terms = TermsHelper.makeTerms(
      1, // Ethereum mainnet
      ALICE,
      ALICE_RECIPIENT,
      DEFAULT_COMMITMENT_DEADLINE,
      DEFAULT_CLAIM_DEADLINE,
      DEFAULT_RECLAIM_RELEASE,
      _makeNativeAsset(1 ether).toArray()
    );

    // Should not revert
    harness.exposed_enforceNonZeroChainId(terms);
  }

  function test_enforceNonZeroChainId_withLargeChainId() public view {
    Terms memory terms = TermsHelper.makeTerms(
      type(uint256).max, // Max chainId
      ALICE,
      ALICE_RECIPIENT,
      DEFAULT_COMMITMENT_DEADLINE,
      DEFAULT_CLAIM_DEADLINE,
      DEFAULT_RECLAIM_RELEASE,
      _makeNativeAsset(1 ether).toArray()
    );

    // Should not revert
    harness.exposed_enforceNonZeroChainId(terms);
  }

  // ============ Revert Cases ============

  function test_enforceNonZeroChainId_revertsWhen_chainIdZero() public {
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
    harness.exposed_enforceNonZeroChainId(terms);
  }

  // ============ Fuzz Tests ============

  function testFuzz_enforceNonZeroChainId_succeedsWithNonZero(uint256 chainId) public view {
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

    // Should not revert for any non-zero chainId
    harness.exposed_enforceNonZeroChainId(terms);
  }
}
