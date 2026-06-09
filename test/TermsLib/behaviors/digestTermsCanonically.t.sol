// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Terms} from '../../../src/TermsLib.sol';
import {AssetHelper} from '../../utils/AssetHelper.sol';
import {TermsHelper} from '../../utils/TermsHelper.sol';
import {TermsLibTest} from '../TermsLib.t.sol';

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
      DEFAULT_COMMITMENT_DEADLINE,
      DEFAULT_CLAIM_DEADLINE,
      DEFAULT_RECLAIM_RELEASE,
      _makeNativeAsset(1 ether).toArray()
    );
  }

  function _bobTerms() internal view returns (Terms memory) {
    return TermsHelper.makeTerms(
      block.chainid,
      BOB,
      BOB_RECIPIENT,
      DEFAULT_COMMITMENT_DEADLINE,
      DEFAULT_CLAIM_DEADLINE,
      DEFAULT_RECLAIM_RELEASE,
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
      DEFAULT_COMMITMENT_DEADLINE,
      DEFAULT_CLAIM_DEADLINE,
      DEFAULT_RECLAIM_RELEASE,
      _makeERC20Asset(2 ether).toArray() // Different assets
    );

    bytes32 hash1 = harness.exposed_digestTermsCanonically(alice, bob);
    bytes32 hash2 = harness.exposed_digestTermsCanonically(alice, bobModified);

    assertNotEq(hash1, hash2);
  }

  /// @dev every field that feeds digestTerms must perturb the canonical digest;
  ///      one assertion per Terms field (assets covered separately below)
  function test_digestTermsCanonically_includesAllFields() public view {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    bytes32 originalHash = harness.exposed_digestTermsCanonically(alice, bob);

    // Change chainId
    Terms memory aliceChainId = alice;
    aliceChainId.chainId = 999;
    assertNotEq(harness.exposed_digestTermsCanonically(aliceChainId, bob), originalHash);

    // Change reclaimRecipient
    Terms memory aliceReclaimRecipient = alice;
    aliceReclaimRecipient.reclaimRecipient = BOB;
    assertNotEq(harness.exposed_digestTermsCanonically(aliceReclaimRecipient, bob), originalHash);

    // Change recipient
    Terms memory aliceRecipient = alice;
    aliceRecipient.recipient = BOB_RECIPIENT;
    assertNotEq(harness.exposed_digestTermsCanonically(aliceRecipient, bob), originalHash);

    // Change commitmentDeadline
    Terms memory aliceCommitment = alice;
    aliceCommitment.commitmentDeadline = DEFAULT_COMMITMENT_DEADLINE + 1;
    assertNotEq(harness.exposed_digestTermsCanonically(aliceCommitment, bob), originalHash);

    // Change claimDeadline
    Terms memory aliceClaim = alice;
    aliceClaim.claimDeadline = DEFAULT_CLAIM_DEADLINE + 1;
    assertNotEq(harness.exposed_digestTermsCanonically(aliceClaim, bob), originalHash);

    // Change reclaimRelease
    Terms memory aliceReclaim = alice;
    aliceReclaim.reclaimRelease = DEFAULT_RECLAIM_RELEASE + 1;
    assertNotEq(harness.exposed_digestTermsCanonically(aliceReclaim, bob), originalHash);

    // Change assets
    Terms memory aliceAssets = alice;
    aliceAssets.assets = _makeNativeAsset(2 ether).toArray();
    assertNotEq(harness.exposed_digestTermsCanonically(aliceAssets, bob), originalHash);
  }

  // ============ Fuzz Tests ============

  function testFuzz_digestTermsCanonically_orderIndependent(
    uint256 chainId1,
    uint256 chainId2,
    uint256 commitment1,
    uint256 commitment2,
    uint256 amount1,
    uint256 amount2
  ) public view {
    chainId1 = bound(chainId1, 1, type(uint64).max);
    chainId2 = bound(chainId2, 1, type(uint64).max);
    commitment1 = bound(commitment1, 1, type(uint64).max);
    commitment2 = bound(commitment2, 1, type(uint64).max);
    amount1 = bound(amount1, 1, type(uint128).max);
    amount2 = bound(amount2, 1, type(uint128).max);

    Terms memory terms1 = TermsHelper.makeTerms(
      chainId1,
      ALICE,
      ALICE_RECIPIENT,
      commitment1,
      DEFAULT_CLAIM_DEADLINE,
      DEFAULT_RECLAIM_RELEASE,
      _makeNativeAsset(amount1).toArray()
    );

    Terms memory terms2 = TermsHelper.makeTerms(
      chainId2,
      BOB,
      BOB_RECIPIENT,
      commitment2,
      DEFAULT_CLAIM_DEADLINE,
      DEFAULT_RECLAIM_RELEASE,
      _makeNativeAsset(amount2).toArray()
    );

    bytes32 hash1 = harness.exposed_digestTermsCanonically(terms1, terms2);
    bytes32 hash2 = harness.exposed_digestTermsCanonically(terms2, terms1);

    assertEq(hash1, hash2);
  }
}
