// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Terms, TermsLib} from '../../../src/TermsLib.sol';
import {LockState} from '../../../src/interfaces/IOmnibus.sol';
import {AssetHelper} from '../../utils/AssetHelper.sol';
import {AuthHelper} from '../../utils/AuthHelper.sol';
import {OmnibusTest} from '../Omnibus.t.sol';

/// @title Omnibus Optimistic Path Scenarios
/// @dev End-to-end flows under optimistic mode: both sides sign `optimistic = true`, waiving
///      the LOWER bounds of the commit and claim windows (no forced sequencing waits). Upper
///      bounds and reclaimRelease stay enforced, so the generously-sized deadline schedule
///      remains the fallback path if the fast path stalls. Same-chain, the lock state machine
///      (Unused -> Free -> Committed -> Spent) carries the ordering the clock no longer does.
contract Omnibus_OptimisticPath is OmnibusTest {
  using AssetHelper for *;

  // ============ Scenario 1: Single-Timestamp Settlement ============

  /// @notice the exchange fast path: proposer commit, taker commit, and claim all land at
  ///         ONE timestamp — the flow that is structurally impossible non-optimistically
  function test_optimistic_scenario_sameChain_singleTimestampSettlement() public {
    Terms memory alice = _aliceOptimisticTerms();
    Terms memory bob = _bobOptimisticTerms();

    uint256 bobRecipientBefore = BOB_RECIPIENT.balance;
    uint256 aliceRecipientBefore = mockERC20.balanceOf(ALICE_RECIPIENT);

    _commitBothPartiesAt(lock, alice, bob, AT_PROPOSER_COMMIT);
    _assertLockState(lock, LockState.Committed);

    // settle at the very same instant — commit is permissionless, so off-chain all three
    // calls can be bundled into a single transaction
    vm.prank(ALICE);
    omnibus.claim(SECRET, alice, bob);

    assertEq(block.timestamp, AT_PROPOSER_COMMIT);
    _assertLockState(lock, LockState.Spent);
    assertEq(BOB_RECIPIENT.balance - bobRecipientBefore, DEFAULT_AMOUNT);
    assertEq(mockERC20.balanceOf(ALICE_RECIPIENT) - aliceRecipientBefore, DEFAULT_AMOUNT);
  }

  // ============ Scenario 2: Taker-First Commit Order ============

  /// @notice with the lower bounds waived either side may post first; the state machine
  ///         sequences the swap and settlement routes both legs correctly
  function test_optimistic_scenario_sameChain_takerFirstOrder_settles() public {
    Terms memory alice = _aliceOptimisticTerms();
    Terms memory bob = _bobOptimisticTerms();

    uint256 bobRecipientBefore = BOB_RECIPIENT.balance;
    uint256 aliceRecipientBefore = mockERC20.balanceOf(ALICE_RECIPIENT);

    // reversed order: taker posts into Unused (-> Free), proposer completes (-> Committed)
    _commitAt(BOB, lock, bob, alice, AT_PROPOSER_COMMIT);
    _assertLockState(lock, LockState.Free);
    _commitAt(ALICE, lock, alice, bob, AT_PROPOSER_COMMIT);
    _assertLockState(lock, LockState.Committed);

    vm.prank(ALICE);
    omnibus.claim(SECRET, alice, bob);

    _assertLockState(lock, LockState.Spent);
    assertEq(BOB_RECIPIENT.balance - bobRecipientBefore, DEFAULT_AMOUNT);
    assertEq(mockERC20.balanceOf(ALICE_RECIPIENT) - aliceRecipientBefore, DEFAULT_AMOUNT);
  }

  // ============ Scenario 3: Taker-First Then Abandoned ============

  /// @notice the self-risk shape of taker-first posting: the taker escrows into Free, the
  ///         proposer never shows, and the taker's funds sit until its OWN reclaimRelease —
  ///         the abandoned optimistic swap degrades to the normal timed fallback
  function test_optimistic_scenario_sameChain_takerFirstThenAbandoned_reclaimableAfterRelease() public {
    Terms memory alice = _aliceOptimisticTerms();
    Terms memory bob = _bobOptimisticTerms();

    _commitAt(BOB, lock, bob, alice, AT_PROPOSER_COMMIT);
    _assertLockState(lock, LockState.Free);

    // reclaimRelease is never waived: too early even though the swap is optimistic
    vm.expectRevert(TermsLib.WindowViolated.selector);
    vm.prank(BOB);
    omnibus.reclaim(lock, bob, alice);

    // at the taker's own release the single posted leg refunds to its reclaimRecipient
    vm.warp(BOB_RECLAIM_RELEASE);
    uint256 bobBefore = mockERC20.balanceOf(BOB);
    vm.prank(BOB);
    omnibus.reclaim(lock, bob, alice);

    _assertLockState(lock, LockState.Spent);
    assertEq(mockERC20.balanceOf(BOB) - bobBefore, DEFAULT_AMOUNT);
  }
}
