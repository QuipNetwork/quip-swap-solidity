// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Terms, TermsLib} from '../../../src/TermsLib.sol';
import {IOmnibus, LockState} from '../../../src/interfaces/IOmnibus.sol';
import {AssetHelper} from '../../utils/AssetHelper.sol';
import {AuthHelper} from '../../utils/AuthHelper.sol';
import {OmnibusTest} from '../Omnibus.t.sol';

/// @title Omnibus Unhappy Path Scenarios
/// @dev Failure scenarios under the windowed timing model. Inherits the canonical schedule
///      and actors from OmnibusTest. Timing is enforced per-action by TermsLib.enforceWithin,
///      so out-of-window actions revert with WindowViolated rather than a terms-expiry error.
contract Omnibus_UnhappyPath is OmnibusTest {
  using AssetHelper for *;

  // ============ Terms Builders ============

  function _aliceNative(uint256 assetAmount) internal view returns (Terms memory) {
    return _aliceTermsOn(block.chainid, _makeNativeAssets(assetAmount));
  }

  function _bobNative(uint256 assetAmount) internal view returns (Terms memory) {
    return _bobTermsOn(block.chainid, _makeNativeAssets(assetAmount));
  }

  function _commitBoth(Terms memory aliceTerms, Terms memory bobTerms, uint256 amount) internal {
    vm.warp(AT_PROPOSER_COMMIT);
    vm.prank(ALICE);
    omnibus.commit{value: amount}(lock, aliceTerms, bobTerms, AuthHelper.keyedAuth(address(verifierA), ALICE));
    vm.warp(AT_TAKER_COMMIT);
    vm.prank(BOB);
    omnibus.commit{value: amount}(lock, bobTerms, aliceTerms, AuthHelper.keyedAuth(address(verifierA), BOB));
  }

  // ============ Scenario 7: Claim Fails After Proposer Claim Window ============

  function test_scenario_claimFailsAfterProposerWindow() public {
    uint256 assetAmount = 1 ether;
    Terms memory aliceTerms = _aliceNative(assetAmount);
    Terms memory bobTerms = _bobNative(assetAmount);

    _commitBoth(aliceTerms, bobTerms, assetAmount);

    // proposer-claim window upper bound (ALICE_CLAIM_DEADLINE) is exclusive
    vm.warp(ALICE_CLAIM_DEADLINE);
    vm.expectRevert(TermsLib.WindowViolated.selector);
    omnibus.claim(SECRET, aliceTerms, bobTerms);

    _assertSwapState(lock, aliceTerms, bobTerms, LockState.Committed);
  }

  // ============ Scenario 8: Claim Fails Before Proposer Claim Window ============

  function test_scenario_claimFailsBeforeProposerWindow() public {
    uint256 assetAmount = 1 ether;
    Terms memory aliceTerms = _aliceNative(assetAmount);
    Terms memory bobTerms = _bobNative(assetAmount);

    _commitBoth(aliceTerms, bobTerms, assetAmount);

    // window opens at BOB_COMMIT_DEADLINE; the taker just committed before that
    vm.warp(BOB_COMMIT_DEADLINE - 1);
    vm.expectRevert(TermsLib.WindowViolated.selector);
    omnibus.claim(SECRET, aliceTerms, bobTerms);

    _assertSwapState(lock, aliceTerms, bobTerms, LockState.Committed);
  }

  // ============ Scenario 9: Reclaim Succeeds At Exact Release ============

  function test_scenario_reclaimSucceedsAtExactRelease() public {
    uint256 assetAmount = 1 ether;
    Terms memory aliceTerms = _aliceNative(assetAmount);
    Terms memory bobTerms = _bobNative(assetAmount);

    _commitBoth(aliceTerms, bobTerms, assetAmount);

    // lower bound of the proposer reclaim window is inclusive
    vm.warp(ALICE_RECLAIM_RELEASE);

    uint256 aliceBalBefore = ALICE.balance;
    uint256 bobBalBefore = BOB.balance;

    vm.prank(ALICE);
    omnibus.reclaim(lock, aliceTerms, bobTerms);

    _assertSwapState(lock, aliceTerms, bobTerms, LockState.Spent);
    assertEq(ALICE.balance - aliceBalBefore, assetAmount);
    assertEq(BOB.balance - bobBalBefore, assetAmount);
  }

  // ============ Scenario 10: Second Commit With Mismatched Terms ============

  function test_scenario_secondCommitMismatchedTerms_opensIsolatedSwap() public {
    uint256 assetAmount = 1 ether;
    Terms memory aliceTerms = _aliceNative(assetAmount);
    Terms memory bobTerms = _bobNative(assetAmount);

    // Alice commits (proposer)
    vm.warp(AT_PROPOSER_COMMIT);
    vm.prank(ALICE);
    omnibus.commit{value: assetAmount}(lock, aliceTerms, bobTerms, AuthHelper.keyedAuth(address(verifierA), ALICE));

    // Bob commits with DIFFERENT terms (1.5 ETH instead of 1 ETH) in the taker window:
    // state is swap-scoped, so the mismatched pairing cannot join (or corrupt) Alice's
    // swap — it opens its own isolated swap instead
    Terms memory mismatchedBobTerms = _bobNative(1.5 ether);

    vm.warp(AT_TAKER_COMMIT);
    vm.prank(BOB);
    omnibus.commit{value: 1.5 ether}(
      lock, mismatchedBobTerms, aliceTerms, AuthHelper.keyedAuth(address(verifierA), BOB)
    );

    // Alice's swap is untouched, still awaiting HER pairing's taker leg
    _assertSwapState(lock, aliceTerms, bobTerms, LockState.Free);
    // the mismatched pairing sits in its own half-committed swap
    _assertSwapState(lock, aliceTerms, mismatchedBobTerms, LockState.Free);

    // Bob's self-inflicted escrow is recoverable from Free after his own release
    _warpToTakerReclaim();
    uint256 bobBalBefore = BOB.balance;
    vm.prank(BOB);
    omnibus.reclaim(lock, mismatchedBobTerms, aliceTerms);
    _assertSwapState(lock, aliceTerms, mismatchedBobTerms, LockState.Spent);
    assertEq(BOB.balance - bobBalBefore, 1.5 ether);
  }

  // ============ Scenario 11: Commit After Lock Already Spent ============

  function test_scenario_commitAfterSpent_reverts() public {
    uint256 assetAmount = 1 ether;
    Terms memory aliceTerms = _aliceNative(assetAmount);
    Terms memory bobTerms = _bobNative(assetAmount);

    // Complete full swap
    _commitBoth(aliceTerms, bobTerms, assetAmount);
    _warpToProposerClaim();
    omnibus.claim(SECRET, aliceTerms, bobTerms);
    _assertSwapState(lock, aliceTerms, bobTerms, LockState.Spent);

    // Re-enter the proposer commit window and try to commit the spent lock again
    vm.warp(AT_PROPOSER_COMMIT);
    vm.expectRevert(IOmnibus.InvalidLockAdvancement.selector);
    vm.prank(ALICE);
    omnibus.commit{value: assetAmount}(lock, aliceTerms, bobTerms, AuthHelper.keyedAuth(address(verifierA), ALICE));
  }

  // ============ Scenario 12: Reclaim Fails Before Release ============

  function test_scenario_reclaimFailsBeforeRelease() public {
    uint256 assetAmount = 1 ether;
    Terms memory aliceTerms = _aliceNative(assetAmount);
    Terms memory bobTerms = _bobNative(assetAmount);

    _commitBoth(aliceTerms, bobTerms, assetAmount);

    // time is at the taker-commit anchor, well before ALICE_RECLAIM_RELEASE
    vm.expectRevert(TermsLib.WindowViolated.selector);
    vm.prank(ALICE);
    omnibus.reclaim(lock, aliceTerms, bobTerms);

    _assertSwapState(lock, aliceTerms, bobTerms, LockState.Committed);
  }

  // ============ Scenario 13: Taker Commits First (Dead-End Swap) ============

  /// @notice nothing forces the proposer to commit first: the taker may post an Unused lock
  ///         inside the taker window. The proposer's own window has then already elapsed, so
  ///         the swap can never reach Committed — the taker's escrow stays recoverable after
  ///         their own release
  function test_scenario_takerCommitsFirst_swapDeadEnds_takerRecovers() public {
    uint256 assetAmount = 1 ether;
    Terms memory aliceTerms = _aliceNative(assetAmount);
    Terms memory bobTerms = _bobNative(assetAmount);

    // Bob (taker) commits first on the unused lock, inside the taker window
    vm.warp(AT_TAKER_COMMIT);
    vm.prank(BOB);
    omnibus.commit{value: assetAmount}(lock, bobTerms, aliceTerms, AuthHelper.keyedAuth(address(verifierA), BOB));
    _assertSwapState(lock, aliceTerms, bobTerms, LockState.Free);

    // the proposer can no longer commit: her window [0, ALICE_COMMIT_DEADLINE) has elapsed
    vm.expectRevert(TermsLib.WindowViolated.selector);
    vm.prank(ALICE);
    omnibus.commit{value: assetAmount}(lock, aliceTerms, bobTerms, AuthHelper.keyedAuth(address(verifierA), ALICE));

    // the lock is stuck in Free; claiming is impossible (never Committed)
    _warpToProposerClaim();
    vm.expectRevert(IOmnibus.InvalidLockState.selector);
    omnibus.claim(SECRET, aliceTerms, bobTerms);

    // the taker recovers the escrow after his own release
    _warpToTakerReclaim();
    uint256 bobBalBefore = BOB.balance;
    vm.prank(BOB);
    omnibus.reclaim(lock, bobTerms, aliceTerms);

    _assertSwapState(lock, aliceTerms, bobTerms, LockState.Spent);
    assertEq(BOB.balance - bobBalBefore, assetAmount);
  }
}
