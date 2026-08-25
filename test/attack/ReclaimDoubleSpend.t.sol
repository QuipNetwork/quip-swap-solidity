// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Terms, TermsLib} from '../../src/TermsLib.sol';
import {IOmnibus, LockState} from '../../src/interfaces/IOmnibus.sol';
import {OmnibusTest} from '../Omnibus/Omnibus.t.sol';

/// @title Reclaim Double-Spend Prevention
/// @dev Independent per-side reclaim means each leg leaves escrow exactly once, via claim
/// XOR reclaim, enforced by the interaction of `lockState` and the per-side `reclaimed`
/// flag. This suite exhausts the double-spend surface across both topologies:
///   - reclaim a side twice                  -> AlreadyReclaimed (flag set before transfer)
///   - claim-settled swap then reclaim       -> InvalidLockState (Spent with no reclaim flag)
///   - reclaim-in-progress then claim        -> blocked (Committed-only; also window-disjoint)
///   - cross-chain: each chain holds one leg; the remote side can never be reclaimed locally
contract Omnibus_ReclaimDoubleSpend is OmnibusTest {
  // ============ Same-chain ============

  /// @notice both sides reclaim independently; each leg leaves exactly once and every replay
  /// (either argument order) reverts
  function test_doubleSpend_sameChain_bothReclaimOnce_noReplay() public {
    Terms memory alice = _aliceTerms(); // native proposer
    Terms memory bob = _bobTerms(); // erc20 taker
    _commitBothParties(lock, alice, bob);

    uint256 obNative = address(omnibus).balance; // post-commit escrow baselines
    uint256 obErc20 = mockERC20.balanceOf(address(omnibus));

    _warpToProposerReclaim();
    uint256 aBefore = ALICE.balance;
    omnibus.reclaim(lock, alice, bob);
    assertEq(ALICE.balance - aBefore, DEFAULT_AMOUNT, 'alice paid once');

    _warpToTakerReclaim();
    uint256 bBefore = mockERC20.balanceOf(BOB);
    omnibus.reclaim(lock, bob, alice);
    assertEq(mockERC20.balanceOf(BOB) - bBefore, DEFAULT_AMOUNT, 'bob paid once');

    // every replay reverts, in either argument order
    vm.expectRevert(IOmnibus.AlreadyReclaimed.selector);
    omnibus.reclaim(lock, alice, bob);
    vm.expectRevert(IOmnibus.AlreadyReclaimed.selector);
    omnibus.reclaim(lock, bob, alice);

    // exactly one of each leg left the escrow
    assertEq(obNative - address(omnibus).balance, DEFAULT_AMOUNT, 'exactly one native leg out');
    assertEq(obErc20 - mockERC20.balanceOf(address(omnibus)), DEFAULT_AMOUNT, 'exactly one erc20 leg out');
  }

  /// @notice a claim-settled swap can never be reclaimed, in either argument order
  function test_doubleSpend_sameChain_claimThenReclaim_revertsBothOrders() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();
    _commitBothParties(lock, alice, bob);

    _warpToProposerClaim();
    omnibus.claim(SECRET, alice, bob); // settles both legs; Spent with no reclaim flag

    _warpToTakerReclaim();
    vm.expectRevert(IOmnibus.InvalidLockState.selector);
    omnibus.reclaim(lock, alice, bob);
    vm.expectRevert(IOmnibus.InvalidLockState.selector);
    omnibus.reclaim(lock, bob, alice);
  }

  /// @notice a reclaim-in-progress swap can never be claimed. the claim window closed before
  /// reclaim opened, so the window guard fires first; the Spent state guard is the belt behind it
  function test_doubleSpend_sameChain_reclaimThenClaim_reverts() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();
    _commitBothParties(lock, alice, bob);

    _warpToProposerReclaim();
    omnibus.reclaim(lock, alice, bob); // Alice out; lock Spent; reclaimed[alice] set

    vm.expectRevert(TermsLib.WindowViolated.selector);
    omnibus.claim(SECRET, alice, bob);
  }

  // ============ Cross-chain: proposer's (Alice) leg escrowed on THIS chain ============

  /// @notice the taker redeems Alice's on-chain leg; Alice's later reclaim must not double-spend it
  function test_doubleSpend_crossChain_proposerLeg_redeemThenReclaim_reverts() public {
    Terms memory alice = _aliceTerms(); // on this chain
    Terms memory bob = _bobCrossChainTerms(); // off chain
    _commitFor(ALICE, lock, alice, bob);
    _assertSwapState(lock, alice, bob, LockState.Committed);

    _warpToTakerClaim(); // taker redeem window
    uint256 before = BOB_RECIPIENT.balance;
    omnibus.claim(SECRET, bob, alice); // Alice's leg -> BOB_RECIPIENT; Spent
    assertEq(BOB_RECIPIENT.balance - before, DEFAULT_AMOUNT);

    _warpToProposerReclaim();
    uint256 aBefore = ALICE.balance;
    vm.expectRevert(IOmnibus.InvalidLockState.selector);
    omnibus.reclaim(lock, alice, bob);
    assertEq(ALICE.balance, aBefore, 'alice got nothing');
  }

  /// @notice Alice reclaims her on-chain leg once; no replay, and the off-chain side is
  /// unreclaimable locally
  function test_doubleSpend_crossChain_proposerLeg_reclaimOnce_noReplay() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobCrossChainTerms();
    _commitFor(ALICE, lock, alice, bob);

    _warpToProposerReclaim();
    uint256 aBefore = ALICE.balance;
    omnibus.reclaim(lock, alice, bob);
    assertEq(ALICE.balance - aBefore, DEFAULT_AMOUNT, 'alice paid once');

    vm.expectRevert(IOmnibus.AlreadyReclaimed.selector);
    omnibus.reclaim(lock, alice, bob);
    // the off-chain counterparty side cannot be reclaimed on this chain
    vm.expectRevert(TermsLib.ChainIdMismatch.selector);
    omnibus.reclaim(lock, bob, alice);
  }

  // ============ Cross-chain: taker's (Bob) leg escrowed on THIS chain ============

  /// @notice the proposer claims Bob's on-chain leg (reveal); Bob's later reclaim must not
  /// double-spend it
  function test_doubleSpend_crossChain_takerLeg_claimThenReclaim_reverts() public {
    Terms memory alice = _aliceTermsOn(OTHER_CHAIN_ID, _makeNativeAssets(DEFAULT_AMOUNT)); // off chain
    Terms memory bob = _bobTerms(); // on this chain (erc20 taker)
    _commitFor(BOB, lock, bob, alice);
    _assertSwapState(lock, alice, bob, LockState.Committed);

    _warpToProposerClaim(); // reveal window (taker's assets local)
    uint256 before = mockERC20.balanceOf(ALICE_RECIPIENT);
    omnibus.claim(SECRET, alice, bob); // Bob's leg -> ALICE_RECIPIENT; Spent
    assertEq(mockERC20.balanceOf(ALICE_RECIPIENT) - before, DEFAULT_AMOUNT);

    _warpToTakerReclaim();
    uint256 bBefore = mockERC20.balanceOf(BOB);
    vm.expectRevert(IOmnibus.InvalidLockState.selector);
    omnibus.reclaim(lock, bob, alice);
    assertEq(mockERC20.balanceOf(BOB), bBefore, 'bob got nothing');
  }

  /// @notice Bob reclaims his on-chain leg once; no replay, and the off-chain side is
  /// unreclaimable locally
  function test_doubleSpend_crossChain_takerLeg_reclaimOnce_noReplay() public {
    Terms memory alice = _aliceTermsOn(OTHER_CHAIN_ID, _makeNativeAssets(DEFAULT_AMOUNT));
    Terms memory bob = _bobTerms();
    _commitFor(BOB, lock, bob, alice);

    _warpToTakerReclaim();
    uint256 bBefore = mockERC20.balanceOf(BOB);
    omnibus.reclaim(lock, bob, alice);
    assertEq(mockERC20.balanceOf(BOB) - bBefore, DEFAULT_AMOUNT, 'bob paid once');

    vm.expectRevert(IOmnibus.AlreadyReclaimed.selector);
    omnibus.reclaim(lock, bob, alice);
    vm.expectRevert(TermsLib.ChainIdMismatch.selector);
    omnibus.reclaim(lock, alice, bob);
  }

  // ============ Argument ordering (explicit) ============

  /// @notice swapping (party, counterparty) selects the OTHER side to reclaim, never the same
  /// one; both orderings resolve to the same swap slot
  function test_doubleSpend_argOrder_sameChain_swapSelectsOppositeSide() public {
    Terms memory alice = _aliceTerms(); // native
    Terms memory bob = _bobTerms(); // erc20
    _commitBothParties(lock, alice, bob);

    // order-independent swap id: both orderings address the same swap
    assertEq(_swapIdFor(lock, alice, bob), _swapIdFor(lock, bob, alice), 'swapId is order-independent');

    // party = alice -> recovers ALICE's native leg to alice.reclaimRecipient; Bob's leg untouched
    _warpToProposerReclaim();
    uint256 aBefore = ALICE.balance;
    uint256 bobErc20 = mockERC20.balanceOf(BOB);
    omnibus.reclaim(lock, alice, bob);
    assertEq(ALICE.balance - aBefore, DEFAULT_AMOUNT, 'party=alice recovers the Alice leg');
    assertEq(mockERC20.balanceOf(BOB), bobErc20, 'Bob leg untouched by Alice reclaim');

    // party = bob -> recovers BOB's erc20 leg to bob.reclaimRecipient
    _warpToTakerReclaim();
    uint256 bBefore = mockERC20.balanceOf(BOB);
    omnibus.reclaim(lock, bob, alice);
    assertEq(mockERC20.balanceOf(BOB) - bBefore, DEFAULT_AMOUNT, 'party=bob recovers the Bob leg');
  }

  /// @notice the two reclaims drain fully regardless of which side goes first (Bob-first here,
  /// complementing the Alice-first path); every replay reverts
  function test_doubleSpend_argOrder_sameChain_orderIndependent_bobFirst() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();
    _commitBothParties(lock, alice, bob);

    // Bob first: Committed -> Spent
    _warpToTakerReclaim();
    uint256 bBefore = mockERC20.balanceOf(BOB);
    omnibus.reclaim(lock, bob, alice);
    assertEq(mockERC20.balanceOf(BOB) - bBefore, DEFAULT_AMOUNT, 'bob once');

    // Alice from Spent (guarded by reclaimed[bob]); her window opened earlier
    uint256 aBefore = ALICE.balance;
    omnibus.reclaim(lock, alice, bob);
    assertEq(ALICE.balance - aBefore, DEFAULT_AMOUNT, 'alice once');

    vm.expectRevert(IOmnibus.AlreadyReclaimed.selector);
    omnibus.reclaim(lock, bob, alice);
    vm.expectRevert(IOmnibus.AlreadyReclaimed.selector);
    omnibus.reclaim(lock, alice, bob);
  }

  /// @notice the reclaim window follows the `party` slot: swapping Bob into `party` still
  /// requires Bob's own reclaimRelease, even past Alice's
  function test_doubleSpend_argOrder_sameChain_windowFollowsPartySlot() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();
    _commitBothParties(lock, alice, bob);

    // past Alice's release (5000) but before Bob's (6000)
    vm.warp(ALICE_RECLAIM_RELEASE);

    // party = bob is gated by bob.reclaimRelease -> still closed
    vm.expectRevert(TermsLib.WindowViolated.selector);
    omnibus.reclaim(lock, bob, alice);

    // party = alice is gated by alice.reclaimRelease -> open at the same instant
    uint256 aBefore = ALICE.balance;
    omnibus.reclaim(lock, alice, bob);
    assertEq(ALICE.balance - aBefore, DEFAULT_AMOUNT, 'alice reclaims at her own release');
  }

  /// @notice cross-chain, the remote side can never be reclaimed locally by moving it into the
  /// `party` slot; only the local leg is reclaimable here (both orientations)
  function test_doubleSpend_argOrder_crossChain_remoteSideAsPartyReverts() public {
    // proposer leg local, taker remote
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobCrossChainTerms();
    _commitFor(ALICE, lock, alice, bob);

    _warpToProposerReclaim();
    // remote taker (bob) as party -> ChainIdMismatch (first check, before window)
    vm.expectRevert(TermsLib.ChainIdMismatch.selector);
    omnibus.reclaim(lock, bob, alice);
    // local proposer (alice) as party -> the only valid order here
    uint256 aBefore = ALICE.balance;
    omnibus.reclaim(lock, alice, bob);
    assertEq(ALICE.balance - aBefore, DEFAULT_AMOUNT, 'only the local leg reclaims');
  }

  // ============ Pool conservation ============

  /// @notice reclaim pays only the party's own declared amount, never the pooled balance,
  /// even though the clamp reads the whole contract balance (setUp pre-funds the Omnibus with
  /// a large ERC20 float standing in for other swaps' pooled deposits)
  function test_doubleSpend_pool_reclaimTakesOnlyDeclared_notThePool() public {
    Terms memory alice = _aliceTerms(); // native
    Terms memory bob = _bobTerms(); // erc20 DEFAULT_AMOUNT
    _commitBothParties(lock, alice, bob);

    uint256 poolBefore = mockERC20.balanceOf(address(omnibus));
    assertGt(poolBefore, DEFAULT_AMOUNT * 100, 'pool dwarfs the declared leg');

    _warpToTakerReclaim();
    uint256 bobBefore = mockERC20.balanceOf(BOB);
    omnibus.reclaim(lock, bob, alice);

    // Bob receives EXACTLY his declared deposit, and the pool shrinks by exactly that
    assertEq(mockERC20.balanceOf(BOB) - bobBefore, DEFAULT_AMOUNT, 'reclaim capped at declared');
    assertEq(poolBefore - mockERC20.balanceOf(address(omnibus)), DEFAULT_AMOUNT, 'pool drained only by declared');
  }

  /// @notice two independent same-chain swaps sharing the ERC20 pool: each party recovers
  /// exactly its own deposit, and no swap can pull another swap's funds
  function test_doubleSpend_pool_multiSwapConservation_noCrossDrain() public {
    address CARO = makeAddr('caro');
    address DAVE = makeAddr('dave');
    mockERC20.mint(CARO, 100 ether);
    mockERC20.mint(DAVE, 100 ether);
    vm.prank(CARO);
    mockERC20.approve(address(omnibus), type(uint256).max);
    vm.prank(DAVE);
    mockERC20.approve(address(omnibus), type(uint256).max);

    // swap 1: Alice(native) <-> Bob(erc20)
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();
    _commitBothParties(lock, alice, bob);

    // swap 2: Caro(erc20) <-> Dave(erc20), a distinct lock -> distinct swap id
    bytes32 lock2 = omnibus.exposed_generateLock(keccak256('secret2'));
    Terms memory caro = _makeTerms(
      block.chainid,
      CARO,
      CARO,
      ALICE_COMMIT_DEADLINE,
      ALICE_CLAIM_DEADLINE,
      ALICE_RECLAIM_RELEASE,
      _makeERC20Assets(100 ether)
    );
    Terms memory dave = _makeTerms(
      block.chainid,
      DAVE,
      DAVE,
      BOB_COMMIT_DEADLINE,
      BOB_CLAIM_DEADLINE,
      BOB_RECLAIM_RELEASE,
      _makeERC20Assets(100 ether)
    );
    _commitBothParties(lock2, caro, dave);

    uint256 poolBefore = mockERC20.balanceOf(address(omnibus));

    _warpToTakerReclaim();
    uint256 b0 = mockERC20.balanceOf(BOB);
    omnibus.reclaim(lock, bob, alice);
    uint256 c0 = mockERC20.balanceOf(CARO);
    omnibus.reclaim(lock2, caro, dave);
    uint256 d0 = mockERC20.balanceOf(DAVE);
    omnibus.reclaim(lock2, dave, caro);

    assertEq(mockERC20.balanceOf(BOB) - b0, DEFAULT_AMOUNT, 'bob exact');
    assertEq(mockERC20.balanceOf(CARO) - c0, 100 ether, 'caro exact');
    assertEq(mockERC20.balanceOf(DAVE) - d0, 100 ether, 'dave exact');
    assertEq(poolBefore - mockERC20.balanceOf(address(omnibus)), DEFAULT_AMOUNT + 200 ether, 'no cross-swap drain');
  }
}
