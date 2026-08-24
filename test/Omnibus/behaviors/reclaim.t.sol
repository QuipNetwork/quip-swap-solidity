// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Terms, TermsLib} from '../../../src/TermsLib.sol';
import {IOmnibus, LockState} from '../../../src/interfaces/IOmnibus.sol';
import {AssetHelper} from '../../utils/AssetHelper.sol';
import {OmnibusTest} from '../Omnibus.t.sol';
import {Vm} from 'forge-std-1.14.0/Vm.sol';

/// @title Omnibus reclaim Tests
/// @dev Tests for Omnibus.reclaim. reclaim is gated only on the PARTY's own reclaimRelease
///      (enforceWithin(party.reclaimRelease, ∞)); same-chain it also refunds the committed
///      counterparty in the same call.
contract Omnibus_reclaim is OmnibusTest {
  using AssetHelper for *;

  // ============ Success Cases ============

  function test_reclaim_returnsAssetsToReclaimRecipient() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);
    _warpToProposerReclaim();

    uint256 aliceBefore = ALICE.balance;

    omnibus.reclaim(lock, alice, bob);

    // Alice gets her assets back
    assertEq(ALICE.balance - aliceBefore, DEFAULT_AMOUNT);
  }

  function test_reclaim_fromFreeState() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    // Only alice commits (Free state)
    _commitFor(ALICE, lock, alice, bob);
    _assertSwapState(lock, alice, bob, LockState.Free);

    _warpToProposerReclaim();

    uint256 aliceBefore = ALICE.balance;

    omnibus.reclaim(lock, alice, bob);

    // Alice gets everything back
    assertEq(ALICE.balance - aliceBefore, DEFAULT_AMOUNT);
    _assertSwapState(lock, alice, bob, LockState.Spent);
  }

  function test_reclaim_fromCommittedState() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);
    _assertSwapState(lock, alice, bob, LockState.Committed);

    _warpToProposerReclaim();

    omnibus.reclaim(lock, alice, bob);
    _assertSwapState(lock, alice, bob, LockState.Spent);
  }

  function test_reclaim_sameChainBothPartiesReclaim() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);
    _warpToProposerReclaim();

    uint256 aliceBefore = ALICE.balance;
    uint256 bobERC20Before = mockERC20.balanceOf(BOB);

    // proposer reclaim same-chain refunds both committed sides in one call
    omnibus.reclaim(lock, alice, bob);

    // Alice gets her native assets back
    assertEq(ALICE.balance - aliceBefore, DEFAULT_AMOUNT);
    // Bob gets his ERC20 assets back
    assertEq(mockERC20.balanceOf(BOB) - bobERC20Before, DEFAULT_AMOUNT);
  }

  function test_reclaim_emitsReclaimedEvent() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);
    _warpToProposerReclaim();

    vm.recordLogs();
    vm.prank(CHARLIE);
    omnibus.reclaim(lock, alice, bob);

    // same-chain proposer reclaim refunds the COUNTERPARTY first, then the party; pin the
    // recipients and their order (the spend-then-pay ordering the reentrancy reasoning relies on)
    address[2] memory expectedRecipients = [BOB, ALICE];
    Vm.Log[] memory logs = vm.getRecordedLogs();
    uint256 reclaimedCount = 0;
    for (uint256 i = 0; i < logs.length; i++) {
      if (logs[i].topics[0] == IOmnibus.Reclaimed.selector) {
        assertEq(logs[i].topics[1], lock);
        assertEq(address(uint160(uint256(logs[i].topics[2]))), expectedRecipients[reclaimedCount]);
        assertEq(abi.decode(logs[i].data, (address)), CHARLIE); // caller
        reclaimedCount++;
      }
    }
    // Should emit Reclaimed for both parties (same chain)
    assertEq(reclaimedCount, 2);
  }

  function test_reclaim_anyoneCanReclaim() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);
    _warpToProposerReclaim();

    // Charlie reclaims on behalf of parties
    vm.prank(CHARLIE);
    omnibus.reclaim(lock, alice, bob);

    _assertSwapState(lock, alice, bob, LockState.Spent);
  }

  function test_reclaim_setsLockStateToSpent() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);
    _assertSwapState(lock, alice, bob, LockState.Committed);

    _warpToProposerReclaim();

    omnibus.reclaim(lock, alice, bob);

    _assertSwapState(lock, alice, bob, LockState.Spent);
  }

  function test_reclaim_takerReclaimsAfterOwnRelease() public {
    // a same-chain taker (Bob) may also reclaim, but only after BOB_RECLAIM_RELEASE
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);
    _warpToTakerReclaim();

    uint256 bobERC20Before = mockERC20.balanceOf(BOB);
    uint256 aliceBefore = ALICE.balance;

    // party = bob (taker), counterparty = alice; same-chain committed -> refunds both
    vm.prank(BOB);
    omnibus.reclaim(lock, bob, alice);

    assertEq(mockERC20.balanceOf(BOB) - bobERC20Before, DEFAULT_AMOUNT);
    assertEq(ALICE.balance - aliceBefore, DEFAULT_AMOUNT);
    _assertSwapState(lock, alice, bob, LockState.Spent);
  }

  function test_reclaim_refundsERC721AndERC1155() public {
    // the refund path must hand back non-fungibles too, not just native/ERC20
    Terms memory alice = _aliceTermsOn(block.chainid, _makeERC721Assets(ERC721_ALICE_TOKEN));
    Terms memory bob = _bobTermsOn(block.chainid, _makeERC1155Assets(ERC1155_TOKEN_ID, 100));

    _commitBothParties(lock, alice, bob);
    assertEq(mockERC721.ownerOf(ERC721_ALICE_TOKEN), address(omnibus));

    uint256 bob1155Before = mockERC1155.balanceOf(BOB, ERC1155_TOKEN_ID);

    _warpToProposerReclaim();
    omnibus.reclaim(lock, alice, bob);

    assertEq(mockERC721.ownerOf(ERC721_ALICE_TOKEN), ALICE);
    assertEq(mockERC1155.balanceOf(BOB, ERC1155_TOKEN_ID) - bob1155Before, 100);
    _assertSwapState(lock, alice, bob, LockState.Spent);
  }

  // ============ Revert Cases ============

  function test_reclaim_revertsWhen_termsMismatch() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);
    _warpToProposerReclaim();

    // Modify terms (still a valid proposer schedule, different amount)
    Terms memory aliceModified = _aliceTermsOn(block.chainid, _makeNativeAssets(DEFAULT_AMOUNT + 1));

    vm.expectRevert(IOmnibus.TermsMismatch.selector);
    omnibus.reclaim(lock, aliceModified, bob);
  }

  function test_reclaim_revertsWhen_lockUnused() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _assertSwapState(lock, alice, bob, LockState.Unused);

    _warpToProposerReclaim();

    // Terms hash is 0 for unused lock, so it won't match
    vm.expectRevert(IOmnibus.TermsMismatch.selector);
    omnibus.reclaim(lock, alice, bob);
  }

  function test_reclaim_revertsWhen_lockSpent() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    // commit + settle via same-chain claim
    _settleSameChain(lock, alice, bob);
    _assertSwapState(lock, alice, bob, LockState.Spent);

    _warpToProposerReclaim();

    vm.expectRevert(IOmnibus.InvalidLockAdvancement.selector);
    omnibus.reclaim(lock, alice, bob);
  }

  function test_reclaim_revertsWhen_alreadyReclaimed() public {
    // the proposer's same-chain reclaim refunds BOTH sides; a follow-up reclaim by the taker
    // must revert rather than refund a second time
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);

    _warpToProposerReclaim();
    omnibus.reclaim(lock, alice, bob);
    _assertSwapState(lock, alice, bob, LockState.Spent);

    _warpToTakerReclaim();
    vm.expectRevert(IOmnibus.InvalidLockAdvancement.selector);
    vm.prank(BOB);
    omnibus.reclaim(lock, bob, alice);
  }

  function test_reclaim_revertsWhen_partySideNotPosted() public {
    // pool-drain regression: with only alice committed (Free), the never-posted bob side
    // cannot "reclaim" assets out of the pooled escrow even after its release
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitFor(ALICE, lock, alice, bob);
    _assertSwapState(lock, alice, bob, LockState.Free);

    _warpToTakerReclaim();
    vm.expectRevert(IOmnibus.TermsNotPosted.selector);
    vm.prank(BOB);
    omnibus.reclaim(lock, bob, alice);
  }

  function test_reclaim_revertsWhen_counterpartySideNotPosted() public {
    // defense-in-depth (harness-staged): a Committed same-chain lock must not refund a
    // counterparty side that was never posted
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    omnibus.setTermsHash(_swapIdFor(lock, alice, bob), omnibus.computeTermsHash(alice, bob));
    omnibus.setLockState(_swapIdFor(lock, alice, bob), LockState.Committed);
    omnibus.setPosted(_swapIdFor(lock, alice, bob), omnibus.computeTermsDigest(alice), true); // party side only

    _warpToProposerReclaim();
    vm.expectRevert(IOmnibus.TermsNotPosted.selector);
    omnibus.reclaim(lock, alice, bob);
  }

  function test_reclaim_revertsWhen_partyNotOnChain() public {
    // reclaim enforces the PARTY's chainId (the party reclaims its own escrow)
    Terms memory alice = _aliceTermsOn(OTHER_CHAIN_ID, _makeNativeAssets(DEFAULT_AMOUNT));
    Terms memory bob = _bobTerms();

    bytes32 hash = omnibus.computeTermsHash(alice, bob);
    omnibus.setLockState(_swapIdFor(lock, alice, bob), LockState.Committed);
    omnibus.setTermsHash(_swapIdFor(lock, alice, bob), hash);

    vm.expectRevert(TermsLib.ChainIdMismatch.selector);
    omnibus.reclaim(lock, alice, bob);
  }

  function test_reclaim_revertsWhen_beforeReclaimRelease() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);

    // time is at the taker-commit anchor, well before ALICE_RECLAIM_RELEASE
    vm.expectRevert(TermsLib.WindowViolated.selector);
    omnibus.reclaim(lock, alice, bob);
  }

  function test_reclaim_revertsWhen_takerReclaimsBeforeOwnRelease() public {
    // the taker's reclaim opens only at BOB_RECLAIM_RELEASE, not the proposer's
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);

    // proposer's release has passed but the taker's has not
    vm.warp(ALICE_RECLAIM_RELEASE);
    vm.expectRevert(TermsLib.WindowViolated.selector);
    vm.prank(BOB);
    omnibus.reclaim(lock, bob, alice);
  }

  // ============ Edge Cases ============

  function test_reclaim_succeedsAtExactReclaimRelease() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);

    // lower bound is inclusive
    vm.warp(ALICE_RECLAIM_RELEASE);

    omnibus.reclaim(lock, alice, bob);
    _assertSwapState(lock, alice, bob, LockState.Spent);
  }

  function test_reclaim_revertsWhen_oneSecondBeforeRelease() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);

    vm.warp(ALICE_RECLAIM_RELEASE - 1);
    vm.expectRevert(TermsLib.WindowViolated.selector);
    omnibus.reclaim(lock, alice, bob);
  }

  // ============ Shortfall Clamping (audit regression: negative rebase) ============
  // fungible payouts are clamped to the held balance (TermsLib.transferAssetsClamped)
  // so a balance-mutable token shrinking the pooled escrow in place can never
  // permanently block reclaim or hold the healthy leg hostage

  /// @dev the base setUp pre-funds the omnibus with a large mockERC20 float; a shortfall
  /// must be created against the ACTUAL held balance, so burn down to a target
  function _burnOmnibusERC20To(uint256 target) internal {
    mockERC20.burn(address(omnibus), mockERC20.balanceOf(address(omnibus)) - target);
  }

  function test_reclaim_clampsCounterpartyERC20PayoutWhenEscrowShrunk() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);
    // negative rebase: escrow is now 1 wei short of Bob's declared amount
    _burnOmnibusERC20To(DEFAULT_AMOUNT - 1);

    _warpToProposerReclaim();
    uint256 aliceBefore = ALICE.balance;
    uint256 bobBefore = mockERC20.balanceOf(BOB);

    // dual-leg reclaim: Bob is the counterparty leg here (Omnibus.reclaim counterparty site)
    omnibus.reclaim(lock, alice, bob);

    assertEq(ALICE.balance - aliceBefore, DEFAULT_AMOUNT); // healthy leg unaffected
    assertEq(mockERC20.balanceOf(BOB) - bobBefore, DEFAULT_AMOUNT - 1); // clamped remainder
    _assertSwapState(lock, alice, bob, LockState.Spent);
  }

  function test_reclaim_clampsPartyERC20PayoutWhenEscrowShrunk() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);
    _burnOmnibusERC20To(DEFAULT_AMOUNT - 1);

    _warpToTakerReclaim();
    uint256 aliceBefore = ALICE.balance;
    uint256 bobBefore = mockERC20.balanceOf(BOB);

    // Bob reclaims as party (Omnibus.reclaim party site); Alice is the counterparty leg
    omnibus.reclaim(lock, bob, alice);

    assertEq(ALICE.balance - aliceBefore, DEFAULT_AMOUNT);
    assertEq(mockERC20.balanceOf(BOB) - bobBefore, DEFAULT_AMOUNT - 1);
    _assertSwapState(lock, alice, bob, LockState.Spent);
  }

  function test_reclaim_clampsToZeroWhenEscrowEmptied() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);
    // worst case: the whole fungible escrow is gone
    _burnOmnibusERC20To(0);

    _warpToProposerReclaim();
    uint256 aliceBefore = ALICE.balance;
    uint256 bobBefore = mockERC20.balanceOf(BOB);

    omnibus.reclaim(lock, alice, bob);

    assertEq(ALICE.balance - aliceBefore, DEFAULT_AMOUNT); // native leg still recovered
    assertEq(mockERC20.balanceOf(BOB), bobBefore); // nothing left to pay
    _assertSwapState(lock, alice, bob, LockState.Spent);
  }

  // ============ Fuzz Tests ============

  function testFuzz_reclaim_anyTimeAfterRelease(uint256 t) public {
    t = bound(t, ALICE_RECLAIM_RELEASE, type(uint64).max);

    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitBothParties(lock, alice, bob);

    vm.warp(t);

    omnibus.reclaim(lock, alice, bob);
    _assertSwapState(lock, alice, bob, LockState.Spent);
  }
}
