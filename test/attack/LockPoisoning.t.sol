// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Test} from 'forge-std-1.14.0/Test.sol';

import {Terms} from '../../src/TermsLib.sol';
import {IOmnibus, LockState} from '../../src/interfaces/IOmnibus.sol';
import {OmnibusHarness} from '../harness/OmnibusHarness.sol';
import {AssetHelper} from '../utils/AssetHelper.sol';
import {TermsHelper} from '../utils/TermsHelper.sol';

/// @title Lock Poisoning (accepted, non-exploitable grief)
/// @dev The lock (`hash(secret)`) becomes public the moment the first party commits. Anyone
/// who learns it can front-run with the SAME lock but their own cheap, valid terms, setting
/// `termsHash[lock]` first and making the legitimate `commit` revert `TermsMismatch`. This is
/// pure griefing, NOT theft:
///   1. the attacker must escrow real assets, which they can fully reclaim after their window;
///   2. payouts always target addresses fixed in the (attacker's own) terms;
///   3. the victim simply retries with a fresh secret -> fresh lock, which the attacker cannot
///      predict ahead of time.
/// These tests pin that behavior so a future change that turns this into something worse is
/// caught.
contract Omnibus_LockPoisoning is Test {
  using AssetHelper for *;
  using TermsHelper for *;

  // lifecycle deadlines (proposer < taker, strictly interleaved)
  uint256 constant A_COMMIT = 1000;
  uint256 constant B_COMMIT = 2000;
  uint256 constant A_CLAIM = 3000;
  uint256 constant B_CLAIM = 4000;
  uint256 constant A_RECLAIM = 5000;
  uint256 constant B_RECLAIM = 6000;

  uint256 constant AT_PROPOSER_COMMIT = 500;

  address public ALICE = makeAddr('alice');
  address public BOB = makeAddr('bob');
  address public ATTACKER = makeAddr('attacker');
  address public ALICE_RECIPIENT = makeAddr('aliceRecipient');
  address public BOB_RECIPIENT = makeAddr('bobRecipient');

  OmnibusHarness public omnibus;

  bytes32 public constant SECRET = keccak256('secret');
  bytes32 public lock;

  function setUp() public {
    omnibus = new OmnibusHarness(address(this));
    lock = omnibus.exposed_generateLock(SECRET);
    vm.deal(ALICE, 100 ether);
    vm.deal(ATTACKER, 100 ether);
  }

  function _proposer(address reclaimRecipient, address recipient, uint256 amount) internal view returns (Terms memory) {
    return TermsHelper.makeTerms(
      block.chainid, reclaimRecipient, recipient, A_COMMIT, A_CLAIM, A_RECLAIM, AssetHelper.makeNative(amount).toArray()
    );
  }

  function _taker(address reclaimRecipient, address recipient, uint256 amount) internal view returns (Terms memory) {
    return TermsHelper.makeTerms(
      block.chainid, reclaimRecipient, recipient, B_COMMIT, B_CLAIM, B_RECLAIM, AssetHelper.makeNative(amount).toArray()
    );
  }

  /// @notice an attacker who commits the lock first with their own terms blocks the legitimate
  /// commit (TermsMismatch), but the victim sidesteps with a fresh lock and the attacker can
  /// reclaim their griefing escrow
  function test_lockPoisoning_blocksLegitCommit_butIsRecoverableAndSidesteppable() public {
    // attacker front-runs with a cheap, valid pairing bound to the SAME lock
    Terms memory attackerParty = _proposer(ATTACKER, ATTACKER, 1 wei);
    Terms memory attackerCounter = _taker(ATTACKER, ATTACKER, 1 wei);

    vm.warp(AT_PROPOSER_COMMIT);
    vm.prank(ATTACKER);
    omnibus.commit{value: 1 wei}(lock, attackerParty, attackerCounter);
    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Free));

    // the legitimate commit on the poisoned lock now reverts on the stored terms hash
    Terms memory alice = _proposer(ALICE, ALICE_RECIPIENT, 1 ether);
    Terms memory bob = _taker(BOB, BOB_RECIPIENT, 1 ether);

    vm.expectRevert(IOmnibus.TermsMismatch.selector);
    vm.prank(ALICE);
    omnibus.commit{value: 1 ether}(lock, alice, bob);

    // victim sidesteps with a fresh secret -> fresh lock (attacker cannot predict it)
    bytes32 freshLock = omnibus.exposed_generateLock(keccak256('alice-fresh-secret'));
    vm.prank(ALICE);
    omnibus.commit{value: 1 ether}(freshLock, alice, bob);
    assertEq(uint8(omnibus.lockState(freshLock)), uint8(LockState.Free));

    // the grief cost the attacker reclaimable capital: they recover it after their window
    vm.warp(A_RECLAIM + 1);
    uint256 attackerBalBefore = ATTACKER.balance;
    vm.prank(ATTACKER);
    omnibus.reclaim(lock, attackerParty, attackerCounter);
    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Spent));
    assertEq(ATTACKER.balance - attackerBalBefore, 1 wei);
  }
}
