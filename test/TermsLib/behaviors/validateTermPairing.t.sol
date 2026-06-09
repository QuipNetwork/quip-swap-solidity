// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Terms, TermsLib} from '../../../src/TermsLib.sol';
import {TermsLibTest} from '../TermsLib.t.sol';
import {AssetHelper} from '../../utils/AssetHelper.sol';
import {TermsHelper} from '../../utils/TermsHelper.sol';

/// @title TermsLib validateTermPairing Tests
/// @dev Tests for TermsLib.validateTermPairing — enforces that the two sides' lifecycle
///      deadlines strictly interleave. Valid (A proposes):
///      A.commit < B.commit < A.claim < B.claim < A.reclaim < B.reclaim,
///      or the same chain with the sides swapped (B proposes).
contract TermsLib_validateTermPairing is TermsLibTest {
  using AssetHelper for *;
  using TermsHelper for *;

  // ============ Helpers ============

  /// @notice builds a side with explicit lifecycle deadlines (other fields are irrelevant
  ///         to validateTermPairing, which reads only the three deadline fields)
  function _side(uint256 commitment, uint256 claim, uint256 reclaim) internal view returns (Terms memory) {
    return TermsHelper.makeTerms(
      block.chainid, ALICE, ALICE_RECIPIENT, commitment, claim, reclaim, _makeNativeAsset(1 ether).toArray()
    );
  }

  // proposer P interleaves strictly ahead of taker T at every stage:
  // P.commit(100) < T.commit(200) < P.claim(300) < T.claim(400) < P.reclaim(500) < T.reclaim(600)
  function _proposer() internal view returns (Terms memory) {
    return _side(100, 300, 500);
  }

  function _taker() internal view returns (Terms memory) {
    return _side(200, 400, 600);
  }

  // ============ Success Cases ============

  function test_validateTermPairing_succeedsWhen_aProposes() public view {
    // first argument is the proposer: matches the aProposes branch
    harness.exposed_validateTermPairing(_proposer(), _taker());
  }

  function test_validateTermPairing_succeedsWhen_bProposes() public view {
    // same pairing, sides swapped: matches the bProposes branch
    harness.exposed_validateTermPairing(_taker(), _proposer());
  }

  // ============ Revert Cases ============

  function test_validateTermPairing_revertsWhen_equalCommitmentDeadlines() public {
    // A.commit == B.commit breaks strictness in both branches
    Terms memory a = _side(100, 300, 500);
    Terms memory b = _side(100, 400, 600);
    vm.expectRevert(TermsLib.DisordedDeadlines.selector);
    harness.exposed_validateTermPairing(a, b);
  }

  function test_validateTermPairing_revertsWhen_equalClaimDeadlines() public {
    Terms memory a = _side(100, 300, 500);
    Terms memory b = _side(200, 300, 600);
    vm.expectRevert(TermsLib.DisordedDeadlines.selector);
    harness.exposed_validateTermPairing(a, b);
  }

  function test_validateTermPairing_revertsWhen_equalReclaimReleases() public {
    Terms memory a = _side(100, 300, 500);
    Terms memory b = _side(200, 400, 500);
    vm.expectRevert(TermsLib.DisordedDeadlines.selector);
    harness.exposed_validateTermPairing(a, b);
  }

  function test_validateTermPairing_revertsWhen_boundaryShared() public {
    // B.commit == A.claim: the cross-stage ordering touches but does not strictly increase
    Terms memory a = _side(100, 200, 500); // A.claim == 200
    Terms memory b = _side(200, 400, 600); // B.commit == 200
    vm.expectRevert(TermsLib.DisordedDeadlines.selector);
    harness.exposed_validateTermPairing(a, b);
  }

  function test_validateTermPairing_revertsWhen_claimsNotInterleaved() public {
    // valid commit interleave, but claim order is wrong: B.claim < A.claim
    Terms memory a = _side(100, 450, 500); // A.claim(450) > B.claim(400)
    Terms memory b = _side(200, 400, 600);
    vm.expectRevert(TermsLib.DisordedDeadlines.selector);
    harness.exposed_validateTermPairing(a, b);
  }

  function test_validateTermPairing_revertsWhen_reclaimsNotInterleaved() public {
    // valid through claims, but reclaim order is wrong: B.reclaim < A.reclaim
    Terms memory a = _side(100, 300, 650); // A.reclaim(650) > B.reclaim(600)
    Terms memory b = _side(200, 400, 600);
    vm.expectRevert(TermsLib.DisordedDeadlines.selector);
    harness.exposed_validateTermPairing(a, b);
  }

  function test_validateTermPairing_revertsWhen_fullyDisordered() public {
    Terms memory a = _side(600, 500, 400);
    Terms memory b = _side(300, 200, 100);
    vm.expectRevert(TermsLib.DisordedDeadlines.selector);
    harness.exposed_validateTermPairing(a, b);
  }

  // ============ Fuzz Tests ============

  function testFuzz_validateTermPairing_succeedsWhenStrictlyInterleaved(
    uint256 ac,
    uint256 gap
  ) public view {
    // build six strictly increasing deadlines from a base and a positive gap
    ac = bound(ac, 1, type(uint64).max);
    gap = bound(gap, 1, 1_000_000);
    Terms memory a = _side(ac, ac + 2 * gap, ac + 4 * gap);
    Terms memory b = _side(ac + gap, ac + 3 * gap, ac + 5 * gap);
    // proposer first (aProposes) and swapped (bProposes) both validate
    harness.exposed_validateTermPairing(a, b);
    harness.exposed_validateTermPairing(b, a);
  }
}
