// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Test} from 'forge-std-1.14.0/Test.sol';

import {Terms} from '../../../src/TermsLib.sol';
import {IOmnibus, LockState} from '../../../src/interfaces/IOmnibus.sol';
import {OmnibusHarness} from '../../harness/OmnibusHarness.sol';
import {ERC20Mock} from '../../mocks/ERC20Mock.sol';
import {AssetHelper} from '../../utils/AssetHelper.sol';
import {TermsHelper} from '../../utils/TermsHelper.sol';

/// @title Omnibus Attack Scenarios
/// @dev Tests for security attack simulations
contract Omnibus_AttackScenarios is Test {
  using AssetHelper for *;
  using TermsHelper for *;

  // ============ Constants ============

  uint256 constant CHAIN_A = 1;
  uint256 constant CHAIN_B = 137;

  // ============ Actors ============

  address public ALICE = makeAddr('alice');
  address public BOB = makeAddr('bob');
  address public CHARLIE = makeAddr('charlie');
  address public ATTACKER = makeAddr('attacker');
  address public ALICE_RECIPIENT = makeAddr('aliceRecipient');
  address public BOB_RECIPIENT = makeAddr('bobRecipient');

  // ============ Contracts ============

  OmnibusHarness public omnibus;
  OmnibusHarness public omnibusA;
  OmnibusHarness public omnibusB;
  ERC20Mock public mockERC20;
  ERC20Mock public tokenA;
  ERC20Mock public tokenB;

  // ============ Test Data ============

  bytes32 public constant SECRET = keccak256('secret');
  bytes32 public lock;

  // ============ Setup ============

  function setUp() public virtual {
    mockERC20 = new ERC20Mock('MockToken', 'MTK', 18);
    omnibus = new OmnibusHarness();
    omnibusA = new OmnibusHarness();
    omnibusB = new OmnibusHarness();
    tokenA = new ERC20Mock('TokenA', 'TKA', 18);
    tokenB = new ERC20Mock('TokenB', 'TKB', 18);

    lock = omnibus.exposed_generateLock(SECRET);

    vm.deal(ALICE, 100 ether);
    vm.deal(BOB, 100 ether);
    vm.deal(CHARLIE, 100 ether);
    vm.deal(ATTACKER, 100 ether);

    mockERC20.mint(ALICE, 1_000_000 ether);
    mockERC20.mint(BOB, 1_000_000 ether);

    vm.prank(ALICE);
    mockERC20.approve(address(omnibus), type(uint256).max);
    vm.prank(BOB);
    mockERC20.approve(address(omnibus), type(uint256).max);
  }

  // ============ Attack 1: Double-Spend Same Chain ============

  /// @notice Test double-spend attempt on same chain fails
  function test_attack_doubleSpendSameChain_secondExecuteFails() public {
    uint256 assetAmount = 1 ether;
    uint64 deadline = uint64(block.timestamp + 1 days);

    Terms memory aliceTerms = TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      deadline,
      AssetHelper.makeNative(assetAmount).toArray()
    );

    Terms memory bobTerms = TermsHelper.makeTerms(
      block.chainid,
      BOB,
      BOB_RECIPIENT,
      deadline,
      AssetHelper.makeNative(assetAmount).toArray()
    );

    // Complete commit phase
    vm.prank(ALICE);
    omnibus.commit{value: assetAmount}(lock, aliceTerms, bobTerms);
    vm.prank(BOB);
    omnibus.commit{value: assetAmount}(lock, bobTerms, aliceTerms);

    // First execute succeeds
    vm.prank(CHARLIE);
    omnibus.execute(SECRET, aliceTerms, bobTerms);
    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Spent));

    // Attacker tries execute AGAIN
    vm.expectRevert(IOmnibus.InvalidLockState.selector);
    vm.prank(ATTACKER);
    omnibus.execute(SECRET, aliceTerms, bobTerms);
  }

  // ============ Attack 2: Double-Spend Cross-Chain Attempt ============

  /// @notice Verify cross-chain execution is expected behavior, not double-spend
  function test_attack_doubleSpendCrossChain_independentLocks() public {
    bytes32 secret = keccak256('crosschain-secret');
    bytes32 crossLock = omnibus.exposed_generateLock(secret);
    uint64 deadline = uint64(block.timestamp + 1 days);
    uint256 tokenAAmount = 100 ether;
    uint256 tokenBAmount = 200 ether;

    // Mint tokens
    tokenA.mint(ALICE, tokenAAmount);
    tokenB.mint(BOB, tokenBAmount);

    // Create terms (same structs used on both chains)
    Terms memory aliceTerms = TermsHelper.makeTerms(
      CHAIN_A,
      ALICE,
      ALICE_RECIPIENT,
      deadline,
      AssetHelper.makeERC20(address(tokenA), tokenAAmount).toArray()
    );

    Terms memory bobTerms = TermsHelper.makeTerms(
      CHAIN_B,
      BOB,
      BOB_RECIPIENT,
      deadline,
      AssetHelper.makeERC20(address(tokenB), tokenBAmount).toArray()
    );

    // === COMMITS ===
    vm.chainId(CHAIN_A);
    vm.startPrank(ALICE);
    tokenA.approve(address(omnibusA), tokenAAmount);
    omnibusA.commit(crossLock, aliceTerms, bobTerms);
    vm.stopPrank();
    assertEq(uint8(omnibusA.lockState(crossLock)), uint8(LockState.Committed));
    assertEq(uint8(omnibusB.lockState(crossLock)), uint8(LockState.Unused)); // INDEPENDENT

    vm.chainId(CHAIN_B);
    vm.startPrank(BOB);
    tokenB.approve(address(omnibusB), tokenBAmount);
    omnibusB.commit(crossLock, bobTerms, aliceTerms);
    vm.stopPrank();
    assertEq(uint8(omnibusB.lockState(crossLock)), uint8(LockState.Committed));
    assertEq(uint8(omnibusA.lockState(crossLock)), uint8(LockState.Committed)); // unchanged

    // === EXECUTE ON CHAIN A ===
    vm.chainId(CHAIN_A);
    omnibusA.execute(secret, aliceTerms, bobTerms);
    assertEq(uint8(omnibusA.lockState(crossLock)), uint8(LockState.Spent));
    assertEq(uint8(omnibusB.lockState(crossLock)), uint8(LockState.Committed)); // STILL independent

    // === ATTEMPT "DOUBLE-SPEND" ON CHAIN A ===
    vm.expectRevert(IOmnibus.InvalidLockState.selector);
    omnibusA.execute(secret, aliceTerms, bobTerms);

    // === EXECUTE ON CHAIN B (expected, not double-spend) ===
    vm.chainId(CHAIN_B);
    omnibusB.execute(secret, bobTerms, aliceTerms);
    assertEq(uint8(omnibusB.lockState(crossLock)), uint8(LockState.Spent));

    // === ATTEMPT "DOUBLE-SPEND" ON CHAIN B ===
    vm.expectRevert(IOmnibus.InvalidLockState.selector);
    omnibusB.execute(secret, bobTerms, aliceTerms);

    // Verify: each chain exactly ONE execute succeeded
    assertEq(tokenA.balanceOf(BOB_RECIPIENT), tokenAAmount);
    assertEq(tokenB.balanceOf(ALICE_RECIPIENT), tokenBAmount);
  }

  // ============ Attack 3: Griefing Via Commitment Without Execution ============

  /// @notice Test griefing mitigated by reclaim before deadline
  function test_attack_griefingCommitNoExecute_victimCanReclaim() public {
    uint256 assetAmount = 1 ether;
    uint64 deadline = uint64(block.timestamp + 1 days);

    Terms memory aliceTerms = TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      deadline,
      AssetHelper.makeNative(assetAmount).toArray()
    );

    Terms memory bobTerms = TermsHelper.makeTerms(
      block.chainid,
      BOB,
      BOB_RECIPIENT,
      deadline,
      AssetHelper.makeNative(assetAmount).toArray()
    );

    // Alice commits
    vm.prank(ALICE);
    omnibus.commit{value: assetAmount}(lock, aliceTerms, bobTerms);

    // Bob commits (griefing: commits but never executes)
    vm.prank(BOB);
    omnibus.commit{value: assetAmount}(lock, bobTerms, aliceTerms);

    // Neither party executes (griefing attempt)
    // Warp to deadline, Alice reclaims
    vm.warp(deadline);
    uint256 aliceBalBefore = ALICE.balance;
    uint256 bobBalBefore = BOB.balance;

    vm.prank(ALICE);
    omnibus.reclaim(lock, aliceTerms, bobTerms);

    // Reclaim succeeds
    assertEq(ALICE.balance - aliceBalBefore, assetAmount);
    assertEq(BOB.balance - bobBalBefore, assetAmount);

    // Griefing mitigated - no permanent fund lock
  }

  // ============ Attack 5: Wrong Secret Execution ============

  /// @notice Test wrong secret execution fails
  function test_attack_wrongSecret_executeFails() public {
    uint256 assetAmount = 1 ether;
    uint64 deadline = uint64(block.timestamp + 1 days);

    Terms memory aliceTerms = TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      deadline,
      AssetHelper.makeNative(assetAmount).toArray()
    );

    Terms memory bobTerms = TermsHelper.makeTerms(
      block.chainid,
      BOB,
      BOB_RECIPIENT,
      deadline,
      AssetHelper.makeNative(assetAmount).toArray()
    );

    // Commit with lock = hash(CORRECT_SECRET)
    vm.prank(ALICE);
    omnibus.commit{value: assetAmount}(lock, aliceTerms, bobTerms);
    vm.prank(BOB);
    omnibus.commit{value: assetAmount}(lock, bobTerms, aliceTerms);

    // Attacker tries execute with WRONG_SECRET
    bytes32 wrongSecret = keccak256('wrong-secret');

    vm.expectRevert(IOmnibus.TermsMismatch.selector);
    vm.prank(ATTACKER);
    omnibus.execute(wrongSecret, aliceTerms, bobTerms);

    // Lock unchanged
    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Committed));
  }

  // ============ Attack 6: Terms Modification After Commit ============

  /// @notice Test modified terms after commit fails
  function test_attack_termsModification_executeFails() public {
    uint256 assetAmount = 1 ether;
    uint64 deadline = uint64(block.timestamp + 1 days);

    Terms memory aliceTerms = TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      deadline,
      AssetHelper.makeNative(assetAmount).toArray()
    );

    Terms memory bobTerms = TermsHelper.makeTerms(
      block.chainid,
      BOB,
      BOB_RECIPIENT,
      deadline,
      AssetHelper.makeNative(assetAmount).toArray()
    );

    // Commit with original terms
    vm.prank(ALICE);
    omnibus.commit{value: assetAmount}(lock, aliceTerms, bobTerms);
    vm.prank(BOB);
    omnibus.commit{value: assetAmount}(lock, bobTerms, aliceTerms);

    // Attacker tries execute with MODIFIED terms
    Terms memory modifiedAliceTerms = TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      deadline,
      AssetHelper.makeNative(1.5 ether).toArray() // Modified amount
    );

    vm.expectRevert(IOmnibus.TermsMismatch.selector);
    vm.prank(ATTACKER);
    omnibus.execute(SECRET, modifiedAliceTerms, bobTerms);
  }

  // ============ Attack 7: Replay Attack - Reuse Lock ============

  /// @notice Test replay attack with same lock after spent fails
  function test_attack_replayAttack_sameLockNewTerms_fails() public {
    uint256 assetAmount = 1 ether;
    uint64 deadline = uint64(block.timestamp + 1 days);

    Terms memory aliceTerms = TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      deadline,
      AssetHelper.makeNative(assetAmount).toArray()
    );

    Terms memory bobTerms = TermsHelper.makeTerms(
      block.chainid,
      BOB,
      BOB_RECIPIENT,
      deadline,
      AssetHelper.makeNative(assetAmount).toArray()
    );

    // Complete swap
    vm.prank(ALICE);
    omnibus.commit{value: assetAmount}(lock, aliceTerms, bobTerms);
    vm.prank(BOB);
    omnibus.commit{value: assetAmount}(lock, bobTerms, aliceTerms);
    omnibus.execute(SECRET, aliceTerms, bobTerms);
    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Spent));

    // Try commit with SAME lock but DIFFERENT terms
    uint64 newDeadline = uint64(block.timestamp + 2 days);
    Terms memory newTerms = TermsHelper.makeTerms(
      block.chainid,
      ATTACKER,
      ATTACKER,
      newDeadline,
      AssetHelper.makeNative(assetAmount).toArray()
    );

    vm.expectRevert(IOmnibus.InvalidLockAdvancement.selector);
    vm.prank(ATTACKER);
    omnibus.commit{value: assetAmount}(lock, newTerms, bobTerms);

    // Spent is terminal - lock cannot be reused
  }

}
