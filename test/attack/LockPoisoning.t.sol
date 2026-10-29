// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Test} from 'forge-std-1.14.0/Test.sol';

import {Terms} from '../../src/TermsLib.sol';
import {CommitAuth, IOmnibus, LockState} from '../../src/interfaces/IOmnibus.sol';
import {OmnibusHarness} from '../harness/OmnibusHarness.sol';
import {VerifierMock} from '../mocks/VerifierMock.sol';
import {WalletFactoryMock} from '../mocks/WalletFactoryMock.sol';
import {AssetHelper} from '../utils/AssetHelper.sol';
import {AuthHelper} from '../utils/AuthHelper.sol';
import {TermsHelper} from '../utils/TermsHelper.sol';

/// @title Lock Poisoning (neutralized by swap-scoped state)
/// @dev The lock (`hash(secret)`) becomes public the moment the first party commits. Anyone
/// who learns it can commit the SAME lock with their own cheap, valid terms — but state is
/// keyed by swapId = hash(lock, canonicalTermsDigest), so such a pairing occupies its OWN
/// slot: it can neither block nor alter the negotiated swap. Occupying the victim's slot
/// would require committing the victim's exact terms, i.e. actually funding the real leg.
/// Before swap-scoped keys, the dust commit set `termsHash[lock]` first and made the
/// legitimate commit revert TermsMismatch; cross-chain the victim proposer was already
/// escrowed on the origin chain and could only wait out her reclaimRelease (the audited
/// grief). These tests pin the neutralization so a regression back to lock-keyed state is
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
  VerifierMock public verifier;

  bytes32 public constant SECRET = keccak256('secret');
  bytes32 public lock;

  function setUp() public {
    // commit is permissionless; each caller authenticates with its own keyed
    // ERC-7913 identity through an accept-all mock verifier
    verifier = new VerifierMock();
    omnibus = new OmnibusHarness(address(this), address(new WalletFactoryMock()));
    omnibus.setVerifierActivity(address(verifier), true);
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

  function _swapIdFor(bytes32 _lock, Terms memory a, Terms memory b) internal view returns (bytes32) {
    return omnibus.swapId(_lock, a, b);
  }

  /// @notice a dust pairing on the same lock lands in its own swap slot: the legitimate
  /// same-chain swap commits and settles untouched, and the attacker only ever moves their
  /// own dust
  function test_lockPoisoning_dustPairing_cannotBlockSameChainSwap() public {
    // attacker front-runs with a cheap, valid pairing bound to the SAME lock
    Terms memory attackerParty = _proposer(ATTACKER, ATTACKER, 1 wei);
    Terms memory attackerCounter = _taker(ATTACKER, ATTACKER, 1 wei);

    vm.warp(AT_PROPOSER_COMMIT);
    vm.prank(ATTACKER);
    omnibus.commit{value: 1 wei}(
      lock, attackerParty, attackerCounter, AuthHelper.keyedAuth(address(verifier), ATTACKER)
    );
    assertEq(uint8(omnibus.lockState(_swapIdFor(lock, attackerParty, attackerCounter))), uint8(LockState.Free));

    // the legitimate commit on the same lock proceeds under its own swap id
    Terms memory alice = _proposer(ALICE, ALICE_RECIPIENT, 1 ether);
    Terms memory bob = _taker(BOB, BOB_RECIPIENT, 1 ether);

    vm.prank(ALICE);
    omnibus.commit{value: 1 ether}(lock, alice, bob, AuthHelper.keyedAuth(address(verifier), ALICE));
    assertEq(uint8(omnibus.lockState(_swapIdFor(lock, alice, bob))), uint8(LockState.Free));

    // taker leg and settlement complete, untouched by the dust swap
    vm.deal(BOB, 1 ether);
    vm.warp(1500); // taker commit window [A_COMMIT, B_COMMIT)
    vm.prank(BOB);
    omnibus.commit{value: 1 ether}(lock, bob, alice, AuthHelper.keyedAuth(address(verifier), BOB));

    vm.warp(2500); // proposer claim window [B_COMMIT, A_CLAIM)
    omnibus.claim(SECRET, alice, bob);
    assertEq(uint8(omnibus.lockState(_swapIdFor(lock, alice, bob))), uint8(LockState.Spent));
    assertEq(ALICE_RECIPIENT.balance, 1 ether);
    assertEq(BOB_RECIPIENT.balance, 1 ether);

    // the attacker's dust swap stays isolated; they merely reclaim their own escrow later
    vm.warp(A_RECLAIM + 1);
    uint256 attackerBalBefore = ATTACKER.balance;
    vm.prank(ATTACKER);
    omnibus.reclaim(lock, attackerParty, attackerCounter);
    assertEq(uint8(omnibus.lockState(_swapIdFor(lock, attackerParty, attackerCounter))), uint8(LockState.Spent));
    assertEq(ATTACKER.balance - attackerBalBefore, 1 wei);
  }

  /// @notice REGRESSION (audit): the cross-chain grief. The proposer's origin-chain commit
  /// publishes the lock; the attacker poisons it on the destination chain before the taker
  /// commits there. With swap-scoped state the taker's commit lands Committed under the
  /// pairing's own swap id regardless
  function test_lockPoisoning_crossChain_takerCommitUnblocked() public {
    // attacker poisons the observed lock on this (destination) chain with a dust pairing
    Terms memory attackerParty = _proposer(ATTACKER, ATTACKER, 1 wei);
    Terms memory attackerCounter = _taker(ATTACKER, ATTACKER, 1 wei);
    vm.warp(AT_PROPOSER_COMMIT);
    vm.prank(ATTACKER);
    omnibus.commit{value: 1 wei}(
      lock, attackerParty, attackerCounter, AuthHelper.keyedAuth(address(verifier), ATTACKER)
    );

    // the real pairing: the proposer's leg lives on another chain, the taker's leg here
    Terms memory proposerRemote = TermsHelper.makeTerms(
      block.chainid + 1, ALICE, ALICE_RECIPIENT, A_COMMIT, A_CLAIM, A_RECLAIM, AssetHelper.makeNative(1 ether).toArray()
    );
    Terms memory takerLocal = _taker(BOB, BOB_RECIPIENT, 1 ether);

    // the taker commits the destination leg in the taker window; cross-chain advances
    // straight to Committed under its own swap id, despite the poisoned lock
    vm.deal(BOB, 1 ether);
    vm.warp(1500); // taker commit window [A_COMMIT, B_COMMIT)
    vm.prank(BOB);
    omnibus.commit{value: 1 ether}(lock, takerLocal, proposerRemote, AuthHelper.keyedAuth(address(verifier), BOB));
    assertEq(uint8(omnibus.lockState(_swapIdFor(lock, takerLocal, proposerRemote))), uint8(LockState.Committed));

    // the attacker's dust swap sits untouched in its own slot
    assertEq(uint8(omnibus.lockState(_swapIdFor(lock, attackerParty, attackerCounter))), uint8(LockState.Free));
  }
}
