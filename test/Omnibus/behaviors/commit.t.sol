// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Asset, AssetType, Terms, TermsLib} from '../../../src/TermsLib.sol';
import {IOmnibus, LockState} from '../../../src/interfaces/IOmnibus.sol';
import {FeeOnTransferERC20Mock} from '../../mocks/FeeOnTransferERC20Mock.sol';
import {AssetHelper} from '../../utils/AssetHelper.sol';
import {OmnibusTest} from '../Omnibus.t.sol';
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
    omnibus.commit{value: nativeAmount}(lock, alice, bob);

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
    omnibus.commit{value: nativeAmount}(lock, alice, bob);

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

  function test_commit_revertsWhen_callerNotQuipWallet() public {
    // only post-quantum secure wallets (deployed by the quip factory) may commit
    address nonQuipWallet = makeAddr('nonQuipWallet');
    vm.deal(nonQuipWallet, DEFAULT_AMOUNT);

    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    vm.warp(AT_PROPOSER_COMMIT);
    vm.expectRevert(IOmnibus.CallerNotQuipWallet.selector);
    vm.prank(nonQuipWallet);
    omnibus.commit{value: DEFAULT_AMOUNT}(lock, alice, bob);
  }

  function test_commit_revertsWhen_walletUnregistered() public {
    // a wallet whose registration is removed (vaultId back to zero) can no longer commit
    quipFactory.unregisterWallet(ALICE);

    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    vm.warp(AT_PROPOSER_COMMIT);
    vm.expectRevert(IOmnibus.CallerNotQuipWallet.selector);
    vm.prank(ALICE);
    omnibus.commit{value: DEFAULT_AMOUNT}(lock, alice, bob);
  }

  // ============ Revert Cases ============

  function test_commit_pullsFromCaller_notNamedParty() public {
    // commit pulls assets from msg.sender, NOT from the side's named reclaimRecipient.
    // A quip-wallet caller (Charlie) naming a victim (Alice) on an ERC20 side cannot
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
    omnibus.commit{value: DEFAULT_AMOUNT}(lock, alice, bob);
  }

  function test_commit_revertsWhen_proposerCommitWindowElapsed() public {
    // freshness is enforced by the commit window, not validateTerms: committing at/after the
    // proposer's commitment deadline falls outside [0, commitmentDeadline) and reverts
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    vm.warp(ALICE_COMMIT_DEADLINE); // upper bound is exclusive
    vm.expectRevert(TermsLib.WindowViolated.selector);
    vm.prank(ALICE);
    omnibus.commit{value: _totalNativeForCommit(alice)}(lock, alice, bob);
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
    omnibus.commit{value: 0}(lock, bob, alice);
  }

  function test_commit_takerSucceedsAtExactProposerDeadline() public {
    // the taker window's lower bound (the proposer's commitmentDeadline) is inclusive
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitFor(ALICE, lock, alice, bob);

    vm.warp(ALICE_COMMIT_DEADLINE);
    vm.prank(BOB);
    omnibus.commit{value: 0}(lock, bob, alice);

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
    omnibus.commit{value: 0}(lock, bob, alice);
  }

  function test_commit_revertsWhen_incorrectNativeAmount() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    uint256 correctAmount = _totalNativeForCommit(alice);

    vm.warp(AT_PROPOSER_COMMIT);
    vm.expectRevert(IOmnibus.IncorrectNativeAmountReceived.selector);
    vm.prank(ALICE);
    omnibus.commit{value: correctAmount + 1}(lock, alice, bob);
  }

  function test_commit_revertsWhen_excessNativeAmount() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    uint256 correctAmount = _totalNativeForCommit(alice);

    vm.warp(AT_PROPOSER_COMMIT);
    vm.expectRevert(IOmnibus.IncorrectNativeAmountReceived.selector);
    vm.prank(ALICE);
    omnibus.commit{value: correctAmount + 1 ether}(lock, alice, bob);
  }

  function test_commit_revertsWhen_insufficientNativeAmount() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    uint256 correctAmount = _totalNativeForCommit(alice);

    vm.warp(AT_PROPOSER_COMMIT);
    vm.expectRevert(IOmnibus.IncorrectNativeAmountReceived.selector);
    vm.prank(ALICE);
    omnibus.commit{value: correctAmount - 1}(lock, alice, bob);
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
    omnibus.commit{value: _totalNativeForCommit(alice)}(lock, alice, bob);
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
    omnibus.commit{value: _totalNativeForCommit(alice)}(lock, alice, bob);
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
    omnibus.commit{value: _totalNativeForCommit(bobModified)}(lock, bobModified, alice);
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
    omnibus.commit{value: _totalNativeForCommit(alice)}(lock, alice, bob);
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
    omnibus.commit(lock, alice, bob);

    // the revert rolled back the pull; Alice keeps her tokens
    assertEq(feeToken.balanceOf(ALICE), aliceBefore);
  }

  function test_commit_revertsWhen_zeroAmountAsset() public {
    Terms memory alice = _proposerSide(ALICE, ALICE_RECIPIENT, _makeNativeAssets(0));
    Terms memory bob = _bobTerms();

    vm.warp(AT_PROPOSER_COMMIT);
    vm.expectRevert(TermsLib.ZeroAmount.selector);
    vm.prank(ALICE);
    omnibus.commit{value: 0}(lock, alice, bob);
  }

  function test_commit_revertsWhen_invalidNativeAsset() public {
    Asset[] memory assets = new Asset[](1);
    assets[0] = Asset({assetType: AssetType.Native, target: address(1), id: 0, amount: DEFAULT_AMOUNT});

    Terms memory alice = _proposerSide(ALICE, ALICE_RECIPIENT, assets);
    Terms memory bob = _bobTerms();

    vm.warp(AT_PROPOSER_COMMIT);
    vm.expectRevert(TermsLib.InvalidNativeAsset.selector);
    vm.prank(ALICE);
    omnibus.commit{value: DEFAULT_AMOUNT}(lock, alice, bob);
  }

  function test_commit_revertsWhen_invalidERC20Asset() public {
    Asset[] memory assets = new Asset[](1);
    assets[0] = Asset({assetType: AssetType.ERC20, target: address(0), id: 0, amount: DEFAULT_AMOUNT}); // Zero target

    Terms memory alice = _proposerSide(ALICE, ALICE_RECIPIENT, assets);
    Terms memory bob = _bobTerms();

    vm.warp(AT_PROPOSER_COMMIT);
    vm.expectRevert(TermsLib.InvalidERC20Asset.selector);
    vm.prank(ALICE);
    omnibus.commit{value: 0}(lock, alice, bob);
  }

  function test_commit_revertsWhen_invalidERC721Asset() public {
    Asset[] memory assets = new Asset[](1);
    assets[0] = Asset({assetType: AssetType.ERC721, target: address(0), id: 1, amount: 1}); // Zero target

    Terms memory alice = _proposerSide(ALICE, ALICE_RECIPIENT, assets);
    Terms memory bob = _bobTerms();

    vm.warp(AT_PROPOSER_COMMIT);
    vm.expectRevert(TermsLib.InvalidERC721Asset.selector);
    vm.prank(ALICE);
    omnibus.commit{value: 0}(lock, alice, bob);
  }

  function test_commit_revertsWhen_invalidERC1155Asset() public {
    Asset[] memory assets = new Asset[](1);
    assets[0] = Asset({assetType: AssetType.ERC1155, target: address(0), id: 1, amount: 100}); // Zero target

    Terms memory alice = _proposerSide(ALICE, ALICE_RECIPIENT, assets);
    Terms memory bob = _bobTerms();

    vm.warp(AT_PROPOSER_COMMIT);
    vm.expectRevert(TermsLib.InvalidERC1155Asset.selector);
    vm.prank(ALICE);
    omnibus.commit{value: 0}(lock, alice, bob);
  }

  function test_commit_revertsWhen_invalidCounterpartyTerms() public {
    // commit validates BOTH sides; a malformed counterparty (zero-amount asset) reverts even
    // though the party side is valid
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTermsOn(block.chainid, _makeERC20Assets(0));

    vm.warp(AT_PROPOSER_COMMIT);
    vm.expectRevert(TermsLib.ZeroAmount.selector);
    vm.prank(ALICE);
    omnibus.commit{value: _totalNativeForCommit(alice)}(lock, alice, bob);
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
    omnibus.commit{value: nativeAmount + fee}(lock, alice, bob);

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
    omnibus.commit{value: nativeAmount}(lock, alice, bob);
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
    omnibus.commit{value: nativeAmount + fee - 1}(lock, alice, bob);
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
    omnibus.commit{value: nativeAmount + maxFee}(lock, alice, bob);

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
    omnibus.commit{value: amount}(lock, alice, bob);

    _assertLockState(lock, LockState.Free);
  }

  function testFuzz_commit_acceptsAnyTimeInProposerWindow(uint256 t) public {
    // the proposer may commit at any instant in [0, ALICE_COMMIT_DEADLINE)
    t = bound(t, 0, ALICE_COMMIT_DEADLINE - 1);

    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    vm.warp(t);
    vm.prank(ALICE);
    omnibus.commit{value: _totalNativeForCommit(alice)}(lock, alice, bob);

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
    omnibus.commit{value: 0}(lock, bob, alice);

    _assertLockState(lock, LockState.Committed);
  }
}
