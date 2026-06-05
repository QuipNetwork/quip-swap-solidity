// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Test} from 'forge-std-1.14.0/Test.sol';

import {Terms} from '../../src/TermsLib.sol';
import {IOmnibus, LockState} from '../../src/interfaces/IOmnibus.sol';
import {OmnibusHarness} from '../harness/OmnibusHarness.sol';
import {ERC20Mock} from '../mocks/ERC20Mock.sol';
import {AssetHelper} from '../utils/AssetHelper.sol';
import {TermsHelper} from '../utils/TermsHelper.sol';

/// @title Cross-chain settlement buffer
/// @dev a cross-chain claim is gated only on the local (party) leg's deadline. this
/// preserves the HTLC safety buffer: the secret holder must reveal before the leg it
/// claims expires, leaving the counterparty the gap until the other leg's deadline to
/// claim. these tests pin both the buffer (correct ordering) and the consequence of
/// mis-ordering (secret holder takes both legs), which is why the ordering is a
/// documented user responsibility.
contract Omnibus_CrossChainFreeOption is Test {
  using AssetHelper for *;
  using TermsHelper for *;

  // ============ Constants ============

  uint256 constant CHAIN_A = 1; // Alice's leg
  uint256 constant CHAIN_B = 137; // Bob's leg

  uint256 constant AMOUNT_A = 100 ether;
  uint256 constant AMOUNT_B = 200 ether;

  // ============ Actors ============

  address public ALICE = makeAddr('alice');
  address public BOB = makeAddr('bob');
  address public ALICE_RECIPIENT = makeAddr('aliceRecipient');
  address public BOB_RECIPIENT = makeAddr('bobRecipient');

  // ============ Contracts ============

  OmnibusHarness public omnibusA; // chain A
  OmnibusHarness public omnibusB; // chain B
  ERC20Mock public tokenA; // Alice's asset
  ERC20Mock public tokenB; // Bob's asset

  // ============ Test Data ============

  bytes32 public constant SECRET = keccak256('bob-secret');
  bytes32 public lock;

  function setUp() public {
    omnibusA = new OmnibusHarness(address(this));
    omnibusB = new OmnibusHarness(address(this));
    tokenA = new ERC20Mock('TokenA', 'TKA', 18);
    tokenB = new ERC20Mock('TokenB', 'TKB', 18);

    lock = omnibusA.exposed_generateLock(SECRET);

    tokenA.mint(ALICE, AMOUNT_A);
    tokenB.mint(BOB, AMOUNT_B);
  }

  // ============ Helpers ============

  function _aliceTerms(uint64 deadline) internal view returns (Terms memory) {
    return TermsHelper.makeTerms(
      CHAIN_A,
      ALICE,
      ALICE_RECIPIENT,
      deadline,
      AssetHelper.makeERC20(address(tokenA), AMOUNT_A).toArray()
    );
  }

  function _bobTerms(uint64 deadline) internal view returns (Terms memory) {
    return TermsHelper.makeTerms(
      CHAIN_B,
      BOB,
      BOB_RECIPIENT,
      deadline,
      AssetHelper.makeERC20(address(tokenB), AMOUNT_B).toArray()
    );
  }

  /// @notice commits both legs on their respective chains
  function _commitBothLegs(Terms memory alice, Terms memory bob) internal {
    vm.chainId(CHAIN_A);
    vm.startPrank(ALICE);
    tokenA.approve(address(omnibusA), AMOUNT_A);
    omnibusA.commit(lock, alice, bob);
    vm.stopPrank();

    vm.chainId(CHAIN_B);
    vm.startPrank(BOB);
    tokenB.approve(address(omnibusB), AMOUNT_B);
    omnibusB.commit(lock, bob, alice);
    vm.stopPrank();
  }

  // ============ Correct ordering: buffer holds ============

  /// @notice with the secret holder's claim leg (Alice's, chain A) expiring first, the
  /// counterparty can still claim the other leg after that earlier deadline has passed
  function test_crossChain_buffer_counterpartyClaimsAfterEarlierDeadline() public {
    uint64 deadlineA = uint64(block.timestamp + 1 hours); // Bob (secret holder) claims this leg
    uint64 deadlineB = uint64(block.timestamp + 3 hours); // Alice claims this leg, later
    Terms memory alice = _aliceTerms(deadlineA);
    Terms memory bob = _bobTerms(deadlineB);

    _commitBothLegs(alice, bob);

    // Bob reveals at the last moment before Alice's leg (chain A) expires
    vm.warp(deadlineA - 1);
    vm.chainId(CHAIN_A);
    vm.prank(BOB);
    omnibusA.execute(SECRET, alice, bob); // Alice's tokenA -> BOB_RECIPIENT, secret revealed
    assertEq(tokenA.balanceOf(BOB_RECIPIENT), AMOUNT_A);

    // chain A's deadline has now passed, but Alice's claim on chain B is gated only on
    // chain B's (later) deadline, so she still settles the swap fairly
    vm.warp(deadlineA + 1);
    assertLt(block.timestamp, deadlineB);
    vm.chainId(CHAIN_B);
    vm.prank(ALICE);
    omnibusB.execute(SECRET, bob, alice); // Bob's tokenB -> ALICE_RECIPIENT
    assertEq(tokenB.balanceOf(ALICE_RECIPIENT), AMOUNT_B);
  }

  // ============ Mis-ordering: secret holder can take both legs ============

  /// @notice if the legs are mis-ordered (the secret holder's claim leg expires LAST),
  /// the secret holder can reclaim its own leg after the earlier deadline and still
  /// claim the counterparty's leg, taking both. documents why ordering is required.
  function test_crossChain_misordered_secretHolderTakesBothLegs() public {
    uint64 deadlineA = uint64(block.timestamp + 3 hours); // Bob claims this leg, LATE (wrong)
    uint64 deadlineB = uint64(block.timestamp + 1 hours); // Bob's own leg expires first (wrong)
    Terms memory alice = _aliceTerms(deadlineA);
    Terms memory bob = _bobTerms(deadlineB);

    _commitBothLegs(alice, bob);

    // Bob never reveals until his own leg (chain B) has expired, then reclaims it
    vm.warp(deadlineB + 1);
    vm.chainId(CHAIN_B);
    vm.prank(BOB);
    omnibusB.reclaim(lock, bob, alice); // Bob's tokenB returns to BOB (signatory)
    assertEq(tokenB.balanceOf(BOB), AMOUNT_B);

    // Alice's leg (chain A) is still fresh, so Bob also claims it
    assertLt(block.timestamp, deadlineA);
    vm.chainId(CHAIN_A);
    vm.prank(BOB);
    omnibusA.execute(SECRET, alice, bob); // Alice's tokenA -> BOB_RECIPIENT
    assertEq(tokenA.balanceOf(BOB_RECIPIENT), AMOUNT_A);

    // Bob ended with both assets; Alice never received tokenB
    assertEq(tokenB.balanceOf(ALICE_RECIPIENT), 0);
  }
}
