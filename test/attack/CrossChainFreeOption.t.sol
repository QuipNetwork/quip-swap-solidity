// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Test} from 'forge-std-1.14.0/Test.sol';

import {Terms, TermsLib} from '../../src/TermsLib.sol';
import {CommitAuth, LockState} from '../../src/interfaces/IOmnibus.sol';
import {OmnibusHarness} from '../harness/OmnibusHarness.sol';
import {ERC20Mock} from '../mocks/ERC20Mock.sol';
import {AssetHelper} from '../utils/AssetHelper.sol';
import {TermsHelper} from '../utils/TermsHelper.sol';

/// @title Cross-chain settlement buffer
/// @dev A cross-chain claim is gated only on the local leg's window; the hashlock bridges the
/// two legs. The HTLC safety buffer is the reaction gap the second claimant has after the
/// secret is revealed. Under the current `validateTermPairing`, the *ordering* that creates
/// that buffer is enforced on-chain (the proposer's reveal deadline opens the taker's claim
/// window), so the old "mis-ordering lets the secret holder take both legs" outcome is no
/// longer expressible as valid terms — it is rejected at `commit`. The only residual risk is
/// the reaction-gap *width* (parameter sizing), not the ordering.
contract Omnibus_CrossChainFreeOption is Test {
  using AssetHelper for *;
  using TermsHelper for *;

  // ============ Constants ============

  uint256 constant CHAIN_A = 1; // Alice's (proposer) leg
  uint256 constant CHAIN_B = 137; // Bob's (taker) leg

  uint256 constant AMOUNT_A = 100 ether;
  uint256 constant AMOUNT_B = 200 ether;

  // lifecycle deadlines (Alice = proposer, Bob = taker)
  uint256 constant A_COMMIT = 1000;
  uint256 constant B_COMMIT = 2000;
  uint256 constant A_CLAIM = 3000;
  uint256 constant B_CLAIM = 4000;
  uint256 constant A_RECLAIM = 5000;
  uint256 constant B_RECLAIM = 6000;

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
    // commit is permissionless; each caller self-authorizes with its own identity
    omnibusA = new OmnibusHarness(address(this), new address[](0));
    omnibusB = new OmnibusHarness(address(this), new address[](0));
    tokenA = new ERC20Mock('TokenA', 'TKA', 18);
    tokenB = new ERC20Mock('TokenB', 'TKB', 18);

    lock = omnibusA.exposed_generateLock(SECRET);

    tokenA.mint(ALICE, AMOUNT_A);
    tokenB.mint(BOB, AMOUNT_B);
  }

  // ============ Helpers ============

  /// @notice minimal self-auth blob: succeeds when `sender` is the actual msg.sender
  function _selfAuth(address sender) private pure returns (CommitAuth memory) {
    return CommitAuth({signer: abi.encodePacked(sender), signature: ''});
  }

  function _aliceTerms() internal view returns (Terms memory) {
    return TermsHelper.makeTerms(
      CHAIN_A,
      ALICE,
      ALICE_RECIPIENT,
      A_COMMIT,
      A_CLAIM,
      A_RECLAIM,
      AssetHelper.makeERC20(address(tokenA), AMOUNT_A).toArray()
    );
  }

  function _bobTerms() internal view returns (Terms memory) {
    return TermsHelper.makeTerms(
      CHAIN_B,
      BOB,
      BOB_RECIPIENT,
      B_COMMIT,
      B_CLAIM,
      B_RECLAIM,
      AssetHelper.makeERC20(address(tokenB), AMOUNT_B).toArray()
    );
  }

  /// @notice commits both legs on their respective chains, in their commit windows
  function _commitBothLegs(Terms memory alice, Terms memory bob) internal {
    vm.chainId(CHAIN_A);
    vm.warp(500); // proposer commit window [0, A_COMMIT)
    vm.startPrank(ALICE);
    tokenA.approve(address(omnibusA), AMOUNT_A);
    omnibusA.commit(lock, alice, bob, _selfAuth(ALICE));
    vm.stopPrank();

    vm.chainId(CHAIN_B);
    vm.warp(1500); // taker commit window [A_COMMIT, B_COMMIT)
    vm.startPrank(BOB);
    tokenB.approve(address(omnibusB), AMOUNT_B);
    omnibusB.commit(lock, bob, alice, _selfAuth(BOB));
    vm.stopPrank();
  }

  // ============ Correct ordering: the reaction buffer holds ============

  /// @notice the proposer reveals at the very end of her reveal window (Chain B); the taker
  /// still has the whole [A_CLAIM, A_RECLAIM) window on Chain A to react and settle fairly
  function test_crossChain_buffer_takerClaimsAfterLastSecondReveal() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitBothLegs(alice, bob);

    // Alice reveals at the last instant before her reveal deadline (A_CLAIM) on Chain B
    vm.chainId(CHAIN_B);
    vm.warp(A_CLAIM - 1);
    omnibusB.claim(SECRET, alice, bob); // Bob's tokenB -> ALICE_RECIPIENT, secret revealed
    assertEq(tokenB.balanceOf(ALICE_RECIPIENT), AMOUNT_B);

    // the reveal window has closed, but Bob's claim window on Chain A is just opening and runs
    // until A_RECLAIM, so Bob still settles the swap fairly with the revealed secret
    vm.chainId(CHAIN_A);
    vm.warp(A_CLAIM + 1);
    assertLt(block.timestamp, A_RECLAIM);
    omnibusA.claim(SECRET, bob, alice); // Alice's tokenA -> BOB_RECIPIENT
    assertEq(tokenA.balanceOf(BOB_RECIPIENT), AMOUNT_A);

    assertEq(uint8(omnibusA.lockState(lock)), uint8(LockState.Spent));
    assertEq(uint8(omnibusB.lockState(lock)), uint8(LockState.Spent));
  }

  // ============ Taker negligence: proposer ends with both legs ============

  /// @notice TIMING_MODEL §7.5: the proposer reveals on Chain B but the taker misses their
  /// Chain-A claim window [A_CLAIM, A_RECLAIM); the proposer then reclaims her own untouched
  /// leg on Chain A and ends holding both legs. This is the documented liveness risk of taker
  /// inaction — not counterparty theft — and a window-logic change that breaks either half of
  /// it (the claim that should succeed or the reclaim that should still be possible) is caught
  /// here.
  function test_crossChain_takerNegligence_proposerTakesBothLegs() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitBothLegs(alice, bob);

    // proposer reveals and claims Bob's leg on Chain B (proposer-claim window)
    vm.chainId(CHAIN_B);
    vm.warp(2500); // [B_COMMIT, A_CLAIM)
    omnibusB.claim(SECRET, alice, bob);
    assertEq(tokenB.balanceOf(ALICE_RECIPIENT), AMOUNT_B);

    // the taker never claims on Chain A; once the proposer's release passes she reclaims
    // her own leg there
    vm.chainId(CHAIN_A);
    vm.warp(A_RECLAIM);
    vm.prank(ALICE);
    omnibusA.reclaim(lock, alice, bob);

    // the proposer holds both legs; the taker's only protection was acting inside its window
    assertEq(tokenA.balanceOf(ALICE), AMOUNT_A);
    assertEq(tokenB.balanceOf(ALICE_RECIPIENT), AMOUNT_B);
    assertEq(tokenA.balanceOf(BOB_RECIPIENT), 0);
    assertEq(uint8(omnibusA.lockState(lock)), uint8(LockState.Spent));
    assertEq(uint8(omnibusB.lockState(lock)), uint8(LockState.Spent));
  }

  // ============ Mis-ordering is now rejected at commit ============

  /// @notice a schedule where the taker's reclaim opens BEFORE the proposer's reveal deadline
  /// (the old "secret holder takes both legs" setup) no longer interleaves strictly, so
  /// `validateTermPairing` rejects it at commit. Each side is individually well-formed; only
  /// the cross-side ordering is dangerous.
  function test_crossChain_misorderedSchedule_rejectedAtCommit() public {
    // alice: 1000 < 5000 < 6000 (valid in isolation)
    Terms memory alice = TermsHelper.makeTerms(
      CHAIN_A, ALICE, ALICE_RECIPIENT, 1000, 5000, 6000, AssetHelper.makeERC20(address(tokenA), AMOUNT_A).toArray()
    );
    // bob: 2000 < 3000 < 4000 (valid in isolation) — but bob.reclaim (4000) opens before
    // alice.claim (5000), the dangerous mis-ordering
    Terms memory bob = TermsHelper.makeTerms(
      CHAIN_B, BOB, BOB_RECIPIENT, 2000, 3000, 4000, AssetHelper.makeERC20(address(tokenB), AMOUNT_B).toArray()
    );

    vm.chainId(CHAIN_A);
    vm.warp(500);
    vm.startPrank(ALICE);
    tokenA.approve(address(omnibusA), AMOUNT_A);
    vm.expectRevert(TermsLib.DisordedDeadlines.selector);
    omnibusA.commit(lock, alice, bob, _selfAuth(ALICE));
    vm.stopPrank();
  }
}
