// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Terms} from '../../../src/TermsLib.sol';
import {TermsLibTest} from '../TermsLib.t.sol';
import {AssetHelper} from '../../utils/AssetHelper.sol';
import {TermsHelper} from '../../utils/TermsHelper.sol';

/// @title TermsLib digestTerms Tests
/// @dev Tests for TermsLib.digestTerms — the per-side digest. Every field that the canonical
///      pairing and posted-tracking rely on must be bound into the hash.
contract TermsLib_digestTerms is TermsLibTest {
  using AssetHelper for *;
  using TermsHelper for *;

  // ============ Helpers ============

  function _terms() internal view returns (Terms memory) {
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

  function test_digestTerms_isDeterministic() public view {
    Terms memory terms = _terms();
    assertEq(harness.exposed_digestTerms(terms), harness.exposed_digestTerms(terms));
  }

  function test_digestTerms_equalForEquivalentTerms() public view {
    // independently constructed but field-identical terms hash equally
    assertEq(harness.exposed_digestTerms(_terms()), harness.exposed_digestTerms(_terms()));
  }

  // ============ Field Binding ============

  function test_digestTerms_bindsChainId() public view {
    Terms memory base = _terms();
    bytes32 original = harness.exposed_digestTerms(base);
    base.chainId = 999;
    assertNotEq(harness.exposed_digestTerms(base), original);
  }

  function test_digestTerms_bindsReclaimRecipient() public view {
    Terms memory base = _terms();
    bytes32 original = harness.exposed_digestTerms(base);
    base.reclaimRecipient = BOB;
    assertNotEq(harness.exposed_digestTerms(base), original);
  }

  function test_digestTerms_bindsRecipient() public view {
    Terms memory base = _terms();
    bytes32 original = harness.exposed_digestTerms(base);
    base.recipient = BOB_RECIPIENT;
    assertNotEq(harness.exposed_digestTerms(base), original);
  }

  function test_digestTerms_bindsCommitmentDeadline() public view {
    Terms memory base = _terms();
    bytes32 original = harness.exposed_digestTerms(base);
    base.commitmentDeadline = DEFAULT_COMMITMENT_DEADLINE + 1;
    assertNotEq(harness.exposed_digestTerms(base), original);
  }

  function test_digestTerms_bindsClaimDeadline() public view {
    Terms memory base = _terms();
    bytes32 original = harness.exposed_digestTerms(base);
    base.claimDeadline = DEFAULT_CLAIM_DEADLINE + 1;
    assertNotEq(harness.exposed_digestTerms(base), original);
  }

  function test_digestTerms_bindsReclaimRelease() public view {
    Terms memory base = _terms();
    bytes32 original = harness.exposed_digestTerms(base);
    base.reclaimRelease = DEFAULT_RECLAIM_RELEASE + 1;
    assertNotEq(harness.exposed_digestTerms(base), original);
  }

  function test_digestTerms_bindsAssets() public view {
    Terms memory base = _terms();
    bytes32 original = harness.exposed_digestTerms(base);
    base.assets = _makeNativeAsset(2 ether).toArray();
    assertNotEq(harness.exposed_digestTerms(base), original);
  }

  function test_digestTerms_bindsAssetCount() public view {
    Terms memory base = _terms();
    bytes32 original = harness.exposed_digestTerms(base);
    base.assets = AssetHelper.toArray(_makeNativeAsset(1 ether), _makeNativeAsset(1 ether));
    assertNotEq(harness.exposed_digestTerms(base), original);
  }

  // ============ Fuzz Tests ============

  function testFuzz_digestTerms_distinctCommitmentsDistinctDigests(
    uint256 commitmentA,
    uint256 commitmentB
  ) public view {
    vm.assume(commitmentA != commitmentB);
    Terms memory a = _terms();
    Terms memory b = _terms();
    a.commitmentDeadline = commitmentA;
    b.commitmentDeadline = commitmentB;
    assertNotEq(harness.exposed_digestTerms(a), harness.exposed_digestTerms(b));
  }
}
