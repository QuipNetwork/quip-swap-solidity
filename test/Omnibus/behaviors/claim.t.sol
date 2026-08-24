// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Terms, TermsLib} from '../../../src/TermsLib.sol';
import {IOmnibus, LockState} from '../../../src/interfaces/IOmnibus.sol';
import {AssetHelper} from '../../utils/AssetHelper.sol';
import {OmnibusTest} from '../Omnibus.t.sol';
import {Vm} from 'forge-std-1.14.0/Vm.sol';

/// @title Omnibus claim Tests
/// @dev Tests for Omnibus.claim (formerly `execute`). Same-chain settlement is one claim by
///      the proposer (secret holder) in the proposer-claim window [BOB_COMMIT, ALICE_CLAIM);
///      it routes the counterparty's assets to party.recipient and, because the party is also
///      on-chain, the party's assets to counterparty.recipient.
contract Omnibus_claim is OmnibusTest {
  using AssetHelper for *;

  // ============ Success Cases ============

  function test_claim_sameChain_settlesBothLegs() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);
    _warpToProposerClaim();

    uint256 bobRecipientNativeBefore = BOB_RECIPIENT.balance;
    uint256 aliceRecipientERC20Before = mockERC20.balanceOf(ALICE_RECIPIENT);

    omnibus.claim(SECRET, alice, bob);

    // Alice's native assets go to Bob's recipient (party assets -> counterparty.recipient)
    assertEq(BOB_RECIPIENT.balance - bobRecipientNativeBefore, DEFAULT_AMOUNT);
    // Bob's ERC20 assets go to Alice's recipient (counterparty assets -> party.recipient)
    assertEq(mockERC20.balanceOf(ALICE_RECIPIENT) - aliceRecipientERC20Before, DEFAULT_AMOUNT);
  }

  function test_claim_transfersPartyAssetsToCounterpartyRecipient() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);
    _warpToProposerClaim();

    uint256 bobRecipientBefore = BOB_RECIPIENT.balance;

    omnibus.claim(SECRET, alice, bob);

    assertEq(BOB_RECIPIENT.balance - bobRecipientBefore, DEFAULT_AMOUNT);
  }

  function test_claim_transfersCounterpartyAssetsToPartyRecipient() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);
    _warpToProposerClaim();

    uint256 aliceRecipientBefore = mockERC20.balanceOf(ALICE_RECIPIENT);

    omnibus.claim(SECRET, alice, bob);

    assertEq(mockERC20.balanceOf(ALICE_RECIPIENT) - aliceRecipientBefore, DEFAULT_AMOUNT);
  }

  function test_claim_crossChainLeg_counterpartyOnChain() public {
    // cross-chain second leg: the on-chain side (alice) is passed as `counterparty` and claimed
    // by the off-chain party (bob). Only the on-chain counterparty's assets move.
    Terms memory alice = _aliceTerms(); // on this chain
    Terms memory bob = _bobCrossChainTerms(); // off chain

    // alice commits her on-chain leg (cross-chain -> Committed)
    _commitFor(ALICE, lock, alice, bob);

    _warpToTakerClaim(); // taker claim window [ALICE_CLAIM, ALICE_RECLAIM)

    uint256 bobRecipientBefore = BOB_RECIPIENT.balance;
    uint256 aliceRecipientERC20Before = mockERC20.balanceOf(ALICE_RECIPIENT);

    // party = bob (off-chain), counterparty = alice (on-chain); alice's assets -> bob.recipient
    omnibus.claim(SECRET, bob, alice);

    assertEq(BOB_RECIPIENT.balance - bobRecipientBefore, DEFAULT_AMOUNT);
    // bob is cross-chain, so no transfer of bob's assets on this chain
    assertEq(mockERC20.balanceOf(ALICE_RECIPIENT), aliceRecipientERC20Before);
  }

  function test_claim_sameChain_settlesBothLegs_regardlessOfTermsParameterOrderingInCalldata() public {
    // argument order carries no meaning same-chain: a claim with the terms role-swapped
    // (taker's terms as `party`) inside the proposer window must settle both legs to the
    // right recipients, exactly like the conventional order
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);
    _warpToProposerClaim();

    uint256 bobRecipientBefore = BOB_RECIPIENT.balance;
    uint256 aliceRecipientBefore = mockERC20.balanceOf(ALICE_RECIPIENT);

    // party = bob (taker), counterparty = alice
    vm.prank(BOB);
    omnibus.claim(SECRET, bob, alice);

    // alice's native assets -> bob.recipient; bob's ERC20 assets -> alice.recipient
    assertEq(BOB_RECIPIENT.balance - bobRecipientBefore, DEFAULT_AMOUNT);
    assertEq(mockERC20.balanceOf(ALICE_RECIPIENT) - aliceRecipientBefore, DEFAULT_AMOUNT);
    _assertSwapState(lock, alice, bob, LockState.Spent);
  }

  function test_claim_emitsClaimEvent() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);
    _warpToProposerClaim();

    vm.recordLogs();
    vm.prank(CHARLIE);
    omnibus.claim(SECRET, alice, bob);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    bool foundEvent = false;
    for (uint256 i = 0; i < logs.length; i++) {
      if (logs[i].topics[0] == IOmnibus.Claim.selector) {
        assertEq(logs[i].topics[1], lock);
        // recipient (non-indexed) then secret (non-indexed) live in data
        (address emittedRecipient, bytes32 emittedSecret) = abi.decode(logs[i].data, (address, bytes32));
        assertEq(emittedRecipient, CHARLIE); // the claimer, not a terms recipient
        assertEq(emittedSecret, SECRET);
        foundEvent = true;
        break;
      }
    }
    assertTrue(foundEvent, 'Claim event not emitted');
  }

  function test_claim_anyoneCanClaim() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);
    _warpToProposerClaim();

    // Charlie claims with valid secret
    vm.prank(CHARLIE);
    omnibus.claim(SECRET, alice, bob);

    _assertSwapState(lock, alice, bob, LockState.Spent);
  }

  function test_claim_withERC20Assets() public {
    Terms memory alice = _aliceTermsOn(block.chainid, _makeERC20Assets(DEFAULT_AMOUNT));
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);
    _warpToProposerClaim();

    uint256 bobRecipientBefore = mockERC20.balanceOf(BOB_RECIPIENT);

    omnibus.claim(SECRET, alice, bob);

    assertEq(mockERC20.balanceOf(BOB_RECIPIENT) - bobRecipientBefore, DEFAULT_AMOUNT);
  }

  function test_claim_withERC721Assets() public {
    uint256 tokenId = ERC721_ALICE_TOKEN;
    Terms memory alice = _aliceTermsOn(block.chainid, _makeERC721Assets(tokenId));
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);
    _warpToProposerClaim();

    assertEq(mockERC721.ownerOf(tokenId), address(omnibus));

    omnibus.claim(SECRET, alice, bob);

    assertEq(mockERC721.ownerOf(tokenId), BOB_RECIPIENT);
  }

  function test_claim_withERC1155Assets() public {
    Terms memory alice = _aliceTermsOn(block.chainid, _makeERC1155Assets(ERC1155_TOKEN_ID, 100));
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);
    _warpToProposerClaim();

    uint256 bobRecipientBefore = mockERC1155.balanceOf(BOB_RECIPIENT, ERC1155_TOKEN_ID);

    omnibus.claim(SECRET, alice, bob);

    assertEq(mockERC1155.balanceOf(BOB_RECIPIENT, ERC1155_TOKEN_ID) - bobRecipientBefore, 100);
  }

  function test_claim_setsLockStateToSpent() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);
    _assertSwapState(lock, alice, bob, LockState.Committed);

    _warpToProposerClaim();
    omnibus.claim(SECRET, alice, bob);
    _assertSwapState(lock, alice, bob, LockState.Spent);
  }

  // ============ Revert Cases ============

  function test_claim_revertsWhen_wrongSecret() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);
    _warpToProposerClaim();

    bytes32 wrongSecret = keccak256('wrong');
    vm.expectRevert(IOmnibus.TermsMismatch.selector);
    omnibus.claim(wrongSecret, alice, bob);
  }

  function test_claim_revertsWhen_termsMismatch() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);
    _warpToProposerClaim();

    // Modify terms (different amount, still a valid proposer schedule)
    Terms memory aliceModified = _aliceTermsOn(block.chainid, _makeNativeAssets(DEFAULT_AMOUNT + 1));

    vm.expectRevert(IOmnibus.TermsMismatch.selector);
    omnibus.claim(SECRET, aliceModified, bob);
  }

  function test_claim_revertsWhen_lockNotCommitted() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    // Only first commit (Free state)
    _commitFor(ALICE, lock, alice, bob);
    _assertSwapState(lock, alice, bob, LockState.Free);

    _warpToProposerClaim();
    vm.expectRevert(IOmnibus.InvalidLockState.selector);
    omnibus.claim(SECRET, alice, bob);
  }

  function test_claim_revertsWhen_lockUnused() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _assertSwapState(lock, alice, bob, LockState.Unused);

    // no terms posted for the lock -> canonical digest mismatch surfaces first
    vm.expectRevert(IOmnibus.TermsMismatch.selector);
    omnibus.claim(SECRET, alice, bob);
  }

  function test_claim_revertsWhen_lockSpent() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);
    _warpToProposerClaim();
    omnibus.claim(SECRET, alice, bob);
    _assertSwapState(lock, alice, bob, LockState.Spent);

    vm.expectRevert(IOmnibus.InvalidLockState.selector);
    omnibus.claim(SECRET, alice, bob);
  }

  function test_claim_revertsWhen_counterpartyNotOnChain() public {
    // claim requires the counterparty (whose assets pay the party) to be on this chain
    Terms memory alice = _aliceTerms(); // on this chain (party)
    Terms memory bob = _bobCrossChainTerms(); // off chain (counterparty)

    // set a committed lock with the matching canonical digest
    bytes32 hash = omnibus.computeTermsHash(alice, bob);
    omnibus.setLockState(_swapIdFor(lock, alice, bob), LockState.Committed);
    omnibus.setTermsHash(_swapIdFor(lock, alice, bob), hash);

    vm.expectRevert(TermsLib.ChainIdMismatch.selector);
    omnibus.claim(SECRET, alice, bob);
  }

  function test_claim_revertsWhen_counterpartySideNotPosted() public {
    // defense-in-depth (harness-staged): a Committed lock with a matching canonical digest
    // must still refuse to pay out a counterparty side that was never posted
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    omnibus.setTermsHash(_swapIdFor(lock, alice, bob), omnibus.computeTermsHash(alice, bob));
    omnibus.setLockState(_swapIdFor(lock, alice, bob), LockState.Committed);
    omnibus.setPosted(_swapIdFor(lock, alice, bob), omnibus.computeTermsDigest(alice), true); // party side only

    _warpToProposerClaim();
    vm.expectRevert(IOmnibus.TermsNotPosted.selector);
    omnibus.claim(SECRET, alice, bob);
  }

  function test_claim_revertsWhen_partySideNotPosted() public {
    // defense-in-depth (harness-staged): the same-chain second leg checks the party side too;
    // a missing party post must revert rather than settle one-sided
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    omnibus.setTermsHash(_swapIdFor(lock, alice, bob), omnibus.computeTermsHash(alice, bob));
    omnibus.setLockState(_swapIdFor(lock, alice, bob), LockState.Committed);
    omnibus.setPosted(_swapIdFor(lock, alice, bob), omnibus.computeTermsDigest(bob), true); // counterparty side only

    _warpToProposerClaim();
    vm.expectRevert(IOmnibus.TermsNotPosted.selector);
    omnibus.claim(SECRET, alice, bob);
  }

  // ============ Window Cases ============

  function test_claim_revertsWhen_beforeProposerClaimWindow() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);

    // taker just committed at AT_TAKER_COMMIT (< BOB_COMMIT_DEADLINE); the proposer claim
    // window opens at BOB_COMMIT_DEADLINE, so claiming now is too early
    vm.warp(BOB_COMMIT_DEADLINE - 1);
    vm.expectRevert(TermsLib.WindowViolated.selector);
    omnibus.claim(SECRET, alice, bob);
  }

  function test_claim_revertsWhen_atProposerClaimUpperBound() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);

    // upper bound (ALICE_CLAIM_DEADLINE) is exclusive
    vm.warp(ALICE_CLAIM_DEADLINE);
    vm.expectRevert(TermsLib.WindowViolated.selector);
    omnibus.claim(SECRET, alice, bob);
  }

  function test_claim_succeedsAtProposerClaimLowerBound() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);

    // lower bound (BOB_COMMIT_DEADLINE) is inclusive
    vm.warp(BOB_COMMIT_DEADLINE);
    omnibus.claim(SECRET, alice, bob);
    _assertSwapState(lock, alice, bob, LockState.Spent);
  }

  function test_claim_succeedsJustBeforeUpperBound() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);

    vm.warp(ALICE_CLAIM_DEADLINE - 1);
    omnibus.claim(SECRET, alice, bob);
    _assertSwapState(lock, alice, bob, LockState.Spent);
  }

  // ============ Taker-Claim Window Cases ============

  /// @dev cross-chain second leg: alice (on-chain) committed, bob (off-chain) claims with the
  ///      revealed secret. The taker-claim window is [ALICE_CLAIM_DEADLINE, ALICE_RECLAIM_RELEASE).
  function _commitCrossChainLeg() internal returns (Terms memory alice, Terms memory bob) {
    alice = _aliceTerms();
    bob = _bobCrossChainTerms();
    _commitFor(ALICE, lock, alice, bob);
  }

  function test_claim_takerClaim_succeedsAtLowerBound() public {
    (Terms memory alice, Terms memory bob) = _commitCrossChainLeg();

    // lower bound (ALICE_CLAIM_DEADLINE) is inclusive
    vm.warp(ALICE_CLAIM_DEADLINE);
    omnibus.claim(SECRET, bob, alice);
    _assertSwapState(lock, alice, bob, LockState.Spent);
  }

  function test_claim_takerClaim_revertsWhen_beforeWindow() public {
    (Terms memory alice, Terms memory bob) = _commitCrossChainLeg();

    // still inside the proposer's reveal window; the taker claim has not opened yet
    vm.warp(ALICE_CLAIM_DEADLINE - 1);
    vm.expectRevert(TermsLib.WindowViolated.selector);
    omnibus.claim(SECRET, bob, alice);
  }

  function test_claim_takerClaim_revertsWhen_atUpperBound() public {
    (Terms memory alice, Terms memory bob) = _commitCrossChainLeg();

    // upper bound (ALICE_RECLAIM_RELEASE) is exclusive: the proposer's reclaim window opens here
    vm.warp(ALICE_RECLAIM_RELEASE);
    vm.expectRevert(TermsLib.WindowViolated.selector);
    omnibus.claim(SECRET, bob, alice);
  }

  function test_claim_takerClaim_succeedsJustBeforeUpperBound() public {
    (Terms memory alice, Terms memory bob) = _commitCrossChainLeg();

    vm.warp(ALICE_RECLAIM_RELEASE - 1);
    omnibus.claim(SECRET, bob, alice);
    _assertSwapState(lock, alice, bob, LockState.Spent);
  }

  // ============ Role-Swapped Same-Chain Window Cases (audit regression) ============

  /// @dev audit finding: same-chain, the claim window is selected from which struct the
  ///      caller passes as `party` vs `counterparty`. Submitting the identical terms
  ///      role-swapped used to flip the check into the cross-chain taker window
  ///      [ALICE_CLAIM_DEADLINE, ALICE_RECLAIM_RELEASE), extending the secret holder's
  ///      effective window to the union [BOB_COMMIT_DEADLINE, ALICE_RECLAIM_RELEASE).
  ///      Roles are now derived from the terms' deadlines, so both argument orders must
  ///      enforce the one proposer window [BOB_COMMIT_DEADLINE, ALICE_CLAIM_DEADLINE).

  function test_claim_sameChainRoleSwapped_revertsWhen_inTakerWindow() public {
    // the original exploit transaction: role-swapped claim inside what used to be the
    // reachable taker window must now revert
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);
    _warpToTakerClaim();

    vm.expectRevert(TermsLib.WindowViolated.selector);
    omnibus.claim(SECRET, bob, alice);
  }

  function test_claim_sameChainRoleSwapped_revertsWhen_atProposerClaimUpperBound() public {
    // upper bound (ALICE_CLAIM_DEADLINE) is exclusive for the swapped order too; this exact
    // timestamp used to be the start of the extended window
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);

    vm.warp(ALICE_CLAIM_DEADLINE);
    vm.expectRevert(TermsLib.WindowViolated.selector);
    omnibus.claim(SECRET, bob, alice);
  }

  function test_claim_sameChainRoleSwapped_revertsWhen_justBeforeProposerReclaimRelease() public {
    // the far end of the previously-exploitable range: one second before the proposer could
    // reclaim, the role-swapped claim must still be closed
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);

    vm.warp(ALICE_RECLAIM_RELEASE - 1);
    vm.expectRevert(TermsLib.WindowViolated.selector);
    omnibus.claim(SECRET, bob, alice);
  }

  function test_claim_sameChainRoleSwapped_revertsWhen_beforeWindow() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);

    // proposer window opens at BOB_COMMIT_DEADLINE regardless of argument order
    vm.warp(BOB_COMMIT_DEADLINE - 1);
    vm.expectRevert(TermsLib.WindowViolated.selector);
    omnibus.claim(SECRET, bob, alice);
  }

  function test_claim_sameChainRoleSwapped_succeedsAtProposerClaimLowerBound() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);

    // lower bound (BOB_COMMIT_DEADLINE) is inclusive for the swapped order too
    vm.warp(BOB_COMMIT_DEADLINE);
    omnibus.claim(SECRET, bob, alice);
    _assertSwapState(lock, alice, bob, LockState.Spent);
  }

  function test_claim_sameChainRoleSwapped_succeedsJustBeforeUpperBound() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);

    vm.warp(ALICE_CLAIM_DEADLINE - 1);
    omnibus.claim(SECRET, bob, alice);
    _assertSwapState(lock, alice, bob, LockState.Spent);
  }

  // ============ Fuzz Tests ============

  function testFuzz_claim_withValidSecret(bytes32 secret) public {
    bytes32 _lock = omnibus.exposed_generateLock(secret);

    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitFor(ALICE, _lock, alice, bob);
    _commitFor(BOB, _lock, bob, alice);

    _warpToProposerClaim();
    omnibus.claim(secret, alice, bob);
    _assertSwapState(_lock, alice, bob, LockState.Spent);
  }

  function testFuzz_claim_sameChain_windowIsArgumentOrderIndependent(uint256 timestamp) public {
    // at every timestamp, both argument orders must agree on accept/reject, and both must
    // accept exactly inside the proposer window [BOB_COMMIT_DEADLINE, ALICE_CLAIM_DEADLINE)
    timestamp = bound(timestamp, 0, BOB_RECLAIM_RELEASE + 1000);

    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);
    vm.warp(timestamp);

    uint256 snapshot = vm.snapshotState();
    bool conventionalOrderSucceeds;
    try omnibus.claim(SECRET, alice, bob) {
      conventionalOrderSucceeds = true;
    } catch {}

    vm.revertToState(snapshot);
    bool swappedOrderSucceeds;
    try omnibus.claim(SECRET, bob, alice) {
      swappedOrderSucceeds = true;
    } catch {}

    assertEq(conventionalOrderSucceeds, swappedOrderSucceeds);

    bool inProposerWindow = timestamp >= BOB_COMMIT_DEADLINE && timestamp < ALICE_CLAIM_DEADLINE;
    assertEq(conventionalOrderSucceeds, inProposerWindow);
  }
}
