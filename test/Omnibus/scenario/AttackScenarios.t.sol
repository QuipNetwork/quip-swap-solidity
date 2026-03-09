// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Test} from 'forge-std-1.14.0/Test.sol';

import {Asset, Terms, TermsLib} from '../../../src/TermsLib.sol';
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

    lock = TermsLib.generateLock(SECRET);

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

    // Complete commit phase
    vm.prank(ALICE);
    omnibus.commit{value: assetAmount + collateralAmount}(lock, aliceTerms, bobTerms);
    vm.prank(BOB);
    omnibus.commit{value: assetAmount + collateralAmount}(lock, bobTerms, aliceTerms);

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
    bytes32 crossLock = TermsLib.generateLock(secret);
    uint64 deadline = uint64(block.timestamp + 1 days);
    uint256 tokenAAmount = 100 ether;
    uint256 tokenBAmount = 200 ether;
    uint256 collateralAmount = 0.1 ether;

    // Mint tokens
    tokenA.mint(ALICE, tokenAAmount);
    tokenB.mint(BOB, tokenBAmount);

    // Create terms (same structs used on both chains)
    Terms memory aliceTerms = TermsHelper.makeTerms(
      CHAIN_A,
      ALICE,
      ALICE_RECIPIENT,
      deadline,
      AssetHelper.makeNative(collateralAmount),
      AssetHelper.makeERC20(address(tokenA), tokenAAmount).toArray()
    );

    Terms memory bobTerms = TermsHelper.makeTerms(
      CHAIN_B,
      BOB,
      BOB_RECIPIENT,
      deadline,
      AssetHelper.makeNative(collateralAmount),
      AssetHelper.makeERC20(address(tokenB), tokenBAmount).toArray()
    );

    // === COMMITS ===
    vm.chainId(CHAIN_A);
    vm.startPrank(ALICE);
    tokenA.approve(address(omnibusA), tokenAAmount);
    omnibusA.commit{value: collateralAmount}(crossLock, aliceTerms, bobTerms);
    vm.stopPrank();
    assertEq(uint8(omnibusA.lockState(crossLock)), uint8(LockState.Committed));
    assertEq(uint8(omnibusB.lockState(crossLock)), uint8(LockState.Unused)); // INDEPENDENT

    vm.chainId(CHAIN_B);
    vm.startPrank(BOB);
    tokenB.approve(address(omnibusB), tokenBAmount);
    omnibusB.commit{value: collateralAmount}(crossLock, bobTerms, aliceTerms);
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

  // ============ Attack 3: Front-Run Execute With Slash Before Deadline ============

  /// @notice Test slash attempt before deadline fails
  function test_attack_frontrunExecuteWithSlash_slashFails() public {
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
      deadline + 1 days, // Bob has longer deadline
      AssetHelper.makeNative(collateralAmount),
      AssetHelper.makeNative(assetAmount).toArray()
    );

    // Commit both
    vm.prank(ALICE);
    omnibus.commit{value: assetAmount + collateralAmount}(lock, aliceTerms, bobTerms);
    vm.prank(BOB);
    omnibus.commit{value: assetAmount + collateralAmount}(lock, bobTerms, aliceTerms);

    // Warp to just before deadline
    vm.warp(deadline - 1);

    // Attacker attempts slash (front-running hypothetical execute)
    vm.expectRevert(TermsLib.TermsNotExpired.selector);
    vm.prank(ATTACKER);
    omnibus.slash(lock, aliceTerms, bobTerms);

    // Execute would still succeed at this time
    omnibus.execute(SECRET, aliceTerms, bobTerms);
    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Spent));
  }

  // ============ Attack 4: Front-Run Execute At Deadline Boundary ============

  /// @notice Test at exact deadline: execute fails, slash succeeds
  function test_attack_frontrunExecuteWithSlash_atDeadline() public {
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

    // Commit both
    vm.prank(ALICE);
    omnibus.commit{value: assetAmount + collateralAmount}(lock, aliceTerms, bobTerms);
    vm.prank(BOB);
    omnibus.commit{value: assetAmount + collateralAmount}(lock, bobTerms, aliceTerms);

    // Warp to EXACTLY Alice's deadline
    vm.warp(aliceDeadline);

    // Execute fails
    vm.expectRevert(TermsLib.TermsExpired.selector);
    omnibus.execute(SECRET, aliceTerms, bobTerms);

    // Slash succeeds
    uint256 bobRecipientBefore = BOB_RECIPIENT.balance;
    omnibus.slash(lock, aliceTerms, bobTerms);
    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Spent));
    assertEq(BOB_RECIPIENT.balance - bobRecipientBefore, collateralAmount);
  }

  // ============ Attack 5: Reclaim After Cross-Chain Execute (Alice Cheats) ============

  /// @notice Document cross-chain atomicity limitation and collateral defense
  function test_attack_reclaimAfterCrossChainExecute_aliceCheats() public {
    bytes32 secret = keccak256('cheat-secret');
    bytes32 cheatLock = TermsLib.generateLock(secret);
    uint64 aliceDeadline = uint64(block.timestamp + 2 days);
    uint64 bobDeadline = uint64(block.timestamp + 1 days);
    uint256 tokenAAmount = 100 ether;
    uint256 tokenBAmount = 200 ether;
    uint256 collateralAmount = 0.1 ether;

    // Mint tokens
    tokenA.mint(ALICE, tokenAAmount);
    tokenB.mint(BOB, tokenBAmount);

    // Create terms (Alice has LONGER deadline - she's proposer)
    Terms memory aliceTerms = TermsHelper.makeTerms(
      CHAIN_A,
      ALICE,
      ALICE_RECIPIENT,
      aliceDeadline,
      AssetHelper.makeNative(collateralAmount),
      AssetHelper.makeERC20(address(tokenA), tokenAAmount).toArray()
    );

    Terms memory bobTerms = TermsHelper.makeTerms(
      CHAIN_B,
      BOB,
      BOB_RECIPIENT,
      bobDeadline,
      AssetHelper.makeNative(collateralAmount),
      AssetHelper.makeERC20(address(tokenB), tokenBAmount).toArray()
    );

    // === COMMITS ===
    vm.chainId(CHAIN_A);
    vm.startPrank(ALICE);
    tokenA.approve(address(omnibusA), tokenAAmount);
    omnibusA.commit{value: collateralAmount}(cheatLock, aliceTerms, bobTerms);
    vm.stopPrank();
    assertEq(uint8(omnibusA.lockState(cheatLock)), uint8(LockState.Committed));
    assertEq(uint8(omnibusB.lockState(cheatLock)), uint8(LockState.Unused));

    vm.chainId(CHAIN_B);
    vm.startPrank(BOB);
    tokenB.approve(address(omnibusB), tokenBAmount);
    omnibusB.commit{value: collateralAmount}(cheatLock, bobTerms, aliceTerms);
    vm.stopPrank();
    assertEq(uint8(omnibusB.lockState(cheatLock)), uint8(LockState.Committed));
    assertEq(uint8(omnibusA.lockState(cheatLock)), uint8(LockState.Committed));

    // === BOB EXECUTES ON CHAIN B (reveals secret) ===
    vm.chainId(CHAIN_B);
    uint256 aliceRecipientBefore = tokenB.balanceOf(ALICE_RECIPIENT);
    omnibusB.execute(secret, bobTerms, aliceTerms);
    assertEq(uint8(omnibusB.lockState(cheatLock)), uint8(LockState.Spent));
    assertEq(uint8(omnibusA.lockState(cheatLock)), uint8(LockState.Committed)); // STILL independent
    assertEq(tokenB.balanceOf(ALICE_RECIPIENT) - aliceRecipientBefore, tokenBAmount);

    // === ALICE ATTEMPTS TO CHEAT: RECLAIM ON CHAIN A ===
    vm.chainId(CHAIN_A);
    uint256 aliceTokenBefore = tokenA.balanceOf(ALICE);
    uint256 aliceEthBefore = ALICE.balance;

    vm.prank(ALICE);
    omnibusA.reclaim(cheatLock, aliceTerms, bobTerms);

    // Reclaim SUCCEEDS (lock on A is still Committed!)
    assertEq(tokenA.balanceOf(ALICE) - aliceTokenBefore, tokenAAmount);
    assertEq(ALICE.balance - aliceEthBefore, collateralAmount);

    // === VERIFY FINAL STATE (ALICE CHEATED) ===
    // Alice has: her 100 tokenA (reclaimed) + Bob's 200 tokenB (executed) = PROFIT
    // Bob has: only his collateral returned, lost 200 tokenB = LOSS
    // State independence ENABLED the cheat

    // === PROTOCOL'S DEFENSE: BOB SHOULD HAVE SLASHED ===
    // This scenario documents: proper deadline ordering is critical
    // proposer (Alice) deadline < acceptor (Bob) deadline prevents this attack
  }

  // ============ Attack 6: Griefing Via Commitment Without Execution ============

  /// @notice Test griefing mitigated by reclaim before deadline
  function test_attack_griefingCommitNoExecute_victimCanReclaim() public {
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

    // Bob commits (griefing: commits but never executes)
    vm.prank(BOB);
    omnibus.commit{value: assetAmount + collateralAmount}(lock, bobTerms, aliceTerms);

    // Neither party executes (griefing attempt)
    // Before deadline, Alice reclaims
    uint256 aliceBalBefore = ALICE.balance;
    uint256 bobBalBefore = BOB.balance;

    vm.prank(ALICE);
    omnibus.reclaim(lock, aliceTerms, bobTerms);

    // Reclaim succeeds
    assertEq(ALICE.balance - aliceBalBefore, assetAmount + collateralAmount);
    assertEq(BOB.balance - bobBalBefore, assetAmount + collateralAmount);

    // Griefing mitigated - no permanent fund lock
  }

  // ============ Attack 7: Griefing Past Deadline - Slash Required ============

  /// @notice Test griefing past deadline requires slash for recovery
  function test_attack_griefingCommitNoExecute_pastDeadline_slashRequired() public {
    uint256 assetAmount = 1 ether;
    uint256 collateralAmount = 0.1 ether;
    uint64 aliceDeadline = uint64(block.timestamp + 1 days);  // shorter
    uint64 bobDeadline = uint64(block.timestamp + 2 days);    // longer

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

    // Both commit
    vm.prank(ALICE);
    omnibus.commit{value: assetAmount + collateralAmount}(lock, aliceTerms, bobTerms);
    vm.prank(BOB);
    omnibus.commit{value: assetAmount + collateralAmount}(lock, bobTerms, aliceTerms);

    // Warp past Alice's deadline
    vm.warp(aliceDeadline);

    // Alice cannot reclaim (deadline passed)
    vm.expectRevert(TermsLib.TermsExpired.selector);
    vm.prank(ALICE);
    omnibus.reclaim(lock, aliceTerms, bobTerms);

    // Alice cannot execute (deadline passed)
    vm.expectRevert(TermsLib.TermsExpired.selector);
    omnibus.execute(SECRET, aliceTerms, bobTerms);

    // Anyone can slash Alice
    uint256 bobRecipientBefore = BOB_RECIPIENT.balance;
    uint256 bobBalBefore = BOB.balance;
    uint256 aliceBalBefore = ALICE.balance;

    vm.prank(CHARLIE);
    omnibus.slash(lock, aliceTerms, bobTerms);

    // Bob gets Alice's collateral (punishment)
    assertEq(BOB_RECIPIENT.balance - bobRecipientBefore, collateralAmount);
    // Bob gets his assets back
    assertEq(BOB.balance - bobBalBefore, assetAmount + collateralAmount);
    // Alice gets her assets back (no swap)
    assertEq(ALICE.balance - aliceBalBefore, assetAmount);
  }

  // ============ Attack 8: Wrong Secret Execution ============

  /// @notice Test wrong secret execution fails
  function test_attack_wrongSecret_executeFails() public {
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

    // Commit with lock = hash(CORRECT_SECRET)
    vm.prank(ALICE);
    omnibus.commit{value: assetAmount + collateralAmount}(lock, aliceTerms, bobTerms);
    vm.prank(BOB);
    omnibus.commit{value: assetAmount + collateralAmount}(lock, bobTerms, aliceTerms);

    // Attacker tries execute with WRONG_SECRET
    bytes32 wrongSecret = keccak256('wrong-secret');

    vm.expectRevert(IOmnibus.TermsMismatch.selector);
    vm.prank(ATTACKER);
    omnibus.execute(wrongSecret, aliceTerms, bobTerms);

    // Lock unchanged
    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Committed));
  }

  // ============ Attack 9: Terms Modification After Commit ============

  /// @notice Test modified terms after commit fails
  function test_attack_termsModification_executeFails() public {
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

    // Commit with original terms
    vm.prank(ALICE);
    omnibus.commit{value: assetAmount + collateralAmount}(lock, aliceTerms, bobTerms);
    vm.prank(BOB);
    omnibus.commit{value: assetAmount + collateralAmount}(lock, bobTerms, aliceTerms);

    // Attacker tries execute with MODIFIED terms
    Terms memory modifiedAliceTerms = TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      deadline,
      AssetHelper.makeNative(collateralAmount),
      AssetHelper.makeNative(1.5 ether).toArray() // Modified amount
    );

    vm.expectRevert(IOmnibus.TermsMismatch.selector);
    vm.prank(ATTACKER);
    omnibus.execute(SECRET, modifiedAliceTerms, bobTerms);
  }

  // ============ Attack 10: Replay Attack - Reuse Lock ============

  /// @notice Test replay attack with same lock after spent fails
  function test_attack_replayAttack_sameLockNewTerms_fails() public {
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

    // Complete swap
    vm.prank(ALICE);
    omnibus.commit{value: assetAmount + collateralAmount}(lock, aliceTerms, bobTerms);
    vm.prank(BOB);
    omnibus.commit{value: assetAmount + collateralAmount}(lock, bobTerms, aliceTerms);
    omnibus.execute(SECRET, aliceTerms, bobTerms);
    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Spent));

    // Try commit with SAME lock but DIFFERENT terms
    uint64 newDeadline = uint64(block.timestamp + 2 days);
    Terms memory newTerms = TermsHelper.makeTerms(
      block.chainid,
      ATTACKER,
      ATTACKER,
      newDeadline,
      AssetHelper.makeNative(collateralAmount),
      AssetHelper.makeNative(assetAmount).toArray()
    );

    vm.expectRevert(IOmnibus.InvalidLockAdvancement.selector);
    vm.prank(ATTACKER);
    omnibus.commit{value: assetAmount + collateralAmount}(lock, newTerms, bobTerms);

    // Spent is terminal - lock cannot be reused
  }

  // ============ Attack 11: Race Condition - Execute vs Slash ============

  /// @notice Test race condition: first operation wins
  function test_attack_raceCondition_executeVsSlash_firstWins() public {
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

    // Commit both
    vm.prank(ALICE);
    omnibus.commit{value: assetAmount + collateralAmount}(lock, aliceTerms, bobTerms);
    vm.prank(BOB);
    omnibus.commit{value: assetAmount + collateralAmount}(lock, bobTerms, aliceTerms);

    // At exact deadline: slash wins, execute fails
    vm.warp(aliceDeadline);

    // Slash first (succeeds)
    omnibus.slash(lock, aliceTerms, bobTerms);
    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Spent));

    // Execute second fails - deadline already passed so TermsExpired,
    // but even if it weren't, lock is Spent
    vm.expectRevert(TermsLib.TermsExpired.selector);
    omnibus.execute(SECRET, aliceTerms, bobTerms);
  }

  // ============ Attack 12: Zero Collateral Attack ============

  /// @notice Test zero collateral is rejected
  function test_attack_zeroCollateral_rejected() public {
    uint256 assetAmount = 1 ether;
    uint64 deadline = uint64(block.timestamp + 1 days);

    // Try to create terms with zero collateral
    Terms memory zeroCollateralTerms = TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      deadline,
      AssetHelper.makeNative(0), // Zero collateral
      AssetHelper.makeNative(assetAmount).toArray()
    );

    Terms memory bobTerms = TermsHelper.makeTerms(
      block.chainid,
      BOB,
      BOB_RECIPIENT,
      deadline,
      AssetHelper.makeNative(0.1 ether),
      AssetHelper.makeNative(assetAmount).toArray()
    );

    // Commit should fail with ZeroAmount
    vm.expectRevert(TermsLib.ZeroAmount.selector);
    vm.prank(ALICE);
    omnibus.commit{value: assetAmount}(lock, zeroCollateralTerms, bobTerms);
  }

  // ============ Attack 13: Cross-Chain Deadline Asymmetry ============

  /// @notice Document mutual destruction from misconfigured deadlines
  function test_attack_crossChainDeadlineAsymmetry_mutualDestruction() public {
    bytes32 secret = keccak256('asymmetry-secret');
    bytes32 asymLock = TermsLib.generateLock(secret);
    uint64 aliceDeadline = uint64(block.timestamp + 1 days);    // Alice's deadline
    uint64 bobDeadline = uint64(block.timestamp + 12 hours);    // Bob's deadline (SHORTER - misconfig!)
    uint256 tokenAAmount = 100 ether;
    uint256 tokenBAmount = 200 ether;
    uint256 collateralAmount = 0.5 ether;

    // Mint tokens
    tokenA.mint(ALICE, tokenAAmount);
    tokenB.mint(BOB, tokenBAmount);

    // Create terms (MISCONFIGURED: Bob's deadline < Alice's)
    Terms memory aliceTerms = TermsHelper.makeTerms(
      CHAIN_A,
      ALICE,
      ALICE_RECIPIENT,
      aliceDeadline,
      AssetHelper.makeNative(collateralAmount),
      AssetHelper.makeERC20(address(tokenA), tokenAAmount).toArray()
    );

    Terms memory bobTerms = TermsHelper.makeTerms(
      CHAIN_B,
      BOB,
      BOB_RECIPIENT,
      bobDeadline,
      AssetHelper.makeNative(collateralAmount),
      AssetHelper.makeERC20(address(tokenB), tokenBAmount).toArray()
    );

    // === COMMITS ===
    vm.chainId(CHAIN_A);
    vm.startPrank(ALICE);
    tokenA.approve(address(omnibusA), tokenAAmount);
    omnibusA.commit{value: collateralAmount}(asymLock, aliceTerms, bobTerms);
    vm.stopPrank();
    assertEq(uint8(omnibusA.lockState(asymLock)), uint8(LockState.Committed));
    assertEq(uint8(omnibusB.lockState(asymLock)), uint8(LockState.Unused));

    vm.chainId(CHAIN_B);
    vm.startPrank(BOB);
    tokenB.approve(address(omnibusB), tokenBAmount);
    omnibusB.commit{value: collateralAmount}(asymLock, bobTerms, aliceTerms);
    vm.stopPrank();
    assertEq(uint8(omnibusB.lockState(asymLock)), uint8(LockState.Committed));
    assertEq(uint8(omnibusA.lockState(asymLock)), uint8(LockState.Committed));

    // === TIME PASSES: BOB'S DEADLINE EXPIRES FIRST ===
    vm.warp(bobDeadline);

    // === SLASH BOB ON CHAIN B ===
    vm.chainId(CHAIN_B);
    uint256 aliceRecipientBefore = ALICE_RECIPIENT.balance;
    uint256 bobTokenBefore = tokenB.balanceOf(BOB);

    omnibusB.slash(asymLock, bobTerms, aliceTerms);

    assertEq(uint8(omnibusB.lockState(asymLock)), uint8(LockState.Spent));
    assertEq(uint8(omnibusA.lockState(asymLock)), uint8(LockState.Committed)); // STILL independent
    assertEq(ALICE_RECIPIENT.balance - aliceRecipientBefore, collateralAmount); // Alice gets Bob's collateral
    assertEq(tokenB.balanceOf(BOB) - bobTokenBefore, tokenBAmount); // Bob gets his tokens back

    // === TIME PASSES: ALICE'S DEADLINE EXPIRES ===
    vm.warp(aliceDeadline);

    // === SLASH ALICE ON CHAIN A ===
    vm.chainId(CHAIN_A);
    uint256 bobRecipientBefore = BOB_RECIPIENT.balance;
    uint256 aliceTokenBefore = tokenA.balanceOf(ALICE);

    omnibusA.slash(asymLock, aliceTerms, bobTerms);

    assertEq(uint8(omnibusA.lockState(asymLock)), uint8(LockState.Spent));
    assertEq(BOB_RECIPIENT.balance - bobRecipientBefore, collateralAmount); // Bob gets Alice's collateral
    assertEq(tokenA.balanceOf(ALICE) - aliceTokenBefore, tokenAAmount); // Alice gets her tokens back

    // === VERIFY FINAL STATE: MUTUAL DESTRUCTION ===
    // Alice: kept tokenA + got Bob's collateral - lost her collateral = NET 0
    // Bob: kept tokenB + got Alice's collateral - lost his collateral = NET 0
    // Neither party completed the swap
    // Deadline asymmetry led to mutual slashing
  }
}
