// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Terms, TermsLib} from '../../../src/TermsLib.sol';
import {IOmnibus, LockState} from '../../../src/interfaces/IOmnibus.sol';
import {OmnibusTest} from '../Omnibus.t.sol';
import {AssetHelper} from '../../utils/AssetHelper.sol';
import {Vm} from 'forge-std-1.14.0/Vm.sol';

/// @title Omnibus slash Tests
/// @dev Tests for Omnibus.slash
contract Omnibus_slash is OmnibusTest {
  using AssetHelper for *;

  // ============ Helpers ============

  /// @notice Creates terms for Alice with earlier deadline (can be slashed)
  function _aliceSlashableTerms() internal view returns (Terms memory) {
    return _makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      uint64(block.timestamp + 1 days), // Earlier deadline
      _makeNativeAsset(COLLATERAL_AMOUNT),
      _makeNativeAssets(DEFAULT_AMOUNT)
    );
  }

  /// @notice Creates terms for Bob with later deadline (can still reclaim when alice is slashed)
  function _bobSlashTerms() internal view returns (Terms memory) {
    return _makeTerms(
      block.chainid,
      BOB,
      BOB_RECIPIENT,
      uint64(block.timestamp + 2 days), // Later deadline
      _makeNativeAsset(COLLATERAL_AMOUNT),
      _makeERC20Assets(DEFAULT_AMOUNT)
    );
  }

  // ============ Success Cases ============

  function test_slash_transfersCollateralToCounterpartyRecipient() public {
    Terms memory alice = _aliceSlashableTerms();
    Terms memory bob = _bobSlashTerms();

    _commitBothParties(lock, alice, bob);

    // Warp past alice's deadline but before bob's
    vm.warp(alice.deadline);

    uint256 bobRecipientBefore = BOB_RECIPIENT.balance;

    omnibus.slash(lock, alice, bob);

    // Alice's collateral goes to bob's recipient (punishment)
    assertEq(BOB_RECIPIENT.balance - bobRecipientBefore, COLLATERAL_AMOUNT);
  }

  function test_slash_returnsAssetsToSlashedSignatory() public {
    Terms memory alice = _aliceSlashableTerms();
    Terms memory bob = _bobSlashTerms();

    _commitBothParties(lock, alice, bob);

    vm.warp(alice.deadline);

    uint256 aliceBefore = ALICE.balance;

    omnibus.slash(lock, alice, bob);

    // Alice gets her assets back (not collateral)
    assertEq(ALICE.balance - aliceBefore, DEFAULT_AMOUNT);
  }

  function test_slash_sameChainCounterpartyReclaims() public {
    Terms memory alice = _aliceSlashableTerms();
    Terms memory bob = _bobSlashTerms();

    _commitBothParties(lock, alice, bob);

    vm.warp(alice.deadline);

    uint256 bobBalanceBefore = BOB.balance;
    uint256 bobERC20Before = mockERC20.balanceOf(BOB);

    omnibus.slash(lock, alice, bob);

    // Bob gets back his collateral and assets
    assertEq(BOB.balance - bobBalanceBefore, COLLATERAL_AMOUNT);
    assertEq(mockERC20.balanceOf(BOB) - bobERC20Before, DEFAULT_AMOUNT);
  }

  function test_slash_emitsSlashedEvent() public {
    Terms memory alice = _aliceSlashableTerms();
    Terms memory bob = _bobSlashTerms();

    _commitBothParties(lock, alice, bob);

    vm.warp(alice.deadline);

    vm.recordLogs();
    omnibus.slash(lock, alice, bob);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    bool foundEvent = false;
    for (uint256 i = 0; i < logs.length; i++) {
      if (logs[i].topics[0] == IOmnibus.Slashed.selector) {
        assertEq(logs[i].topics[1], lock);
        assertEq(address(uint160(uint256(logs[i].topics[2]))), ALICE);
        assertEq(address(uint160(uint256(logs[i].topics[3]))), BOB_RECIPIENT);
        foundEvent = true;
        break;
      }
    }
    assertTrue(foundEvent, 'Slashed event not emitted');
  }

  function test_slash_emitsReclaimedEventForCounterparty() public {
    Terms memory alice = _aliceSlashableTerms();
    Terms memory bob = _bobSlashTerms();

    _commitBothParties(lock, alice, bob);

    vm.warp(alice.deadline);

    vm.recordLogs();
    omnibus.slash(lock, alice, bob);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    bool foundReclaimed = false;
    for (uint256 i = 0; i < logs.length; i++) {
      if (logs[i].topics[0] == IOmnibus.Reclaimed.selector) {
        assertEq(logs[i].topics[1], lock);
        assertEq(address(uint160(uint256(logs[i].topics[2]))), BOB);
        foundReclaimed = true;
        break;
      }
    }
    assertTrue(foundReclaimed, 'Reclaimed event not emitted for counterparty');
  }

  function test_slash_anyoneCanSlash() public {
    Terms memory alice = _aliceSlashableTerms();
    Terms memory bob = _bobSlashTerms();

    _commitBothParties(lock, alice, bob);

    vm.warp(alice.deadline);

    // Charlie slashes
    vm.prank(CHARLIE);
    omnibus.slash(lock, alice, bob);

    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Spent));
  }

  function test_slash_setsLockStateToSpent() public {
    Terms memory alice = _aliceSlashableTerms();
    Terms memory bob = _bobSlashTerms();

    _commitBothParties(lock, alice, bob);

    vm.warp(alice.deadline);

    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Committed));

    omnibus.slash(lock, alice, bob);

    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Spent));
  }

  // ============ Revert Cases ============

  function test_slash_revertsWhen_termsMismatch() public {
    Terms memory alice = _aliceSlashableTerms();
    Terms memory bob = _bobSlashTerms();

    _commitBothParties(lock, alice, bob);

    vm.warp(alice.deadline);

    // Modify terms - use same deadline as alice to avoid TermsExpired
    Terms memory aliceModified = _makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      alice.deadline, // Same deadline
      _makeNativeAsset(COLLATERAL_AMOUNT),
      _makeNativeAssets(DEFAULT_AMOUNT + 1) // Different amount
    );

    vm.expectRevert(IOmnibus.TermsMismatch.selector);
    omnibus.slash(lock, aliceModified, bob);
  }

  function test_slash_revertsWhen_lockNotCommitted() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    // Only first commit (Free state)
    _commitFor(ALICE, lock, alice, bob);

    vm.warp(alice.deadline);

    vm.expectRevert(IOmnibus.InvalidLockState.selector);
    omnibus.slash(lock, alice, bob);
  }

  function test_slash_revertsWhen_lockUnused() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    vm.warp(alice.deadline);

    vm.expectRevert(IOmnibus.TermsMismatch.selector);
    omnibus.slash(lock, alice, bob);
  }

  function test_slash_revertsWhen_lockFree() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitFor(ALICE, lock, alice, bob);
    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Free));

    vm.warp(alice.deadline);

    vm.expectRevert(IOmnibus.InvalidLockState.selector);
    omnibus.slash(lock, alice, bob);
  }

  function test_slash_revertsWhen_lockSpent() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);
    omnibus.execute(SECRET, alice, bob);
    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Spent));

    vm.warp(alice.deadline);

    vm.expectRevert(IOmnibus.InvalidLockState.selector);
    omnibus.slash(lock, alice, bob);
  }

  function test_slash_revertsWhen_partyNotOnChain() public {
    Terms memory alice = _makeTerms(
      OTHER_CHAIN_ID, // Alice on other chain
      ALICE,
      ALICE_RECIPIENT,
      _defaultDeadline(),
      _makeNativeAsset(COLLATERAL_AMOUNT),
      _makeNativeAssets(DEFAULT_AMOUNT)
    );
    Terms memory bob = _bobTerms();

    bytes32 hash = omnibus.computeTermsHash(alice, bob);
    omnibus.setLockState(lock, LockState.Committed);
    omnibus.setTermsHash(lock, hash);

    vm.warp(alice.deadline);

    vm.expectRevert(IOmnibus.ChainMismatch.selector);
    omnibus.slash(lock, alice, bob);
  }

  function test_slash_revertsWhen_deadlineNotPassed() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);

    // Don't warp - deadline not passed
    vm.expectRevert(TermsLib.TermsNotExpired.selector);
    omnibus.slash(lock, alice, bob);
  }

  function test_slash_revertsWhen_sameChainCounterpartyExpired() public {
    // Create terms where counterparty expires before party
    Terms memory alice = _makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      uint64(block.timestamp + 2 days), // Later deadline
      _makeNativeAsset(COLLATERAL_AMOUNT),
      _makeNativeAssets(DEFAULT_AMOUNT)
    );
    Terms memory bob = _makeTerms(
      block.chainid,
      BOB,
      BOB_RECIPIENT,
      uint64(block.timestamp + 1 days), // Earlier deadline
      _makeNativeAsset(COLLATERAL_AMOUNT),
      _makeERC20Assets(DEFAULT_AMOUNT)
    );

    _commitBothParties(lock, alice, bob);

    // Warp past both deadlines so alice can be slashed but bob's reclaim fails
    vm.warp(alice.deadline);

    // This should revert because counterparty's reclaim fails (deadline expired)
    vm.expectRevert(TermsLib.TermsExpired.selector);
    omnibus.slash(lock, alice, bob);
  }

  // ============ Edge Cases ============

  function test_slash_exactDeadlineTimestamp() public {
    Terms memory alice = _aliceSlashableTerms();
    Terms memory bob = _bobSlashTerms();

    _commitBothParties(lock, alice, bob);

    // Warp to exactly deadline - should succeed (stale)
    vm.warp(alice.deadline);

    omnibus.slash(lock, alice, bob);
    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Spent));
  }

  function test_slash_oneSecondAfterDeadline() public {
    Terms memory alice = _aliceSlashableTerms();
    Terms memory bob = _bobSlashTerms();

    _commitBothParties(lock, alice, bob);

    vm.warp(alice.deadline + 1);

    omnibus.slash(lock, alice, bob);
    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Spent));
  }

  // ============ Fuzz Tests ============

  function testFuzz_slash_afterDeadline(uint64 deadline, uint64 delay) public {
    deadline = uint64(bound(deadline, block.timestamp + 1, type(uint64).max - 1 days));
    delay = uint64(bound(delay, 0, 1 days));

    Terms memory alice = _makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      deadline,
      _makeNativeAsset(COLLATERAL_AMOUNT),
      _makeNativeAssets(DEFAULT_AMOUNT)
    );
    // Bob's deadline must be after the warp time
    Terms memory bob = _makeTerms(
      block.chainid,
      BOB,
      BOB_RECIPIENT,
      uint64(deadline + delay + 1),
      _makeNativeAsset(COLLATERAL_AMOUNT),
      _makeERC20Assets(DEFAULT_AMOUNT)
    );

    _commitBothParties(lock, alice, bob);

    vm.warp(deadline + delay);

    omnibus.slash(lock, alice, bob);
    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Spent));
  }
}
