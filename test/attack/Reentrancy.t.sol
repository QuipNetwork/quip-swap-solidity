// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Test} from 'forge-std-1.14.0/Test.sol';

import {CommitAuth, LockState} from '../../src/interfaces/IOmnibus.sol';
import {Terms} from '../../src/legacy/TermsLib.sol';
import {OmnibusHarness} from '../harness/OmnibusHarness.sol';
import {VerifierMock} from '../mocks/VerifierMock.sol';
import {WalletFactoryMock} from '../mocks/WalletFactoryMock.sol';
import {AssetHelper} from '../utils/AssetHelper.sol';
import {AuthHelper} from '../utils/AuthHelper.sol';
import {TermsHelper} from '../utils/TermsHelper.sol';

/// @notice recipient that re-enters the omnibus once when it receives native, recording
/// whether the inner call succeeded; it never reverts itself so the outer payout completes
contract ReentrantRecipient {
  address public target;
  bytes public payload;
  bool public reentered;
  bool public innerSucceeded;

  function arm(address _target, bytes memory _payload) external {
    target = _target;
    payload = _payload;
  }

  receive() external payable {
    if (reentered || target == address(0)) return;
    reentered = true;
    (bool ok,) = target.call(payload);
    innerSucceeded = ok;
  }
}

/// @title Reentrancy
/// @dev claim and reclaim advance the lock to Spent BEFORE any asset leaves the contract.
/// These tests pin that ordering: a malicious native recipient re-enters mid-payout and the
/// inner call must fail on the already-spent lock, with nothing paid out twice.
contract Omnibus_Reentrancy is Test {
  using AssetHelper for *;
  using TermsHelper for *;

  // lifecycle deadlines (Alice = proposer, Bob = taker)
  uint256 constant A_COMMIT = 1000;
  uint256 constant B_COMMIT = 2000;
  uint256 constant A_CLAIM = 3000;
  uint256 constant B_CLAIM = 4000;
  uint256 constant A_RECLAIM = 5000;
  uint256 constant B_RECLAIM = 6000;

  uint256 constant AT_PROPOSER_COMMIT = 500;
  uint256 constant AT_TAKER_COMMIT = 1500;
  uint256 constant AT_PROPOSER_CLAIM = 2500;
  uint256 constant AT_PROPOSER_RECLAIM = 5500;

  uint256 constant ALICE_AMOUNT = 1 ether;
  uint256 constant BOB_AMOUNT = 2 ether;

  address public ALICE = makeAddr('alice');
  address public BOB = makeAddr('bob');
  address public BOB_RECIPIENT = makeAddr('bobRecipient');

  OmnibusHarness public omnibus;
  ReentrantRecipient public attacker;
  VerifierMock public verifier;

  bytes32 public constant SECRET = keccak256('secret');
  bytes32 public lock;

  function setUp() public {
    // commit is permissionless; each caller authenticates with its own keyed
    // ERC-7913 identity through an accept-all mock verifier
    verifier = new VerifierMock();
    omnibus = new OmnibusHarness(address(this), address(new WalletFactoryMock()));
    omnibus.setVerifierActivity(address(verifier), true);
    attacker = new ReentrantRecipient();
    lock = omnibus.exposed_generateLock(SECRET);

    vm.deal(ALICE, 100 ether);
    vm.deal(BOB, 100 ether);
  }

  /// @notice proposer terms; `recipient` and `reclaimRecipient` are parameterized so each
  /// test can plant the attacker on the payout leg it targets
  function _aliceTerms(address reclaimRecipient, address recipient) internal view returns (Terms memory) {
    return TermsHelper.makeTerms(
      block.chainid,
      reclaimRecipient,
      recipient,
      A_COMMIT,
      A_CLAIM,
      A_RECLAIM,
      AssetHelper.makeNative(ALICE_AMOUNT).toArray()
    );
  }

  function _bobTerms() internal view returns (Terms memory) {
    return TermsHelper.makeTerms(
      block.chainid, BOB, BOB_RECIPIENT, B_COMMIT, B_CLAIM, B_RECLAIM, AssetHelper.makeNative(BOB_AMOUNT).toArray()
    );
  }

  function _commitBoth(Terms memory alice, Terms memory bob) internal {
    vm.warp(AT_PROPOSER_COMMIT);
    vm.prank(ALICE);
    omnibus.commit{value: ALICE_AMOUNT}(lock, alice, bob, AuthHelper.keyedAuth(address(verifier), ALICE));

    vm.warp(AT_TAKER_COMMIT);
    vm.prank(BOB);
    omnibus.commit{value: BOB_AMOUNT}(lock, bob, alice, AuthHelper.keyedAuth(address(verifier), BOB));
  }

  /// @notice a claim recipient that re-enters claim mid-payout fails on the spent lock and
  /// cannot extract a second settlement
  function test_attack_reentrantClaimRecipient_cannotDoubleClaim() public {
    // the attacker sits as alice.recipient: it receives Bob's native first, before Alice's
    // leg pays out, so its re-entry fires while the outer claim is mid-flight
    Terms memory alice = _aliceTerms(ALICE, address(attacker));
    Terms memory bob = _bobTerms();

    _commitBoth(alice, bob);
    attacker.arm(address(omnibus), abi.encodeCall(omnibus.claim, (SECRET, alice, bob)));

    vm.warp(AT_PROPOSER_CLAIM);
    omnibus.claim(SECRET, alice, bob);

    // the re-entry ran and failed: the lock was already Spent when it fired
    assertTrue(attacker.reentered());
    assertFalse(attacker.innerSucceeded());

    // exactly one settlement: bob's leg -> attacker, alice's leg -> bob recipient
    assertEq(address(attacker).balance, BOB_AMOUNT);
    assertEq(BOB_RECIPIENT.balance, ALICE_AMOUNT);
    assertEq(address(omnibus).balance, 0);
    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Spent));
  }

  /// @notice a reclaim recipient that re-enters reclaim mid-refund fails on the spent lock
  /// and cannot extract a second refund
  function test_attack_reentrantReclaimRecipient_cannotDoubleReclaim() public {
    // the attacker sits as alice.reclaimRecipient; the counterparty (Bob) is refunded first,
    // then the attacker receives Alice's refund and re-enters
    Terms memory alice = _aliceTerms(address(attacker), ALICE);
    Terms memory bob = _bobTerms();

    _commitBoth(alice, bob);
    attacker.arm(address(omnibus), abi.encodeCall(omnibus.reclaim, (lock, alice, bob)));

    uint256 bobBalBefore = BOB.balance;

    vm.warp(AT_PROPOSER_RECLAIM);
    omnibus.reclaim(lock, alice, bob);

    // the re-entry ran and failed: the lock was already Spent when it fired
    assertTrue(attacker.reentered());
    assertFalse(attacker.innerSucceeded());

    // exactly one refund per side
    assertEq(address(attacker).balance, ALICE_AMOUNT);
    assertEq(BOB.balance - bobBalBefore, BOB_AMOUNT);
    assertEq(address(omnibus).balance, 0);
    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Spent));
  }
}
