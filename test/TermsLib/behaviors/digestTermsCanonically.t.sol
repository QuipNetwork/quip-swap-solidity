// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Terms} from '../../../src/TermsLib.sol';
import {TermsLibTest} from '../TermsLib.t.sol';
import {AssetHelper} from '../../utils/AssetHelper.sol';
import {TermsHelper} from '../../utils/TermsHelper.sol';

/// @title TermsLib digestTermsCanonically Tests
/// @dev Tests for TermsLib.digestTermsCanonically
contract TermsLib_digestTermsCanonically is TermsLibTest {
  using AssetHelper for *;
  using TermsHelper for *;

  // ============ Helpers ============

  function _aliceTerms() internal view returns (Terms memory) {
    return TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      DEFAULT_DEADLINE,
      _makeNativeAsset(1 ether).toArray()
    );
  }

  function _bobTerms() internal view returns (Terms memory) {
    return TermsHelper.makeTerms(
      block.chainid,
      BOB,
      BOB_RECIPIENT,
      DEFAULT_DEADLINE,
      _makeERC20Asset(1 ether).toArray()
    );
  }

  // ============ Success Cases ============

  function test_digestTermsCanonically_returnsConsistentHash() public view {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    bytes32 hash1 = harness.exposed_digestTermsCanonically(alice, bob);
    bytes32 hash2 = harness.exposed_digestTermsCanonically(alice, bob);

    assertEq(hash1, hash2);
  }

  function test_digestTermsCanonically_orderIndependent() public view {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    // Same hash regardless of party/counterparty order
    bytes32 hashAliceBob = harness.exposed_digestTermsCanonically(alice, bob);
    bytes32 hashBobAlice = harness.exposed_digestTermsCanonically(bob, alice);

    assertEq(hashAliceBob, hashBobAlice);
  }

  function test_digestTermsCanonically_differentTermsDifferentHash() public view {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    // Different bob terms
    Terms memory bobModified = TermsHelper.makeTerms(
      block.chainid,
      BOB,
      BOB_RECIPIENT,
      DEFAULT_DEADLINE,
      _makeERC20Asset(2 ether).toArray() // Different assets
    );

    bytes32 hash1 = harness.exposed_digestTermsCanonically(alice, bob);
    bytes32 hash2 = harness.exposed_digestTermsCanonically(alice, bobModified);

    assertNotEq(hash1, hash2);
  }

  function test_digestTermsCanonically_includesAllFields() public view {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    bytes32 originalHash = harness.exposed_digestTermsCanonically(alice, bob);

    // Change chainId
    Terms memory aliceChainId = TermsHelper.makeTerms(
      999, ALICE, ALICE_RECIPIENT, DEFAULT_DEADLINE, _makeNativeAsset(1 ether).toArray()
    );
    assertNotEq(harness.exposed_digestTermsCanonically(aliceChainId, bob), originalHash);

    // Change signatory
    Terms memory aliceSignatory = TermsHelper.makeTerms(
      block.chainid,
      BOB, // Different signatory
      ALICE_RECIPIENT,
      DEFAULT_DEADLINE,
      _makeNativeAsset(1 ether).toArray()
    );
    assertNotEq(harness.exposed_digestTermsCanonically(aliceSignatory, bob), originalHash);

    // Change recipient
    Terms memory aliceRecipient = TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      BOB_RECIPIENT, // Different recipient
      DEFAULT_DEADLINE,
      _makeNativeAsset(1 ether).toArray()
    );
    assertNotEq(harness.exposed_digestTermsCanonically(aliceRecipient, bob), originalHash);

    // Change deadline
    Terms memory aliceDeadline = TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      DEFAULT_DEADLINE + 1, // Different deadline
      _makeNativeAsset(1 ether).toArray()
    );
    assertNotEq(harness.exposed_digestTermsCanonically(aliceDeadline, bob), originalHash);

    // Change assets
    Terms memory aliceAssets = TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      DEFAULT_DEADLINE,
      _makeNativeAsset(2 ether).toArray() // Different assets
    );
    assertNotEq(harness.exposed_digestTermsCanonically(aliceAssets, bob), originalHash);
  }

  // ============ Fuzz Tests ============

  function testFuzz_digestTermsCanonically_orderIndependent(
    uint256 chainId1,
    uint256 chainId2,
    uint64 deadline1,
    uint64 deadline2,
    uint256 amount1,
    uint256 amount2
  ) public view {
    chainId1 = bound(chainId1, 1, type(uint64).max);
    chainId2 = bound(chainId2, 1, type(uint64).max);
    deadline1 = uint64(bound(deadline1, 1, type(uint64).max));
    deadline2 = uint64(bound(deadline2, 1, type(uint64).max));
    amount1 = bound(amount1, 1, type(uint128).max);
    amount2 = bound(amount2, 1, type(uint128).max);

    Terms memory terms1 = TermsHelper.makeTerms(
      chainId1, ALICE, ALICE_RECIPIENT, deadline1, _makeNativeAsset(amount1).toArray()
    );

    Terms memory terms2 = TermsHelper.makeTerms(
      chainId2, BOB, BOB_RECIPIENT, deadline2, _makeNativeAsset(amount2).toArray()
    );

    bytes32 hash1 = harness.exposed_digestTermsCanonically(terms1, terms2);
    bytes32 hash2 = harness.exposed_digestTermsCanonically(terms2, terms1);

    assertEq(hash1, hash2);
  }
}
