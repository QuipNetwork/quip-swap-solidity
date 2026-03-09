// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Test} from 'forge-std-1.14.0/Test.sol';

import {Asset, Terms, TermsLib} from '../../../src/TermsLib.sol';
import {IOmnibus, LockState} from '../../../src/interfaces/IOmnibus.sol';
import {OmnibusHarness} from '../../harness/OmnibusHarness.sol';
import {ERC20Mock} from '../../mocks/ERC20Mock.sol';
import {AssetHelper} from '../../utils/AssetHelper.sol';
import {TermsHelper} from '../../utils/TermsHelper.sol';

/// @title Omnibus Unhappy Path Scenarios
/// @dev Tests for failure scenarios (deadlines, misconfigs, etc.)
contract Omnibus_UnhappyPath is Test {
  using AssetHelper for *;
  using TermsHelper for *;

  // ============ Actors ============

  address public ALICE = makeAddr('alice');
  address public BOB = makeAddr('bob');
  address public CHARLIE = makeAddr('charlie');
  address public ALICE_RECIPIENT = makeAddr('aliceRecipient');
  address public BOB_RECIPIENT = makeAddr('bobRecipient');

  // ============ Contracts ============

  OmnibusHarness public omnibus;
  ERC20Mock public mockERC20;

  // ============ Test Data ============

  bytes32 public constant SECRET = keccak256('secret');
  bytes32 public lock;

  // ============ Setup ============

  function setUp() public virtual {
    mockERC20 = new ERC20Mock('MockToken', 'MTK', 18);
    omnibus = new OmnibusHarness();
    lock = TermsLib.generateLock(SECRET);

    vm.deal(ALICE, 100 ether);
    vm.deal(BOB, 100 ether);
    vm.deal(CHARLIE, 100 ether);

    mockERC20.mint(ALICE, 1_000_000 ether);
    mockERC20.mint(BOB, 1_000_000 ether);

    vm.prank(ALICE);
    mockERC20.approve(address(omnibus), type(uint256).max);
    vm.prank(BOB);
    mockERC20.approve(address(omnibus), type(uint256).max);
  }

  // ============ Scenario 7: Slash After Party Deadline ============

  /// @notice Test slash after party deadline expires (party punished)
  function test_scenario_slashAfterDeadline_partyPunished() public {
    uint256 assetAmount = 1 ether;
    uint256 collateralAmount = 0.1 ether;
    uint64 aliceDeadline = uint64(block.timestamp + 1 days);
    uint64 bobDeadline = uint64(block.timestamp + 2 days); // Longer - required for slash

    Terms memory aliceTerms = TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      aliceDeadline,
      AssetHelper.makeNative(collateralAmount),
      AssetHelper.makeNative(assetAmount).toArray()
    );

    Terms memory bobTerms = TermsHelper.makeTerms(
      block.chainid,
      BOB,
      BOB_RECIPIENT,
      bobDeadline,
      AssetHelper.makeNative(collateralAmount),
      AssetHelper.makeNative(assetAmount).toArray()
    );

    // Commit both parties
    vm.prank(ALICE);
    omnibus.commit{value: assetAmount + collateralAmount}(lock, aliceTerms, bobTerms);
    vm.prank(BOB);
    omnibus.commit{value: assetAmount + collateralAmount}(lock, bobTerms, aliceTerms);

    // Warp to exactly Alice's deadline
    vm.warp(aliceDeadline);

    // Record balances
    uint256 bobRecipientBalBefore = BOB_RECIPIENT.balance;
    uint256 aliceBalBefore = ALICE.balance;
    uint256 bobBalBefore = BOB.balance;

    // Charlie slashes Alice
    vm.prank(CHARLIE);
    omnibus.slash(lock, aliceTerms, bobTerms);

    // Verify: lock state = Spent
    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Spent));

    // Verify: Alice's COLLATERAL -> BOB_RECIPIENT (punishment)
    assertEq(BOB_RECIPIENT.balance - bobRecipientBalBefore, collateralAmount);

    // Verify: Alice's ASSETS -> ALICE (returned, not swapped)
    assertEq(ALICE.balance - aliceBalBefore, assetAmount);

    // Verify: Bob's ASSETS + COLLATERAL -> BOB (reclaimed)
    assertEq(BOB.balance - bobBalBefore, assetAmount + collateralAmount);
  }

  // ============ Scenario 8: Execute Fails After Party Deadline ============

  /// @notice Test execute fails after party deadline expires
  function test_scenario_executeFailsAfterDeadline_partyExpired() public {
    uint256 assetAmount = 1 ether;
    uint256 collateralAmount = 0.1 ether;
    uint64 aliceDeadline = uint64(block.timestamp + 1 days);
    uint64 bobDeadline = uint64(block.timestamp + 2 days);

    Terms memory aliceTerms = TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      aliceDeadline,
      AssetHelper.makeNative(collateralAmount),
      AssetHelper.makeNative(assetAmount).toArray()
    );

    Terms memory bobTerms = TermsHelper.makeTerms(
      block.chainid,
      BOB,
      BOB_RECIPIENT,
      bobDeadline,
      AssetHelper.makeNative(collateralAmount),
      AssetHelper.makeNative(assetAmount).toArray()
    );

    // Commit both parties
    vm.prank(ALICE);
    omnibus.commit{value: assetAmount + collateralAmount}(lock, aliceTerms, bobTerms);
    vm.prank(BOB);
    omnibus.commit{value: assetAmount + collateralAmount}(lock, bobTerms, aliceTerms);

    // Warp past Alice's deadline but before Bob's
    vm.warp(aliceDeadline + 12 hours);

    // Try execute - should fail
    vm.expectRevert(TermsLib.TermsExpired.selector);
    omnibus.execute(SECRET, aliceTerms, bobTerms);

    // Verify: lock state unchanged
    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Committed));
  }

  // ============ Scenario 9: Execute Fails After Counterparty Deadline ============

  /// @notice Test execute fails after counterparty deadline expires
  function test_scenario_executeFailsAfterDeadline_counterpartyExpired() public {
    uint256 assetAmount = 1 ether;
    uint256 collateralAmount = 0.1 ether;
    uint64 aliceDeadline = uint64(block.timestamp + 2 days);
    uint64 bobDeadline = uint64(block.timestamp + 1 days);

    Terms memory aliceTerms = TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      aliceDeadline,
      AssetHelper.makeNative(collateralAmount),
      AssetHelper.makeNative(assetAmount).toArray()
    );

    Terms memory bobTerms = TermsHelper.makeTerms(
      block.chainid,
      BOB,
      BOB_RECIPIENT,
      bobDeadline,
      AssetHelper.makeNative(collateralAmount),
      AssetHelper.makeNative(assetAmount).toArray()
    );

    // Commit both parties
    vm.prank(ALICE);
    omnibus.commit{value: assetAmount + collateralAmount}(lock, aliceTerms, bobTerms);
    vm.prank(BOB);
    omnibus.commit{value: assetAmount + collateralAmount}(lock, bobTerms, aliceTerms);

    // Warp past Bob's deadline but before Alice's
    vm.warp(bobDeadline + 12 hours);

    // Try execute - should fail because counterparty expired
    vm.expectRevert(TermsLib.TermsExpired.selector);
    omnibus.execute(SECRET, aliceTerms, bobTerms);

    // Verify: lock state unchanged
    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Committed));
  }

  // ============ Scenario 10: Reclaim Fails At Exact Deadline ============

  /// @notice Test reclaim fails at exact deadline timestamp
  function test_scenario_reclaimFailsAtExactDeadline() public {
    uint256 assetAmount = 1 ether;
    uint256 collateralAmount = 0.1 ether;
    uint64 deadline = uint64(block.timestamp + 1 days);

    Terms memory aliceTerms = TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      deadline,
      AssetHelper.makeNative(collateralAmount),
      AssetHelper.makeNative(assetAmount).toArray()
    );

    Terms memory bobTerms = TermsHelper.makeTerms(
      block.chainid,
      BOB,
      BOB_RECIPIENT,
      deadline,
      AssetHelper.makeNative(collateralAmount),
      AssetHelper.makeNative(assetAmount).toArray()
    );

    // Commit both parties
    vm.prank(ALICE);
    omnibus.commit{value: assetAmount + collateralAmount}(lock, aliceTerms, bobTerms);
    vm.prank(BOB);
    omnibus.commit{value: assetAmount + collateralAmount}(lock, bobTerms, aliceTerms);

    // Warp to EXACTLY deadline
    vm.warp(deadline);

    // Try reclaim - should fail (deadline is exclusive for reclaim)
    vm.expectRevert(TermsLib.TermsExpired.selector);
    vm.prank(ALICE);
    omnibus.reclaim(lock, aliceTerms, bobTerms);
  }

  // ============ Scenario 11: Second Commit With Mismatched Terms ============

  /// @notice Test second commit with different terms reverts
  function test_scenario_secondCommitMismatchedTerms_reverts() public {
    uint256 assetAmount = 1 ether;
    uint256 collateralAmount = 0.1 ether;
    uint64 deadline = uint64(block.timestamp + 1 days);

    Terms memory aliceTerms = TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      deadline,
      AssetHelper.makeNative(collateralAmount),
      AssetHelper.makeNative(assetAmount).toArray()
    );

    Terms memory bobTerms = TermsHelper.makeTerms(
      block.chainid,
      BOB,
      BOB_RECIPIENT,
      deadline,
      AssetHelper.makeNative(collateralAmount),
      AssetHelper.makeNative(assetAmount).toArray()
    );

    // Alice commits
    vm.prank(ALICE);
    omnibus.commit{value: assetAmount + collateralAmount}(lock, aliceTerms, bobTerms);

    // Bob tries to commit with DIFFERENT terms (1.5 ETH instead of 1 ETH)
    Terms memory mismatchedBobTerms = TermsHelper.makeTerms(
      block.chainid,
      BOB,
      BOB_RECIPIENT,
      deadline,
      AssetHelper.makeNative(collateralAmount),
      AssetHelper.makeNative(1.5 ether).toArray() // Different amount
    );

    vm.expectRevert(IOmnibus.TermsMismatch.selector);
    vm.prank(BOB);
    omnibus.commit{value: 1.5 ether + collateralAmount}(lock, mismatchedBobTerms, aliceTerms);

    // Verify: lock state still = Free
    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Free));
  }

  // ============ Scenario 12: Commit After Lock Already Spent ============

  /// @notice Test commit after lock is spent reverts
  function test_scenario_commitAfterSpent_reverts() public {
    uint256 assetAmount = 1 ether;
    uint256 collateralAmount = 0.1 ether;
    uint64 deadline = uint64(block.timestamp + 1 days);

    Terms memory aliceTerms = TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      deadline,
      AssetHelper.makeNative(collateralAmount),
      AssetHelper.makeNative(assetAmount).toArray()
    );

    Terms memory bobTerms = TermsHelper.makeTerms(
      block.chainid,
      BOB,
      BOB_RECIPIENT,
      deadline,
      AssetHelper.makeNative(collateralAmount),
      AssetHelper.makeNative(assetAmount).toArray()
    );

    // Complete full swap
    vm.prank(ALICE);
    omnibus.commit{value: assetAmount + collateralAmount}(lock, aliceTerms, bobTerms);
    vm.prank(BOB);
    omnibus.commit{value: assetAmount + collateralAmount}(lock, bobTerms, aliceTerms);
    omnibus.execute(SECRET, aliceTerms, bobTerms);

    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Spent));

    // Charlie tries to commit with same lock, different terms
    Terms memory charlieTerms = TermsHelper.makeTerms(
      block.chainid,
      CHARLIE,
      CHARLIE,
      deadline,
      AssetHelper.makeNative(collateralAmount),
      AssetHelper.makeNative(assetAmount).toArray()
    );

    vm.expectRevert(IOmnibus.InvalidLockAdvancement.selector);
    vm.prank(CHARLIE);
    omnibus.commit{value: assetAmount + collateralAmount}(lock, charlieTerms, bobTerms);
  }

  // ============ Scenario 13: Slash Fails When Same-Chain Counterparty Expired ============

  /// @notice Test slash fails when counterparty has also expired (lock stuck)
  function test_scenario_slashFailsCounterpartyExpired_lockStuck() public {
    uint256 assetAmount = 1 ether;
    uint256 collateralAmount = 0.1 ether;
    uint64 aliceDeadline = uint64(block.timestamp + 2 days); // LATER
    uint64 bobDeadline = uint64(block.timestamp + 1 days);   // EARLIER - misconfigured!

    Terms memory aliceTerms = TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      aliceDeadline,
      AssetHelper.makeNative(collateralAmount),
      AssetHelper.makeNative(assetAmount).toArray()
    );

    Terms memory bobTerms = TermsHelper.makeTerms(
      block.chainid,
      BOB,
      BOB_RECIPIENT,
      bobDeadline,
      AssetHelper.makeNative(collateralAmount),
      AssetHelper.makeNative(assetAmount).toArray()
    );

    // Commit both parties
    vm.prank(ALICE);
    omnibus.commit{value: assetAmount + collateralAmount}(lock, aliceTerms, bobTerms);
    vm.prank(BOB);
    omnibus.commit{value: assetAmount + collateralAmount}(lock, bobTerms, aliceTerms);

    // Warp to Alice's deadline (Bob's already expired)
    vm.warp(aliceDeadline);

    // Try slash Alice - should fail because Bob's reclaim during slash fails
    vm.expectRevert(TermsLib.TermsExpired.selector);
    vm.prank(CHARLIE);
    omnibus.slash(lock, aliceTerms, bobTerms);

    // Verify: lock stuck in Committed state
    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Committed));
  }

  // ============ Scenario 14: Reclaim Fails When Counterparty Expired ============

  /// @notice Test reclaim fails when counterparty has expired
  function test_scenario_reclaimFailsCounterpartyExpired_lockStuck() public {
    uint256 assetAmount = 1 ether;
    uint256 collateralAmount = 0.1 ether;
    uint64 aliceDeadline = uint64(block.timestamp + 2 days);
    uint64 bobDeadline = uint64(block.timestamp + 1 days);

    Terms memory aliceTerms = TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      aliceDeadline,
      AssetHelper.makeNative(collateralAmount),
      AssetHelper.makeNative(assetAmount).toArray()
    );

    Terms memory bobTerms = TermsHelper.makeTerms(
      block.chainid,
      BOB,
      BOB_RECIPIENT,
      bobDeadline,
      AssetHelper.makeNative(collateralAmount),
      AssetHelper.makeNative(assetAmount).toArray()
    );

    // Commit both parties
    vm.prank(ALICE);
    omnibus.commit{value: assetAmount + collateralAmount}(lock, aliceTerms, bobTerms);
    vm.prank(BOB);
    omnibus.commit{value: assetAmount + collateralAmount}(lock, bobTerms, aliceTerms);

    // Warp past Bob's deadline but before Alice's
    vm.warp(bobDeadline + 12 hours);

    // Alice tries reclaim - should fail (counterparty freshness check)
    vm.expectRevert(TermsLib.TermsExpired.selector);
    vm.prank(ALICE);
    omnibus.reclaim(lock, aliceTerms, bobTerms);

    // Verify: lock stuck in Committed state
    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Committed));
  }
}
