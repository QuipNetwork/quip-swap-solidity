// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Terms, TermsLib} from '../../../src/TermsLib.sol';
import {IOmnibus, LockState} from '../../../src/interfaces/IOmnibus.sol';
import {OmnibusTest} from '../Omnibus.t.sol';
import {AssetHelper} from '../../utils/AssetHelper.sol';
import {Vm} from 'forge-std-1.14.0/Vm.sol';

/// @title Omnibus reclaim Tests
/// @dev Tests for Omnibus.reclaim
contract Omnibus_reclaim is OmnibusTest {
  using AssetHelper for *;

  // ============ Success Cases ============

  function test_reclaim_returnsAssetsToSignatory() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);

    // Warp to deadline (staleness check)
    vm.warp(alice.deadline);

    uint256 aliceBefore = ALICE.balance;

    omnibus.reclaim(lock, alice, bob);

    // Alice gets her assets back
    assertEq(ALICE.balance - aliceBefore, DEFAULT_AMOUNT);
  }

  function test_reclaim_fromFreeState() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    // Only alice commits (Free state)
    _commitFor(ALICE, lock, alice, bob);
    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Free));

    // Warp to deadline (staleness check)
    vm.warp(alice.deadline);

    uint256 aliceBefore = ALICE.balance;

    omnibus.reclaim(lock, alice, bob);

    // Alice gets everything back
    assertEq(ALICE.balance - aliceBefore, DEFAULT_AMOUNT);
    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Spent));
  }

  function test_reclaim_fromCommittedState() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);
    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Committed));

    // Warp to deadline (staleness check)
    vm.warp(alice.deadline);

    omnibus.reclaim(lock, alice, bob);
    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Spent));
  }

  function test_reclaim_sameChainBothPartiesReclaim() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);

    // Warp to deadline (staleness check)
    vm.warp(alice.deadline);

    uint256 aliceBefore = ALICE.balance;
    uint256 bobERC20Before = mockERC20.balanceOf(BOB);

    omnibus.reclaim(lock, alice, bob);

    // Alice gets her native assets back
    assertEq(ALICE.balance - aliceBefore, DEFAULT_AMOUNT);
    // Bob gets his ERC20 assets back
    assertEq(mockERC20.balanceOf(BOB) - bobERC20Before, DEFAULT_AMOUNT);
  }

  function test_reclaim_emitsReclaimedEvent() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);

    // Warp to deadline (staleness check)
    vm.warp(alice.deadline);

    vm.recordLogs();
    omnibus.reclaim(lock, alice, bob);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    uint256 reclaimedCount = 0;
    for (uint256 i = 0; i < logs.length; i++) {
      if (logs[i].topics[0] == IOmnibus.Reclaimed.selector) {
        assertEq(logs[i].topics[1], lock);
        reclaimedCount++;
      }
    }
    // Should emit Reclaimed for both parties (same chain)
    assertEq(reclaimedCount, 2);
  }

  function test_reclaim_anyoneCanReclaim() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);

    // Warp to deadline (staleness check)
    vm.warp(alice.deadline);

    // Charlie reclaims on behalf of parties
    vm.prank(CHARLIE);
    omnibus.reclaim(lock, alice, bob);

    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Spent));
  }

  function test_reclaim_setsLockStateToSpent() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);
    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Committed));

    // Warp to deadline (staleness check)
    vm.warp(alice.deadline);

    omnibus.reclaim(lock, alice, bob);

    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Spent));
  }

  // ============ Revert Cases ============

  function test_reclaim_revertsWhen_termsMismatch() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);

    // Warp to deadline (staleness check)
    vm.warp(alice.deadline);

    // Modify terms
    Terms memory aliceModified = _makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      alice.deadline,
      _makeNativeAssets(DEFAULT_AMOUNT + 1)
    );

    vm.expectRevert(IOmnibus.TermsMismatch.selector);
    omnibus.reclaim(lock, aliceModified, bob);
  }

  function test_reclaim_revertsWhen_lockUnused() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Unused));

    // Warp to deadline (staleness check)
    vm.warp(alice.deadline);

    // Terms hash is 0 for unused lock, so it won't match
    vm.expectRevert(IOmnibus.TermsMismatch.selector);
    omnibus.reclaim(lock, alice, bob);
  }

  function test_reclaim_revertsWhen_lockSpent() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);
    omnibus.execute(SECRET, alice, bob);
    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Spent));

    // Warp to deadline (staleness check)
    vm.warp(alice.deadline);

    vm.expectRevert(IOmnibus.InvalidLockAdvancement.selector);
    omnibus.reclaim(lock, alice, bob);
  }

  function test_reclaim_revertsWhen_partyNotOnChain() public {
    Terms memory alice = _makeTerms(
      OTHER_CHAIN_ID, // Alice on other chain
      ALICE,
      ALICE_RECIPIENT,
      _defaultDeadline(),
      _makeNativeAssets(DEFAULT_AMOUNT)
    );
    Terms memory bob = _bobTerms();

    bytes32 hash = omnibus.computeTermsHash(alice, bob);
    omnibus.setLockState(lock, LockState.Committed);
    omnibus.setTermsHash(lock, hash);

    // Warp to deadline (staleness check)
    vm.warp(alice.deadline);

    vm.expectRevert(TermsLib.ChainIdMismatch.selector);
    omnibus.reclaim(lock, alice, bob);
  }

  function test_reclaim_revertsWhen_deadlineNotExpired() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);

    // Don't warp - deadline not passed
    vm.expectRevert(TermsLib.TermsNotExpired.selector);
    omnibus.reclaim(lock, alice, bob);
  }

  function test_reclaim_revertsWhen_sameChainCounterpartyNotExpired() public {
    // Create terms where party expires before counterparty
    Terms memory alice = _makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      uint64(block.timestamp + 1 days), // Earlier deadline
      _makeNativeAssets(DEFAULT_AMOUNT)
    );
    Terms memory bob = _makeTerms(
      block.chainid,
      BOB,
      BOB_RECIPIENT,
      uint64(block.timestamp + 2 days), // Later deadline
      _makeERC20Assets(DEFAULT_AMOUNT)
    );

    _commitBothParties(lock, alice, bob);

    // Warp to alice's deadline (passed) but before bob's
    vm.warp(alice.deadline);

    // This should revert because counterparty's staleness check fails
    vm.expectRevert(TermsLib.TermsNotExpired.selector);
    omnibus.reclaim(lock, alice, bob);
  }

  // ============ Edge Cases ============

  function test_reclaim_oneSecondAfterDeadline() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);

    // Warp to one second after deadline
    vm.warp(alice.deadline + 1);

    omnibus.reclaim(lock, alice, bob);
    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Spent));
  }

  function test_reclaim_exactDeadlineTimestamp() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);

    // Warp to exactly deadline - should succeed (stale)
    vm.warp(alice.deadline);

    omnibus.reclaim(lock, alice, bob);
    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Spent));
  }

  // ============ Fuzz Tests ============

  function testFuzz_reclaim_afterDeadline(uint64 deadline, uint64 delay) public {
    deadline = uint64(bound(deadline, block.timestamp + 1, type(uint64).max - 1 days));
    delay = uint64(bound(delay, 0, 1 days));

    Terms memory alice = _makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      deadline,
      _makeNativeAssets(DEFAULT_AMOUNT)
    );
    Terms memory bob = _makeTerms(
      block.chainid,
      BOB,
      BOB_RECIPIENT,
      deadline,
      _makeERC20Assets(DEFAULT_AMOUNT)
    );

    _commitBothParties(lock, alice, bob);

    // Warp to or after deadline
    vm.warp(deadline + delay);

    omnibus.reclaim(lock, alice, bob);
    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Spent));
  }
}
