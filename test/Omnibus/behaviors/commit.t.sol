// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Asset, AssetType, Terms, TermsLib} from '../../../src/TermsLib.sol';
import {CommitAuth, IOmnibus, LockState} from '../../../src/interfaces/IOmnibus.sol';
import {FeeOnTransferERC20Mock} from '../../mocks/FeeOnTransferERC20Mock.sol';
import {AssetHelper} from '../../utils/AssetHelper.sol';
import {AuthHelper} from '../../utils/AuthHelper.sol';
import {OmnibusTest} from '../Omnibus.t.sol';
import {
  IERC7913SignatureVerifier
} from '@quip.network/hashsigs-solidity-0.2.0/contracts/interfaces/IERC7913SignatureVerifier.sol';
import {
  IERC7913TransientAttestation
} from '@quip.network/hashsigs-solidity-0.2.0/contracts/interfaces/IERC7913TransientAttestation.sol';
import {Vm} from 'forge-std-1.14.0/Vm.sol';

/// @title Omnibus commit Tests
/// @dev Tests for Omnibus.commit
contract Omnibus_commit is OmnibusTest {
  using AssetHelper for *;

  // proposer (Alice-schedule) side carrying the given assets, on the local chain
  function _proposerSide(
    address reclaimRecipient,
    address recipient,
    Asset[] memory assets
  ) internal view returns (Terms memory) {
    return _makeTerms(
      block.chainid,
      reclaimRecipient,
      recipient,
      ALICE_COMMIT_DEADLINE,
      ALICE_CLAIM_DEADLINE,
      ALICE_RECLAIM_RELEASE,
      assets
    );
  }

  // ============ Success Cases ============

  function test_commit_sameChainFirstCommit() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    vm.warp(AT_PROPOSER_COMMIT);
    uint256 nativeAmount = _totalNativeForCommit(alice);
    vm.prank(ALICE);
    omnibus.commit{value: nativeAmount}(lock, alice, bob, AuthHelper.keyedAuth(address(verifierA), ALICE));

    // First commit on same-chain transitions to Free
    _assertLockState(lock, LockState.Free);
  }

  function test_commit_sameChainSecondCommit() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    // First commit
    _commitFor(ALICE, lock, alice, bob);
    _assertLockState(lock, LockState.Free);

    // Second commit transitions to Committed (taker commits after proposer's deadline)
    _commitFor(BOB, lock, bob, alice);
    _assertLockState(lock, LockState.Committed);
  }

  function test_commit_crossChainCommit() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobCrossChainTerms();

    _commitFor(ALICE, lock, alice, bob);

    // Cross-chain commit transitions directly to Committed
    _assertLockState(lock, LockState.Committed);
  }

  function test_commit_withNativeCollateral() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    uint256 omnibusBalanceBefore = address(omnibus).balance;
    uint256 nativeAmount = _totalNativeForCommit(alice);

    _commitFor(ALICE, lock, alice, bob);

    assertEq(address(omnibus).balance - omnibusBalanceBefore, nativeAmount);
  }

  function test_commit_withERC20Assets() public {
    Terms memory alice = _proposerSide(ALICE, ALICE_RECIPIENT, _makeERC20Assets(DEFAULT_AMOUNT));
    Terms memory bob = _bobTerms();

    uint256 aliceBalanceBefore = mockERC20.balanceOf(ALICE);
    uint256 omnibusBalanceBefore = mockERC20.balanceOf(address(omnibus));

    _commitFor(ALICE, lock, alice, bob);

    assertEq(aliceBalanceBefore - mockERC20.balanceOf(ALICE), DEFAULT_AMOUNT);
    assertEq(mockERC20.balanceOf(address(omnibus)) - omnibusBalanceBefore, DEFAULT_AMOUNT);
  }

  function test_commit_withERC721Assets() public {
    uint256 tokenId = ERC721_ALICE_TOKEN;
    Terms memory alice = _proposerSide(ALICE, ALICE_RECIPIENT, _makeERC721Assets(tokenId));
    Terms memory bob = _bobTerms();

    assertEq(mockERC721.ownerOf(tokenId), ALICE);

    _commitFor(ALICE, lock, alice, bob);

    assertEq(mockERC721.ownerOf(tokenId), address(omnibus));
  }

  function test_commit_withERC1155Assets() public {
    Terms memory alice = _proposerSide(ALICE, ALICE_RECIPIENT, _makeERC1155Assets(ERC1155_TOKEN_ID, 100));
    Terms memory bob = _bobTerms();

    uint256 aliceBalanceBefore = mockERC1155.balanceOf(ALICE, ERC1155_TOKEN_ID);
    uint256 omnibusBalanceBefore = mockERC1155.balanceOf(address(omnibus), ERC1155_TOKEN_ID);

    _commitFor(ALICE, lock, alice, bob);

    assertEq(aliceBalanceBefore - mockERC1155.balanceOf(ALICE, ERC1155_TOKEN_ID), 100);
    assertEq(mockERC1155.balanceOf(address(omnibus), ERC1155_TOKEN_ID) - omnibusBalanceBefore, 100);
  }

  function test_commit_withMixedAssets() public {
    Asset[] memory mixedAssets = new Asset[](3);
    mixedAssets[0] = _makeNativeAsset(1 ether);
    mixedAssets[1] = _makeERC20Asset(100 ether);
    mixedAssets[2] = _makeERC1155Asset(ERC1155_TOKEN_ID, 50);

    Terms memory alice = _proposerSide(ALICE, ALICE_RECIPIENT, mixedAssets);
    Terms memory bob = _bobTerms();

    uint256 nativeAmount = 1 ether;
    uint256 omnibusNativeBefore = address(omnibus).balance;
    uint256 omnibusERC20Before = mockERC20.balanceOf(address(omnibus));
    uint256 omnibusERC1155Before = mockERC1155.balanceOf(address(omnibus), ERC1155_TOKEN_ID);

    _commitFor(ALICE, lock, alice, bob);

    assertEq(address(omnibus).balance - omnibusNativeBefore, nativeAmount);
    assertEq(mockERC20.balanceOf(address(omnibus)) - omnibusERC20Before, 100 ether);
    assertEq(mockERC1155.balanceOf(address(omnibus), ERC1155_TOKEN_ID) - omnibusERC1155Before, 50);
  }

  function test_commit_emitsCommitmentEvent() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    vm.warp(AT_PROPOSER_COMMIT);
    uint256 nativeAmount = _totalNativeForCommit(alice);

    vm.recordLogs();
    vm.prank(ALICE);
    omnibus.commit{value: nativeAmount}(lock, alice, bob, AuthHelper.keyedAuth(address(verifierA), ALICE));

    Vm.Log[] memory logs = vm.getRecordedLogs();
    bool foundEvent = false;
    for (uint256 i = 0; i < logs.length; i++) {
      if (logs[i].topics[0] == IOmnibus.Commitment.selector) {
        assertEq(logs[i].topics[1], lock);
        assertEq(address(uint160(uint256(logs[i].topics[2]))), ALICE);
        foundEvent = true;
        break;
      }
    }
    assertTrue(foundEvent, 'Commitment event not emitted');
  }

  function test_commit_storesTermsHash() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitFor(ALICE, lock, alice, bob);

    // the stored hash is the canonical (order-independent) digest of both sides
    assertEq(omnibus.termsHash(lock), omnibus.computeTermsHash(alice, bob));
  }

  function test_commit_marksSidePosted() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    bytes32 aliceDigest = omnibus.computeTermsDigest(alice);
    bytes32 bobDigest = omnibus.computeTermsDigest(bob);
    assertFalse(omnibus.posted(lock, aliceDigest));
    assertFalse(omnibus.posted(lock, bobDigest));

    // each commit posts exactly the committing side
    _commitFor(ALICE, lock, alice, bob);
    assertTrue(omnibus.posted(lock, aliceDigest));
    assertFalse(omnibus.posted(lock, bobDigest));

    _commitFor(BOB, lock, bob, alice);
    assertTrue(omnibus.posted(lock, aliceDigest));
    assertTrue(omnibus.posted(lock, bobDigest));
  }

  function test_commit_anyoneCanCommitOwnSide() public {
    // commit is permissionless: any caller can post a side; assets are pulled from the caller
    Terms memory charlie = _proposerSide(CHARLIE, CHARLIE, _makeNativeAssets(DEFAULT_AMOUNT));
    Terms memory bob = _bobTerms();

    _commitFor(CHARLIE, lock, charlie, bob);

    _assertLockState(lock, LockState.Free);
  }

  // ============ State Transition Tests ============

  function test_commit_lockStateUnusedToFree() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _assertLockState(lock, LockState.Unused);
    _commitFor(ALICE, lock, alice, bob);
    _assertLockState(lock, LockState.Free);
  }

  function test_commit_lockStateFreeToCommitted() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitFor(ALICE, lock, alice, bob);
    _assertLockState(lock, LockState.Free);

    _commitFor(BOB, lock, bob, alice);
    _assertLockState(lock, LockState.Committed);
  }

  function test_commit_lockStateUnusedToCommitted() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobCrossChainTerms();

    _assertLockState(lock, LockState.Unused);
    _commitFor(ALICE, lock, alice, bob);
    _assertLockState(lock, LockState.Committed);
  }

  // ============ Access Control ============

  function test_commit_permissionless_anySenderCanCommit() public {
    // commit is permissionless: any funded sender may post a side with its own keyed identity
    address anySender = makeAddr('anySender');
    vm.deal(anySender, DEFAULT_AMOUNT);

    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    vm.warp(AT_PROPOSER_COMMIT);
    vm.prank(anySender);
    omnibus.commit{value: _totalNativeForCommit(alice)}(
      lock, alice, bob, AuthHelper.keyedAuth(address(verifierA), anySender)
    );

    _assertLockState(lock, LockState.Free);
  }

  // ============ Revert Cases ============

  function test_commit_pullsFromCaller_notNamedParty() public {
    // commit pulls assets from msg.sender, NOT from the side's named reclaimRecipient.
    // Any caller (Charlie) naming a victim (Alice) on an ERC20 side cannot
    // drain Alice's standing approval: the pull debits Charlie, leaving Alice untouched.
    Terms memory victim = _proposerSide(ALICE, ALICE_RECIPIENT, _makeERC20Assets(DEFAULT_AMOUNT));
    Terms memory attacker = _bobTermsOn(OTHER_CHAIN_ID, _makeERC20Assets(DEFAULT_AMOUNT));

    uint256 aliceBefore = mockERC20.balanceOf(ALICE);
    uint256 charlieBefore = mockERC20.balanceOf(CHARLIE);

    _commitFor(CHARLIE, lock, victim, attacker);

    // Alice's approval was untouched; Charlie funded the escrow
    assertEq(mockERC20.balanceOf(ALICE), aliceBefore);
    assertEq(charlieBefore - mockERC20.balanceOf(CHARLIE), DEFAULT_AMOUNT);
  }

  function test_commit_revertsWhen_partyChainIdMismatch() public {
    Terms memory alice = _makeTerms(
      OTHER_CHAIN_ID, // Wrong chain
      ALICE,
      ALICE_RECIPIENT,
      ALICE_COMMIT_DEADLINE,
      ALICE_CLAIM_DEADLINE,
      ALICE_RECLAIM_RELEASE,
      _makeNativeAssets(DEFAULT_AMOUNT)
    );
    Terms memory bob = _bobTerms();

    vm.warp(AT_PROPOSER_COMMIT);
    vm.expectRevert(TermsLib.ChainIdMismatch.selector);
    vm.prank(ALICE);
    omnibus.commit{value: DEFAULT_AMOUNT}(lock, alice, bob, AuthHelper.keyedAuth(address(verifierA), ALICE));
  }

  function test_commit_revertsWhen_proposerCommitWindowElapsed() public {
    // freshness is enforced by the commit window, not validateTerms: committing at/after the
    // proposer's commitment deadline falls outside [0, commitmentDeadline) and reverts
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    vm.warp(ALICE_COMMIT_DEADLINE); // upper bound is exclusive
    vm.expectRevert(TermsLib.WindowViolated.selector);
    vm.prank(ALICE);
    omnibus.commit{value: _totalNativeForCommit(alice)}(
      lock, alice, bob, AuthHelper.keyedAuth(address(verifierA), ALICE)
    );
  }

  function test_commit_revertsWhen_takerCommitsBeforeProposerDeadline() public {
    // the taker's commit window is [proposer.commit, taker.commit); committing before the
    // proposer's commitment deadline is too early and reverts
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitFor(ALICE, lock, alice, bob);

    vm.warp(ALICE_COMMIT_DEADLINE - 1); // before the taker window opens
    vm.expectRevert(TermsLib.WindowViolated.selector);
    vm.prank(BOB);
    omnibus.commit{value: 0}(lock, bob, alice, AuthHelper.keyedAuth(address(verifierA), BOB));
  }

  function test_commit_takerSucceedsAtExactProposerDeadline() public {
    // the taker window's lower bound (the proposer's commitmentDeadline) is inclusive
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitFor(ALICE, lock, alice, bob);

    vm.warp(ALICE_COMMIT_DEADLINE);
    vm.prank(BOB);
    omnibus.commit{value: 0}(lock, bob, alice, AuthHelper.keyedAuth(address(verifierA), BOB));

    _assertLockState(lock, LockState.Committed);
  }

  function test_commit_revertsWhen_takerCommitsAtOwnDeadline() public {
    // the taker window's upper bound (the taker's own commitmentDeadline) is exclusive
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitFor(ALICE, lock, alice, bob);

    vm.warp(BOB_COMMIT_DEADLINE);
    vm.expectRevert(TermsLib.WindowViolated.selector);
    vm.prank(BOB);
    omnibus.commit{value: 0}(lock, bob, alice, AuthHelper.keyedAuth(address(verifierA), BOB));
  }

  function test_commit_revertsWhen_incorrectNativeAmount() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    uint256 correctAmount = _totalNativeForCommit(alice);

    vm.warp(AT_PROPOSER_COMMIT);
    vm.expectRevert(IOmnibus.IncorrectNativeAmountReceived.selector);
    vm.prank(ALICE);
    omnibus.commit{value: correctAmount + 1}(lock, alice, bob, AuthHelper.keyedAuth(address(verifierA), ALICE));
  }

  function test_commit_revertsWhen_excessNativeAmount() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    uint256 correctAmount = _totalNativeForCommit(alice);

    vm.warp(AT_PROPOSER_COMMIT);
    vm.expectRevert(IOmnibus.IncorrectNativeAmountReceived.selector);
    vm.prank(ALICE);
    omnibus.commit{value: correctAmount + 1 ether}(lock, alice, bob, AuthHelper.keyedAuth(address(verifierA), ALICE));
  }

  function test_commit_revertsWhen_insufficientNativeAmount() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    uint256 correctAmount = _totalNativeForCommit(alice);

    vm.warp(AT_PROPOSER_COMMIT);
    vm.expectRevert(IOmnibus.IncorrectNativeAmountReceived.selector);
    vm.prank(ALICE);
    omnibus.commit{value: correctAmount - 1}(lock, alice, bob, AuthHelper.keyedAuth(address(verifierA), ALICE));
  }

  function test_commit_revertsWhen_lockAlreadyCommitted() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    // Both parties commit
    _commitBothParties(lock, alice, bob);
    _assertLockState(lock, LockState.Committed);

    // Try to commit again (re-enter the proposer commit window)
    vm.warp(AT_PROPOSER_COMMIT);
    vm.expectRevert(IOmnibus.InvalidLockAdvancement.selector);
    vm.prank(ALICE);
    omnibus.commit{value: _totalNativeForCommit(alice)}(
      lock, alice, bob, AuthHelper.keyedAuth(address(verifierA), ALICE)
    );
  }

  function test_commit_revertsWhen_lockAlreadySpent() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    // Commit both and settle (same-chain claim by the proposer)
    _settleSameChain(lock, alice, bob);
    _assertLockState(lock, LockState.Spent);

    // Try to commit again (re-enter the proposer commit window)
    vm.warp(AT_PROPOSER_COMMIT);
    vm.expectRevert(IOmnibus.InvalidLockAdvancement.selector);
    vm.prank(ALICE);
    omnibus.commit{value: _totalNativeForCommit(alice)}(
      lock, alice, bob, AuthHelper.keyedAuth(address(verifierA), ALICE)
    );
  }

  function test_commit_revertsWhen_termsMismatchOnSecondCommit() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    // First commit
    _commitFor(ALICE, lock, alice, bob);

    // Second commit with different terms (still a valid taker schedule, different amount)
    Terms memory bobModified = _bobTermsOn(block.chainid, _makeERC20Assets(DEFAULT_AMOUNT + 1 ether));

    vm.warp(AT_TAKER_COMMIT);
    vm.expectRevert(IOmnibus.TermsMismatch.selector);
    vm.prank(BOB);
    omnibus.commit{value: _totalNativeForCommit(bobModified)}(
      lock, bobModified, alice, AuthHelper.keyedAuth(address(verifierA), BOB)
    );
  }

  function test_commit_revertsWhen_repostingSameSide() public {
    // a second same-chain commit must post the OTHER side; re-posting the already-posted side
    // (which would self-advance the lock to Committed with only one side escrowed) reverts
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitFor(ALICE, lock, alice, bob);
    _assertLockState(lock, LockState.Free);

    vm.warp(AT_PROPOSER_COMMIT); // still inside the proposer commit window
    vm.expectRevert(IOmnibus.TermsAlreadyPosted.selector);
    vm.prank(ALICE);
    omnibus.commit{value: _totalNativeForCommit(alice)}(
      lock, alice, bob, AuthHelper.keyedAuth(address(verifierA), ALICE)
    );
  }

  function test_commit_revertsWhen_feeOnTransferToken() public {
    // a fee-on-transfer token delivers less than the declared amount; commit must
    // reject it rather than record more than the escrow received
    FeeOnTransferERC20Mock feeToken = new FeeOnTransferERC20Mock('Fee', 'FEE', 100); // 1% fee
    feeToken.mint(ALICE, 1000 ether);
    vm.prank(ALICE);
    feeToken.approve(address(omnibus), type(uint256).max);

    Terms memory alice =
      _proposerSide(ALICE, ALICE_RECIPIENT, AssetHelper.makeERC20(address(feeToken), 100 ether).toArray());
    Terms memory bob = _bobTerms();

    uint256 aliceBefore = feeToken.balanceOf(ALICE);

    vm.warp(AT_PROPOSER_COMMIT);
    vm.expectRevert(TermsLib.UnexpectedAmountReceived.selector);
    vm.prank(ALICE);
    omnibus.commit(lock, alice, bob, AuthHelper.keyedAuth(address(verifierA), ALICE));

    // the revert rolled back the pull; Alice keeps her tokens
    assertEq(feeToken.balanceOf(ALICE), aliceBefore);
  }

  function test_commit_revertsWhen_zeroAmountAsset() public {
    Terms memory alice = _proposerSide(ALICE, ALICE_RECIPIENT, _makeNativeAssets(0));
    Terms memory bob = _bobTerms();

    vm.warp(AT_PROPOSER_COMMIT);
    vm.expectRevert(TermsLib.ZeroAmount.selector);
    vm.prank(ALICE);
    omnibus.commit{value: 0}(lock, alice, bob, AuthHelper.keyedAuth(address(verifierA), ALICE));
  }

  function test_commit_revertsWhen_invalidNativeAsset() public {
    Asset[] memory assets = new Asset[](1);
    assets[0] = Asset({assetType: AssetType.Native, target: address(1), id: 0, amount: DEFAULT_AMOUNT});

    Terms memory alice = _proposerSide(ALICE, ALICE_RECIPIENT, assets);
    Terms memory bob = _bobTerms();

    vm.warp(AT_PROPOSER_COMMIT);
    vm.expectRevert(TermsLib.InvalidNativeAsset.selector);
    vm.prank(ALICE);
    omnibus.commit{value: DEFAULT_AMOUNT}(lock, alice, bob, AuthHelper.keyedAuth(address(verifierA), ALICE));
  }

  function test_commit_revertsWhen_invalidERC20Asset() public {
    Asset[] memory assets = new Asset[](1);
    assets[0] = Asset({assetType: AssetType.ERC20, target: address(0), id: 0, amount: DEFAULT_AMOUNT}); // Zero target

    Terms memory alice = _proposerSide(ALICE, ALICE_RECIPIENT, assets);
    Terms memory bob = _bobTerms();

    vm.warp(AT_PROPOSER_COMMIT);
    vm.expectRevert(TermsLib.InvalidERC20Asset.selector);
    vm.prank(ALICE);
    omnibus.commit{value: 0}(lock, alice, bob, AuthHelper.keyedAuth(address(verifierA), ALICE));
  }

  function test_commit_revertsWhen_invalidERC721Asset() public {
    Asset[] memory assets = new Asset[](1);
    assets[0] = Asset({assetType: AssetType.ERC721, target: address(0), id: 1, amount: 1}); // Zero target

    Terms memory alice = _proposerSide(ALICE, ALICE_RECIPIENT, assets);
    Terms memory bob = _bobTerms();

    vm.warp(AT_PROPOSER_COMMIT);
    vm.expectRevert(TermsLib.InvalidERC721Asset.selector);
    vm.prank(ALICE);
    omnibus.commit{value: 0}(lock, alice, bob, AuthHelper.keyedAuth(address(verifierA), ALICE));
  }

  function test_commit_revertsWhen_invalidERC1155Asset() public {
    Asset[] memory assets = new Asset[](1);
    assets[0] = Asset({assetType: AssetType.ERC1155, target: address(0), id: 1, amount: 100}); // Zero target

    Terms memory alice = _proposerSide(ALICE, ALICE_RECIPIENT, assets);
    Terms memory bob = _bobTerms();

    vm.warp(AT_PROPOSER_COMMIT);
    vm.expectRevert(TermsLib.InvalidERC1155Asset.selector);
    vm.prank(ALICE);
    omnibus.commit{value: 0}(lock, alice, bob, AuthHelper.keyedAuth(address(verifierA), ALICE));
  }

  function test_commit_revertsWhen_invalidCounterpartyTerms() public {
    // commit validates BOTH sides; a malformed counterparty (zero-amount asset) reverts even
    // though the party side is valid
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTermsOn(block.chainid, _makeERC20Assets(0));

    vm.warp(AT_PROPOSER_COMMIT);
    vm.expectRevert(TermsLib.ZeroAmount.selector);
    vm.prank(ALICE);
    omnibus.commit{value: _totalNativeForCommit(alice)}(
      lock, alice, bob, AuthHelper.keyedAuth(address(verifierA), ALICE)
    );
  }

  // ============ Fee Tests ============

  function test_commit_requiresFeeOnTopOfNative() public {
    uint256 fee = 0.005 ether;
    omnibus.setCommitmentFee(fee);

    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    uint256 nativeAmount = _totalNativeForCommit(alice);
    uint256 omnibusBalanceBefore = address(omnibus).balance;

    vm.warp(AT_PROPOSER_COMMIT);
    vm.prank(ALICE);
    omnibus.commit{value: nativeAmount + fee}(lock, alice, bob, AuthHelper.keyedAuth(address(verifierA), ALICE));

    // Both native assets and fee should be received
    assertEq(address(omnibus).balance - omnibusBalanceBefore, nativeAmount + fee);
    _assertLockState(lock, LockState.Free);
  }

  function test_commit_revertsWhen_feeNotIncluded() public {
    uint256 fee = 0.005 ether;
    omnibus.setCommitmentFee(fee);

    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    uint256 nativeAmount = _totalNativeForCommit(alice);

    // Send only the native amount without fee
    vm.warp(AT_PROPOSER_COMMIT);
    vm.expectRevert(IOmnibus.IncorrectNativeAmountReceived.selector);
    vm.prank(ALICE);
    omnibus.commit{value: nativeAmount}(lock, alice, bob, AuthHelper.keyedAuth(address(verifierA), ALICE));
  }

  function test_commit_revertsWhen_partialFeeIncluded() public {
    uint256 fee = 0.005 ether;
    omnibus.setCommitmentFee(fee);

    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    uint256 nativeAmount = _totalNativeForCommit(alice);

    // Send native amount plus partial fee
    vm.warp(AT_PROPOSER_COMMIT);
    vm.expectRevert(IOmnibus.IncorrectNativeAmountReceived.selector);
    vm.prank(ALICE);
    omnibus.commit{value: nativeAmount + fee - 1}(lock, alice, bob, AuthHelper.keyedAuth(address(verifierA), ALICE));
  }

  function test_commit_worksWithZeroFee() public {
    // Fee defaults to 0, should work as before
    assertEq(omnibus.commitmentFee(), 0);

    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitFor(ALICE, lock, alice, bob);

    _assertLockState(lock, LockState.Free);
  }

  function test_commit_withMaxFee() public {
    uint256 maxFee = omnibus.MAX_FEE();
    omnibus.setCommitmentFee(maxFee);

    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    uint256 nativeAmount = _totalNativeForCommit(alice);

    vm.warp(AT_PROPOSER_COMMIT);
    vm.prank(ALICE);
    omnibus.commit{value: nativeAmount + maxFee}(lock, alice, bob, AuthHelper.keyedAuth(address(verifierA), ALICE));

    _assertLockState(lock, LockState.Free);
  }

  function test_commit_incrementsAccruedFees() public {
    uint256 fee = 0.005 ether;
    omnibus.setCommitmentFee(fee);

    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    assertEq(omnibus.accruedFees(), 0);

    // first commit accrues one fee
    _commitFor(ALICE, lock, alice, bob);
    assertEq(omnibus.accruedFees(), fee);

    // second commit accrues another
    _commitFor(BOB, lock, bob, alice);
    assertEq(omnibus.accruedFees(), 2 * fee);
  }

  function test_commit_feeAccumulatesAcrossCommits() public {
    uint256 fee = 0.005 ether;
    omnibus.setCommitmentFee(fee);

    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    uint256 omnibusBalanceBefore = address(omnibus).balance;
    uint256 aliceNative = _totalNativeForCommit(alice);
    uint256 bobNative = _totalNativeForCommit(bob);

    // Both parties commit
    _commitBothParties(lock, alice, bob);

    // Two fees should be accumulated
    assertEq(address(omnibus).balance - omnibusBalanceBefore, aliceNative + bobNative + (2 * fee));
  }

  // ============ Fuzz Tests ============

  function testFuzz_commit_acceptsValidNativeAmount(uint256 amount) public {
    amount = bound(amount, 1, 50 ether);

    Terms memory alice = _proposerSide(ALICE, ALICE_RECIPIENT, _makeNativeAssets(amount));
    Terms memory bob = _bobTerms();

    vm.warp(AT_PROPOSER_COMMIT);
    vm.prank(ALICE);
    omnibus.commit{value: amount}(lock, alice, bob, AuthHelper.keyedAuth(address(verifierA), ALICE));

    _assertLockState(lock, LockState.Free);
  }

  function testFuzz_commit_acceptsAnyTimeInProposerWindow(uint256 t) public {
    // the proposer may commit at any instant in [0, ALICE_COMMIT_DEADLINE)
    t = bound(t, 0, ALICE_COMMIT_DEADLINE - 1);

    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    vm.warp(t);
    vm.prank(ALICE);
    omnibus.commit{value: _totalNativeForCommit(alice)}(
      lock, alice, bob, AuthHelper.keyedAuth(address(verifierA), ALICE)
    );

    _assertLockState(lock, LockState.Free);
  }

  function testFuzz_commit_acceptsAnyTimeInTakerWindow(uint256 t) public {
    // the taker may commit at any instant in [ALICE_COMMIT_DEADLINE, BOB_COMMIT_DEADLINE)
    t = bound(t, ALICE_COMMIT_DEADLINE, BOB_COMMIT_DEADLINE - 1);

    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitFor(ALICE, lock, alice, bob);

    vm.warp(t);
    vm.prank(BOB);
    omnibus.commit{value: 0}(lock, bob, alice, AuthHelper.keyedAuth(address(verifierA), BOB));

    _assertLockState(lock, LockState.Committed);
  }

  // ============ Commit authorization: wiring + digest binding ============
  // The auth guard's own verdicts are unit-tested in _enforceCommitAuth.t.sol;
  // these prove commit WIRES the guard in, binds the digest to calldata, and
  // implements the permissionless funding model.

  /// @dev commit alice's (native-asset) side as `sender` with explicit auth, inside
  /// the proposer window with the exact required value
  function _commitAliceSideAs(address sender, CommitAuth memory auth) internal {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();
    vm.warp(AT_PROPOSER_COMMIT);
    vm.prank(sender);
    omnibus.commit{value: _totalNativeForCommit(alice)}(lock, alice, bob, auth);
  }

  /// @dev the same commit but expecting `revertData`; zero-length means "any revert"
  function _expectCommitAliceSideRevert(address sender, CommitAuth memory auth, bytes memory revertData) internal {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();
    vm.warp(AT_PROPOSER_COMMIT);
    if (revertData.length == 0) vm.expectRevert();
    else vm.expectRevert(revertData);
    vm.prank(sender);
    omnibus.commit{value: _totalNativeForCommit(alice)}(lock, alice, bob, auth);
  }

  function _aliceDigestFor(bytes memory signer) internal view returns (bytes32) {
    return omnibus.commitDigest(lock, _aliceTerms(), _bobTerms(), keccak256(signer));
  }

  /// @dev baseline: verifierA rejects every verify call (returns wrong magic).
  /// Selector-prefix mock — matches ANY verify calldata
  function _mockVerifierRejectsAll() internal {
    vm.mockCall(
      address(verifierA),
      abi.encodeWithSelector(IERC7913SignatureVerifier.verify.selector),
      abi.encode(bytes4(0xffffffff))
    );
  }

  /// @dev verifierA accepts EXACTLY (key, digest, signature) and rejects all
  /// else: a reject-all prefix mock underneath, an exact-calldata accept on
  /// top (specific mocks take precedence; registered second wins either way)
  function _mockVerifierAcceptsOnly(bytes memory key, bytes32 digest, bytes memory signature) internal {
    _mockVerifierRejectsAll();
    vm.mockCall(
      address(verifierA),
      abi.encodeCall(IERC7913SignatureVerifier.verify, (key, digest, signature)),
      abi.encode(IERC7913SignatureVerifier.verify.selector)
    );
  }

  function test_commit_revertsWhen_authFails() public {
    // the wiring branch: bad auth must stop a real commit
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();
    vm.warp(AT_PROPOSER_COMMIT);
    vm.expectRevert(IOmnibus.MalformedSigner.selector);
    vm.prank(ALICE);
    omnibus.commit{value: _totalNativeForCommit(alice)}(
      lock, alice, bob, CommitAuth({signer: abi.encodePacked(ALICE), signature: '', walletBinding: bytes32(0)})
    );
  }

  // ============ Malformed blobs (keyed identities only) ============

  function test_commit_revertsWhen_signerEmpty() public {
    _expectCommitAliceSideRevert(
      ALICE,
      CommitAuth({signer: '', signature: '', walletBinding: bytes32(0)}),
      abi.encodePacked(IOmnibus.MalformedSigner.selector)
    );
  }

  function test_commit_revertsWhen_signerOneByte() public {
    _expectCommitAliceSideRevert(
      ALICE,
      CommitAuth({signer: hex'01', signature: '', walletBinding: bytes32(0)}),
      abi.encodePacked(IOmnibus.MalformedSigner.selector)
    );
  }

  function test_commit_revertsWhen_signerNineteenBytes() public {
    _expectCommitAliceSideRevert(
      ALICE,
      CommitAuth({signer: new bytes(19), signature: '', walletBinding: bytes32(0)}),
      abi.encodePacked(IOmnibus.MalformedSigner.selector)
    );
  }

  function test_commit_revertsWhen_signerIsBareAddress_evenWhenSender() public {
    // a 20-byte blob is a bare address: the self-auth shortcut is GONE, so even
    // msg.sender's own address is malformed — keyed identities only
    _expectCommitAliceSideRevert(
      ALICE,
      CommitAuth({signer: abi.encodePacked(ALICE), signature: '', walletBinding: bytes32(0)}),
      abi.encodePacked(IOmnibus.MalformedSigner.selector)
    );
  }

  function test_commit_revertsWhen_signerIsBareContractAddress() public {
    // has-code changes nothing (ERC-1271 removed): a contract's bare
    // 20-byte address is malformed like any other
    _expectCommitAliceSideRevert(
      CHARLIE,
      CommitAuth({signer: abi.encodePacked(address(verifierA)), signature: 'sig', walletBinding: bytes32(0)}),
      abi.encodePacked(IOmnibus.MalformedSigner.selector)
    );
  }

  // ============ ERC-7913 keyed route ============

  function test_commit_keyed_revertsWhen_verifierNotActive() public {
    bytes memory signer = abi.encodePacked(address(verifierB), bytes('alice-key'));
    _expectCommitAliceSideRevert(
      ALICE,
      CommitAuth({signer: signer, signature: '', walletBinding: bytes32(0)}),
      abi.encodePacked(IOmnibus.VerifierNotActive.selector)
    );
  }

  function test_commit_keyed_succeeds() public {
    // no mock needed: the one-function VerifierMock accepts everything
    _commitAliceSideAs(ALICE, AuthHelper.auth(aliceSigner));
    _assertLockState(lock, LockState.Free);
  }

  function test_commit_keyed_succeedsOnExactDigest() public {
    // digest exactness: accept ONLY the raw-mirror digest (spec re-derivation);
    // the commit passes iff the enforced digest equals the mirror
    bytes32 mirror = _mirrorCommitDigest(lock, _aliceTerms(), _bobTerms(), aliceSigner);
    assertEq(mirror, _aliceDigestFor(aliceSigner), 'mirror must equal the commitDigest view');
    _mockVerifierAcceptsOnly(bytes('alice-key'), mirror, bytes('envelope'));

    _commitAliceSideAs(
      ALICE, CommitAuth({signer: aliceSigner, signature: bytes('envelope'), walletBinding: bytes32(0)})
    );
    _assertLockState(lock, LockState.Free);
  }

  function test_commit_keyed_revertsWhen_digestNotAccepted() public {
    _mockVerifierAcceptsOnly(bytes('alice-key'), keccak256('some other digest'), bytes('envelope'));

    _expectCommitAliceSideRevert(
      ALICE,
      CommitAuth({signer: aliceSigner, signature: bytes('envelope'), walletBinding: bytes32(0)}),
      abi.encodePacked(IOmnibus.InvalidCommitSignature.selector)
    );
  }

  function test_commit_keyed_revertsWhen_verifierRejects() public {
    _mockVerifierRejectsAll();
    _expectCommitAliceSideRevert(
      ALICE, AuthHelper.auth(aliceSigner), abi.encodePacked(IOmnibus.InvalidCommitSignature.selector)
    );
  }

  function test_commit_keyed_revertsWhen_verifierReverts_bubbles() public {
    vm.mockCallRevert(
      address(verifierA),
      abi.encodeWithSelector(IERC7913SignatureVerifier.verify.selector),
      abi.encodeWithSignature('Error(string)', 'verifier reverted')
    );
    _expectCommitAliceSideRevert(
      ALICE, AuthHelper.auth(aliceSigner), abi.encodeWithSignature('Error(string)', 'verifier reverted')
    );
  }

  function test_commit_keyed_revertsWhen_wrongMagicReturned() public {
    // a plausible-but-wrong selector must NOT be treated as valid
    vm.mockCall(
      address(verifierA),
      abi.encodeWithSelector(IERC7913SignatureVerifier.verify.selector),
      abi.encode(bytes4(0x12345678))
    );
    _expectCommitAliceSideRevert(
      ALICE, AuthHelper.auth(aliceSigner), abi.encodePacked(IOmnibus.InvalidCommitSignature.selector)
    );
  }

  function test_commit_keyed_relayedByAnySender() public {
    // Alice's keyed identity endorses; CHARLIE submits and FUNDS (sender pays,
    // identity authorizes)
    _commitAliceSideAs(CHARLIE, AuthHelper.auth(aliceSigner));
    _assertLockState(lock, LockState.Free);
  }

  // ============ Digest exactness: tampered context is rejected ============

  /// @dev verifierA accepts EXACTLY the digest for (lock, party, counterparty,
  /// aliceSigner); any on-chain tampering with that context recomputes a
  /// different digest, falls through to the reject baseline, and fails
  function _authAcceptedOnlyFor(
    bytes32 _lock,
    Terms memory party,
    Terms memory cp
  ) internal returns (CommitAuth memory) {
    _mockVerifierAcceptsOnly(bytes('alice-key'), _mirrorCommitDigest(_lock, party, cp, aliceSigner), bytes('envelope'));
    return CommitAuth({signer: aliceSigner, signature: bytes('envelope'), walletBinding: bytes32(0)});
  }

  function _expectTamperedCommitRejected(
    CommitAuth memory auth,
    bytes32 _lock,
    Terms memory party,
    Terms memory cp
  ) internal {
    vm.warp(AT_PROPOSER_COMMIT);
    vm.expectRevert(IOmnibus.InvalidCommitSignature.selector);
    vm.prank(CHARLIE);
    omnibus.commit{value: _totalNativeForCommit(party)}(_lock, party, cp, auth);
  }

  function test_commit_digest_revertsWhen_lockTampered() public {
    CommitAuth memory auth = _authAcceptedOnlyFor(lock, _aliceTerms(), _bobTerms());
    bytes32 otherLock = omnibus.exposed_generateLock(keccak256('other-secret'));
    _expectTamperedCommitRejected(auth, otherLock, _aliceTerms(), _bobTerms());
  }

  function test_commit_digest_revertsWhen_partyTermsTampered() public {
    CommitAuth memory auth = _authAcceptedOnlyFor(lock, _aliceTerms(), _bobTerms());
    Terms memory tampered = _aliceTermsOn(block.chainid, _makeNativeAssets(DEFAULT_AMOUNT + 1));
    _expectTamperedCommitRejected(auth, lock, tampered, _bobTerms());
  }

  function test_commit_digest_revertsWhen_counterpartyTermsTampered() public {
    CommitAuth memory auth = _authAcceptedOnlyFor(lock, _aliceTerms(), _bobTerms());
    Terms memory tampered = _bobTermsOn(block.chainid, _makeERC20Assets(DEFAULT_AMOUNT + 1));
    _expectTamperedCommitRejected(auth, lock, _aliceTerms(), tampered);
  }

  function test_commit_digest_revertsWhen_signerHashTampered() public {
    // envelope valid for the digest bound to ALICE's blob, but the declared blob
    // is swapped to another keyed identity: signerHash binding must reject the
    // transplant (the on-chain digest is recomputed from the DECLARED blob)
    bytes memory swappedSigner = abi.encodePacked(address(verifierA), bytes('other-key'));
    _mockVerifierAcceptsOnly(bytes('other-key'), _aliceDigestFor(aliceSigner), bytes('envelope'));

    _expectCommitAliceSideRevert(
      CHARLIE,
      CommitAuth({signer: swappedSigner, signature: bytes('envelope'), walletBinding: bytes32(0)}),
      abi.encodePacked(IOmnibus.InvalidCommitSignature.selector)
    );
  }

  function test_commit_digest_revertsWhen_chainIdTampered() public {
    // an envelope endorsed for THIS chain's digest must not validate against
    // chain-999 context (the replay scope is the baked DOMAIN_SEPARATOR —
    // per-chain deployments bake different separators). Terms must move with
    // the chain (enforceChainId), so rebuild them on the new id: their digests
    // change and the envelope was never accepted for that context
    CommitAuth memory auth = _authAcceptedOnlyFor(lock, _aliceTerms(), _bobTerms());

    uint256 newChainId = 999;
    vm.chainId(newChainId);
    Terms memory aliceOn999 = _aliceTermsOn(newChainId, _makeNativeAssets(DEFAULT_AMOUNT));
    Terms memory bobOn999 = _bobTermsOn(newChainId, _makeERC20Assets(DEFAULT_AMOUNT));

    _expectTamperedCommitRejected(auth, lock, aliceOn999, bobOn999);
  }

  // ============ Attested route: wiring + envelope binding ============
  // The guard's attested verdicts are unit-tested in _enforceCommitAuth.t.sol;
  // these prove commit wires the SAME recomputed digest into the envelope, that
  // the route pins msg.sender to the attesting account, and that the lock state
  // machine consumes an attestation on first use (the route has no nonce — this
  // IS its intra-transaction replay scope). Real single-transaction
  // verifyAndAttest flows run in integration/ShrincsVerifierIntegration.t.sol

  /// @dev verifierA attests EXACTLY (account, keyHash, hash) and denies all else
  function _mockAttestedOnly(address account, bytes32 keyHash, bytes32 hash) internal {
    vm.mockCall(
      address(verifierA), abi.encodeWithSelector(IERC7913TransientAttestation.wasVerified.selector), abi.encode(false)
    );
    vm.mockCall(
      address(verifierA),
      abi.encodeCall(IERC7913TransientAttestation.wasVerified, (account, keyHash, hash)),
      abi.encode(true)
    );
  }

  /// @dev the attested route's composite envelope hash — spec re-derivation
  function _envelopeHash(bytes32 walletBinding, bytes32 digest) internal view returns (bytes32) {
    return keccak256(abi.encode(omnibus.ENVELOPE_TYPEHASH(), walletBinding, digest));
  }

  bytes32 internal constant WALLET_BINDING = keccak256('some wallet binding');

  /// @dev attestation exists for exactly (ALICE, alice's key, envelope over
  /// alice's true commit digest)
  function _attestAliceSide() internal returns (CommitAuth memory) {
    bytes32 envelope = _envelopeHash(WALLET_BINDING, _aliceDigestFor(aliceSigner));
    _mockAttestedOnly(ALICE, keccak256(bytes('alice-key')), envelope);
    return AuthHelper.attestedAuth(aliceSigner, WALLET_BINDING);
  }

  function test_commit_attested_succeeds() public {
    _commitAliceSideAs(ALICE, _attestAliceSide());
    _assertLockState(lock, LockState.Free);
  }

  function test_commit_attested_revertsWhen_noAttestation() public {
    vm.mockCall(
      address(verifierA), abi.encodeWithSelector(IERC7913TransientAttestation.wasVerified.selector), abi.encode(false)
    );
    _expectCommitAliceSideRevert(
      ALICE,
      AuthHelper.attestedAuth(aliceSigner, WALLET_BINDING),
      abi.encodePacked(IOmnibus.AttestationNotFound.selector)
    );
  }

  function test_commit_attested_revertsWhen_senderIsNotAttestingAccount() public {
    // the attestation names ALICE as account: CHARLIE cannot spend it even with
    // the identical auth — on this route the permissionless-sender model
    // deliberately collapses to sender == attesting wallet
    CommitAuth memory auth = _attestAliceSide();
    _expectCommitAliceSideRevert(CHARLIE, auth, abi.encodePacked(IOmnibus.AttestationNotFound.selector));
  }

  function test_commit_attested_revertsWhen_payloadTampered() public {
    // attested for the true digest; tampering any commit parameter recomputes a
    // different digest, hence a different envelope, and the lookup misses
    CommitAuth memory auth = _attestAliceSide();
    Terms memory tampered = _aliceTermsOn(block.chainid, _makeNativeAssets(DEFAULT_AMOUNT + 1));
    vm.warp(AT_PROPOSER_COMMIT);
    vm.expectRevert(IOmnibus.AttestationNotFound.selector);
    vm.prank(ALICE);
    omnibus.commit{value: _totalNativeForCommit(tampered)}(lock, tampered, _bobTerms(), auth);
  }

  function test_commit_attested_revertsWhen_walletBindingTampered() public {
    _attestAliceSide();
    _expectCommitAliceSideRevert(
      ALICE,
      AuthHelper.attestedAuth(aliceSigner, keccak256('other binding')),
      abi.encodePacked(IOmnibus.AttestationNotFound.selector)
    );
  }

  function test_commit_attested_replay_revertsOnLockState() public {
    // the attestation stays queryable for the whole transaction (a PUBLIC
    // transient fact), but a second identical commit dies at the lock state
    // machine: posted[lock][partyDigest] is the route's nonce
    CommitAuth memory auth = _attestAliceSide();
    _commitAliceSideAs(ALICE, auth);
    _assertLockState(lock, LockState.Free);

    _expectCommitAliceSideRevert(ALICE, auth, abi.encodePacked(IOmnibus.TermsAlreadyPosted.selector));
  }

  function test_commit_attested_emitsSignerBlobForAttribution() public {
    // attribution is route-independent: the Commitment event carries the SAME
    // declared identity blob the envelope was bound to
    vm.recordLogs();
    _commitAliceSideAs(ALICE, _attestAliceSide());
    Vm.Log[] memory logs = vm.getRecordedLogs();
    _assertEventEmitted(logs, IOmnibus.Commitment.selector, lock);
  }

  // ============ Soft-guard semantics (a decision, not an accident) ============

  function test_commit_softGuard_thirdPartyPostsOtherSideWithOwnIdentityAndFunds() public {
    // Alice posts her side (keyed). A THIRD PARTY (Charlie) then posts BOB's side
    // with his OWN keyed identity and OWN funds: the contract never enforces WHICH
    // identity posts a side — economically a donation, since recipients are
    // terms-pinned and claim stays secret-gated
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();
    _commitFor(ALICE, lock, alice, bob);
    _assertLockState(lock, LockState.Free);

    uint256 charlieErc20Before = mockERC20.balanceOf(CHARLIE);
    uint256 bobErc20Before = mockERC20.balanceOf(BOB);
    uint256 omnibusErc20Before = mockERC20.balanceOf(address(omnibus));

    vm.warp(AT_TAKER_COMMIT);
    vm.prank(CHARLIE);
    omnibus.commit{value: 0}(lock, bob, alice, AuthHelper.keyedAuth(address(verifierA), CHARLIE));
    _assertLockState(lock, LockState.Committed);

    // the SENDER funded the leg; the side's named party paid nothing
    assertEq(charlieErc20Before - mockERC20.balanceOf(CHARLIE), DEFAULT_AMOUNT);
    assertEq(mockERC20.balanceOf(BOB), bobErc20Before);
    assertEq(mockERC20.balanceOf(address(omnibus)) - omnibusErc20Before, DEFAULT_AMOUNT);

    // the swap still settles to the TERMS-pinned recipients
    _warpToProposerClaim();
    vm.prank(ALICE);
    omnibus.claim(SECRET, alice, bob);
    _assertLockState(lock, LockState.Spent);
    assertEq(mockERC20.balanceOf(ALICE_RECIPIENT), DEFAULT_AMOUNT);
    assertEq(BOB_RECIPIENT.balance, DEFAULT_AMOUNT);
  }

  function test_commit_fundingModel_arbitrarySenderFundsKeyedIdentityLeg() public {
    // an arbitrary unrelated EOA sender submits a commit carrying Alice's KEYED
    // identity: succeeds, and the SENDER (not the identity) funds the leg + fee
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();
    address relayer = makeAddr('relayer');
    uint256 fee = 0.005 ether;
    omnibus.setCommitmentFee(fee);
    uint256 required = _totalNativeForCommit(alice) + fee;
    vm.deal(relayer, required);

    vm.warp(AT_PROPOSER_COMMIT);
    vm.prank(relayer);
    omnibus.commit{value: required}(lock, alice, bob, AuthHelper.auth(aliceSigner));

    _assertLockState(lock, LockState.Free);
    assertEq(relayer.balance, 0); // relayer paid everything
    assertEq(omnibus.accruedFees(), fee);
  }
}
