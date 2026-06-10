// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Test} from 'forge-std-1.14.0/Test.sol';

import {Asset, Terms} from '../../../src/TermsLib.sol';
import {IOmnibus, LockState} from '../../../src/interfaces/IOmnibus.sol';
import {OmnibusHarness} from '../../harness/OmnibusHarness.sol';
import {ERC20Mock} from '../../mocks/ERC20Mock.sol';
import {QuipFactoryMock} from '../../mocks/QuipFactoryMock.sol';
import {AssetHelper} from '../../utils/AssetHelper.sol';
import {TermsHelper} from '../../utils/TermsHelper.sol';

/// @title Omnibus Attack Scenarios
/// @dev Security regressions under the windowed timing model. Alice is the proposer, Bob the
///      taker; deadlines strictly interleave
///        A_COMMIT < B_COMMIT < A_CLAIM < B_CLAIM < A_RECLAIM < B_RECLAIM
///      and each action runs at its window anchor. These pin double-spend, wrong-secret,
///      tampered-terms, griefing-recovery, and spent-lock-replay protections.
contract Omnibus_AttackScenarios is Test {
  using AssetHelper for *;
  using TermsHelper for *;

  // ============ Constants ============

  uint256 constant CHAIN_A = 1;
  uint256 constant CHAIN_B = 137;

  // lifecycle deadlines (Alice = proposer, Bob = taker)
  uint256 constant A_COMMIT = 1000;
  uint256 constant B_COMMIT = 2000;
  uint256 constant A_CLAIM = 3000;
  uint256 constant B_CLAIM = 4000;
  uint256 constant A_RECLAIM = 5000;
  uint256 constant B_RECLAIM = 6000;

  // action time anchors (each strictly inside its window)
  uint256 constant AT_PROPOSER_COMMIT = 500;
  uint256 constant AT_TAKER_COMMIT = 1500;
  uint256 constant AT_PROPOSER_CLAIM = 2500;
  uint256 constant AT_TAKER_CLAIM = 3500;
  uint256 constant AT_PROPOSER_RECLAIM = 5500;

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
  ERC20Mock public tokenA;
  ERC20Mock public tokenB;
  QuipFactoryMock public quipFactory;

  // ============ Test Data ============

  bytes32 public constant SECRET = keccak256('secret');
  bytes32 public lock;

  // ============ Setup ============

  function setUp() public virtual {
    // commit is gated to factory-deployed quip wallets; the attacker is registered too
    // since these scenarios pin protections that hold even against quip wallets
    quipFactory = new QuipFactoryMock();
    _registerQuipWallet(ALICE);
    _registerQuipWallet(BOB);
    _registerQuipWallet(ATTACKER);

    omnibus = new OmnibusHarness(address(this), address(quipFactory));
    omnibusA = new OmnibusHarness(address(this), address(quipFactory));
    omnibusB = new OmnibusHarness(address(this), address(quipFactory));
    tokenA = new ERC20Mock('TokenA', 'TKA', 18);
    tokenB = new ERC20Mock('TokenB', 'TKB', 18);

    lock = omnibus.exposed_generateLock(SECRET);

    vm.deal(ALICE, 100 ether);
    vm.deal(BOB, 100 ether);
    vm.deal(CHARLIE, 100 ether);
    vm.deal(ATTACKER, 100 ether);
  }

  /// @notice register `wallet` in the factory mock so it passes the onlyQuipWallet gate
  function _registerQuipWallet(address wallet) internal {
    quipFactory.registerWallet(wallet, bytes32(uint256(uint160(wallet))), wallet);
  }

  // ============ Terms Builders ============

  function _alice(uint256 chainId, Asset[] memory assets) internal view returns (Terms memory) {
    return TermsHelper.makeTerms(chainId, ALICE, ALICE_RECIPIENT, A_COMMIT, A_CLAIM, A_RECLAIM, assets);
  }

  function _bob(uint256 chainId, Asset[] memory assets) internal view returns (Terms memory) {
    return TermsHelper.makeTerms(chainId, BOB, BOB_RECIPIENT, B_COMMIT, B_CLAIM, B_RECLAIM, assets);
  }

  function _commitBothSameChainNative(uint256 amount)
    internal
    returns (Terms memory aliceTerms, Terms memory bobTerms)
  {
    aliceTerms = _alice(block.chainid, AssetHelper.makeNative(amount).toArray());
    bobTerms = _bob(block.chainid, AssetHelper.makeNative(amount).toArray());

    vm.warp(AT_PROPOSER_COMMIT);
    vm.prank(ALICE);
    omnibus.commit{value: amount}(lock, aliceTerms, bobTerms);

    vm.warp(AT_TAKER_COMMIT);
    vm.prank(BOB);
    omnibus.commit{value: amount}(lock, bobTerms, aliceTerms);

    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Committed));
  }

  // ============ Attack 1: Double-Spend Same Chain ============

  /// @notice a second claim on a settled same-chain lock reverts (Spent is terminal)
  function test_attack_doubleSpendSameChain_secondClaimFails() public {
    (Terms memory aliceTerms, Terms memory bobTerms) = _commitBothSameChainNative(1 ether);

    vm.warp(AT_PROPOSER_CLAIM);
    vm.prank(CHARLIE);
    omnibus.claim(SECRET, aliceTerms, bobTerms);
    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Spent));

    // attacker tries to claim AGAIN within the same window
    vm.expectRevert(IOmnibus.InvalidLockState.selector);
    vm.prank(ATTACKER);
    omnibus.claim(SECRET, aliceTerms, bobTerms);
  }

  // ============ Attack 2: Cross-Chain Independent Locks (no double-spend) ============

  /// @notice each chain holds an independent lock; exactly one claim settles per chain and a
  ///         replay on either chain reverts
  function test_attack_doubleSpendCrossChain_independentLocks() public {
    bytes32 secret = keccak256('crosschain-secret');
    bytes32 crossLock = omnibus.exposed_generateLock(secret);
    uint256 tokenAAmount = 100 ether;
    uint256 tokenBAmount = 200 ether;

    tokenA.mint(ALICE, tokenAAmount);
    tokenB.mint(BOB, tokenBAmount);

    Terms memory aliceTerms = _alice(CHAIN_A, AssetHelper.makeERC20(address(tokenA), tokenAAmount).toArray());
    Terms memory bobTerms = _bob(CHAIN_B, AssetHelper.makeERC20(address(tokenB), tokenBAmount).toArray());

    // commits on each chain
    vm.chainId(CHAIN_A);
    vm.warp(AT_PROPOSER_COMMIT);
    vm.startPrank(ALICE);
    tokenA.approve(address(omnibusA), tokenAAmount);
    omnibusA.commit(crossLock, aliceTerms, bobTerms);
    vm.stopPrank();
    assertEq(uint8(omnibusA.lockState(crossLock)), uint8(LockState.Committed));
    assertEq(uint8(omnibusB.lockState(crossLock)), uint8(LockState.Unused)); // independent

    vm.chainId(CHAIN_B);
    vm.warp(AT_TAKER_COMMIT);
    vm.startPrank(BOB);
    tokenB.approve(address(omnibusB), tokenBAmount);
    omnibusB.commit(crossLock, bobTerms, aliceTerms);
    vm.stopPrank();
    assertEq(uint8(omnibusB.lockState(crossLock)), uint8(LockState.Committed));
    assertEq(uint8(omnibusA.lockState(crossLock)), uint8(LockState.Committed)); // unchanged

    // proposer reveals on Chain B (proposer-claim window), settling Bob's leg
    vm.chainId(CHAIN_B);
    vm.warp(AT_PROPOSER_CLAIM);
    omnibusB.claim(secret, aliceTerms, bobTerms);
    assertEq(uint8(omnibusB.lockState(crossLock)), uint8(LockState.Spent));
    assertEq(uint8(omnibusA.lockState(crossLock)), uint8(LockState.Committed)); // still independent

    // replay on Chain B reverts
    vm.expectRevert(IOmnibus.InvalidLockState.selector);
    omnibusB.claim(secret, aliceTerms, bobTerms);

    // taker claims on Chain A with the revealed secret (taker-claim window)
    vm.chainId(CHAIN_A);
    vm.warp(AT_TAKER_CLAIM);
    omnibusA.claim(secret, bobTerms, aliceTerms);
    assertEq(uint8(omnibusA.lockState(crossLock)), uint8(LockState.Spent));

    // replay on Chain A reverts
    vm.expectRevert(IOmnibus.InvalidLockState.selector);
    omnibusA.claim(secret, bobTerms, aliceTerms);

    // exactly one settlement per chain
    assertEq(tokenA.balanceOf(BOB_RECIPIENT), tokenAAmount);
    assertEq(tokenB.balanceOf(ALICE_RECIPIENT), tokenBAmount);
  }

  // ============ Attack 3: Griefing Via Commit Without Claim ============

  /// @notice a counterparty that commits then never claims cannot lock funds permanently:
  ///         the proposer reclaim after release refunds both sides
  function test_attack_griefingCommitNoClaim_victimCanReclaim() public {
    (Terms memory aliceTerms, Terms memory bobTerms) = _commitBothSameChainNative(1 ether);

    vm.warp(AT_PROPOSER_RECLAIM);
    uint256 aliceBalBefore = ALICE.balance;
    uint256 bobBalBefore = BOB.balance;

    vm.prank(ALICE);
    omnibus.reclaim(lock, aliceTerms, bobTerms);

    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Spent));
    assertEq(ALICE.balance - aliceBalBefore, 1 ether);
    assertEq(BOB.balance - bobBalBefore, 1 ether);
    assertEq(address(omnibus).balance, 0);
  }

  // ============ Attack 4: Wrong Secret ============

  /// @notice claiming with a wrong secret derives a different (unused) lock and reverts
  function test_attack_wrongSecret_claimFails() public {
    (Terms memory aliceTerms, Terms memory bobTerms) = _commitBothSameChainNative(1 ether);

    bytes32 wrongSecret = keccak256('wrong-secret');

    vm.warp(AT_PROPOSER_CLAIM);
    vm.expectRevert(IOmnibus.TermsMismatch.selector);
    vm.prank(ATTACKER);
    omnibus.claim(wrongSecret, aliceTerms, bobTerms);

    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Committed));
  }

  // ============ Attack 5: Terms Modification After Commit ============

  /// @notice claiming with tampered terms breaks the stored canonical digest and reverts
  function test_attack_termsModification_claimFails() public {
    (Terms memory aliceTerms, Terms memory bobTerms) = _commitBothSameChainNative(1 ether);

    // attacker inflates Alice's declared amount
    Terms memory modifiedAlice = _alice(block.chainid, AssetHelper.makeNative(1.5 ether).toArray());

    vm.warp(AT_PROPOSER_CLAIM);
    vm.expectRevert(IOmnibus.TermsMismatch.selector);
    vm.prank(ATTACKER);
    omnibus.claim(SECRET, modifiedAlice, bobTerms);

    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Committed));
  }

  // ============ Attack 6: Replay - Reuse Spent Lock ============

  /// @notice a settled (Spent) lock is terminal: re-committing it with fresh, later-scheduled
  ///         terms reverts at the state machine
  function test_attack_replay_spentLockCannotBeReused() public {
    (Terms memory aliceTerms, Terms memory bobTerms) = _commitBothSameChainNative(1 ether);

    vm.warp(AT_PROPOSER_CLAIM);
    omnibus.claim(SECRET, aliceTerms, bobTerms);
    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Spent));

    // attacker builds a valid, later-scheduled pairing reusing the SAME (spent) lock
    Terms memory replayParty = TermsHelper.makeTerms(
      block.chainid, ATTACKER, ATTACKER, 10_000, 12_000, 14_000, AssetHelper.makeNative(1 ether).toArray()
    );
    Terms memory replayCounter = TermsHelper.makeTerms(
      block.chainid, ATTACKER, ATTACKER, 11_000, 13_000, 15_000, AssetHelper.makeNative(1 ether).toArray()
    );

    vm.warp(9000); // inside the replay party's commit window [0, 10_000)
    vm.expectRevert(IOmnibus.InvalidLockAdvancement.selector);
    vm.prank(ATTACKER);
    omnibus.commit{value: 1 ether}(lock, replayParty, replayCounter);

    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Spent));
  }
}
