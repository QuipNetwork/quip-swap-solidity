// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Asset, AssetType, Terms, TermsLib} from '../../../src/TermsLib.sol';
import {IOmnibus, LockState} from '../../../src/interfaces/IOmnibus.sol';
import {OmnibusTest} from '../Omnibus.t.sol';
import {AssetHelper} from '../../utils/AssetHelper.sol';
import {Vm} from 'forge-std-1.14.0/Vm.sol';

/// @title Omnibus commit Tests
/// @dev Tests for Omnibus.commit
contract Omnibus_commit is OmnibusTest {
  using AssetHelper for *;

  // ============ Success Cases ============

  function test_commit_sameChainFirstCommit() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

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

    // Second commit transitions to Committed
    _commitFor(BOB, lock, bob, alice);
    _assertLockState(lock, LockState.Committed);
  }

  function test_commit_crossChainCommit() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobCrossChainTerms();

    uint256 nativeAmount = _totalNativeForCommit(alice);
    vm.prank(ALICE);
    omnibus.commit{value: nativeAmount}(lock, alice, bob);

    // Cross-chain commit transitions directly to Committed
    _assertLockState(lock, LockState.Committed);
  }

  function test_commit_withNativeCollateral() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    uint256 omnibusBalanceBefore = address(omnibus).balance;
    uint256 nativeAmount = _totalNativeForCommit(alice);

    vm.prank(ALICE);
    omnibus.commit{value: nativeAmount}(lock, alice, bob);

    assertEq(address(omnibus).balance - omnibusBalanceBefore, nativeAmount);
  }

  function test_commit_withERC20Assets() public {
    Terms memory alice = _makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      _defaultDeadline(),
      _makeERC20Assets(DEFAULT_AMOUNT)
    );
    Terms memory bob = _bobTerms();

    uint256 aliceBalanceBefore = mockERC20.balanceOf(ALICE);
    uint256 omnibusBalanceBefore = mockERC20.balanceOf(address(omnibus));

    vm.prank(ALICE);
    omnibus.commit(lock, alice, bob);

    assertEq(aliceBalanceBefore - mockERC20.balanceOf(ALICE), DEFAULT_AMOUNT);
    assertEq(mockERC20.balanceOf(address(omnibus)) - omnibusBalanceBefore, DEFAULT_AMOUNT);
  }

  function test_commit_withERC721Assets() public {
    // ALICE owns tokens 1, 2, 3 from setUp minting
    uint256 tokenId = 1;
    Terms memory alice = _makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      _defaultDeadline(),
      _makeERC721Assets(tokenId)
    );
    Terms memory bob = _bobTerms();

    assertEq(mockERC721.ownerOf(tokenId), ALICE);

    vm.prank(ALICE);
    omnibus.commit(lock, alice, bob);

    assertEq(mockERC721.ownerOf(tokenId), address(omnibus));
  }

  function test_commit_withERC1155Assets() public {
    Terms memory alice = _makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      _defaultDeadline(),
      _makeERC1155Assets(ERC1155_TOKEN_ID, 100)
    );
    Terms memory bob = _bobTerms();

    uint256 aliceBalanceBefore = mockERC1155.balanceOf(ALICE, ERC1155_TOKEN_ID);
    uint256 omnibusBalanceBefore = mockERC1155.balanceOf(address(omnibus), ERC1155_TOKEN_ID);

    vm.prank(ALICE);
    omnibus.commit(lock, alice, bob);

    assertEq(aliceBalanceBefore - mockERC1155.balanceOf(ALICE, ERC1155_TOKEN_ID), 100);
    assertEq(mockERC1155.balanceOf(address(omnibus), ERC1155_TOKEN_ID) - omnibusBalanceBefore, 100);
  }

  function test_commit_withMixedAssets() public {
    Asset[] memory mixedAssets = new Asset[](3);
    mixedAssets[0] = _makeNativeAsset(1 ether);
    mixedAssets[1] = _makeERC20Asset(100 ether);
    mixedAssets[2] = _makeERC1155Asset(ERC1155_TOKEN_ID, 50);

    Terms memory alice = _makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      _defaultDeadline(),
      mixedAssets
    );
    Terms memory bob = _bobTerms();

    uint256 nativeAmount = 1 ether;
    uint256 omnibusNativeBefore = address(omnibus).balance;
    uint256 omnibusERC20Before = mockERC20.balanceOf(address(omnibus));
    uint256 omnibusERC1155Before = mockERC1155.balanceOf(address(omnibus), ERC1155_TOKEN_ID);

    vm.prank(ALICE);
    omnibus.commit{value: nativeAmount}(lock, alice, bob);

    assertEq(address(omnibus).balance - omnibusNativeBefore, nativeAmount);
    assertEq(mockERC20.balanceOf(address(omnibus)) - omnibusERC20Before, 100 ether);
    assertEq(mockERC1155.balanceOf(address(omnibus), ERC1155_TOKEN_ID) - omnibusERC1155Before, 50);
  }

  function test_commit_emitsCommitmentEvent() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

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

    // Verify terms hash is stored - just check it's non-zero
    assertNotEq(omnibus.termsHash(lock), bytes32(0));
  }

  function test_commit_anyoneCanCommit() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    // Charlie commits on behalf of Alice (must send native)
    uint256 nativeAmount = _totalNativeForCommit(alice);
    vm.deal(CHARLIE, nativeAmount);
    vm.prank(CHARLIE);
    omnibus.commit{value: nativeAmount}(lock, alice, bob);

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

  // ============ Revert Cases ============

  function test_commit_revertsWhen_partyChainIdMismatch() public {
    Terms memory alice = _makeTerms(
      OTHER_CHAIN_ID, // Wrong chain
      ALICE,
      ALICE_RECIPIENT,
      _defaultDeadline(),
      _makeNativeAssets(DEFAULT_AMOUNT)
    );
    Terms memory bob = _bobTerms();

    vm.expectRevert(TermsLib.ChainIdMismatch.selector);
    vm.prank(ALICE);
    omnibus.commit{value: DEFAULT_AMOUNT}(lock, alice, bob);
  }

  function test_commit_revertsWhen_partyDeadlineExpired() public {
    Terms memory alice = _makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      _expiredDeadline(),
      _makeNativeAssets(DEFAULT_AMOUNT)
    );
    Terms memory bob = _bobTerms();

    vm.expectRevert(TermsLib.TermsExpired.selector);
    vm.prank(ALICE);
    omnibus.commit{value: DEFAULT_AMOUNT}(lock, alice, bob);
  }

  function test_commit_revertsWhen_counterpartyDeadlineExpired() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _makeTerms(
      block.chainid,
      BOB,
      BOB_RECIPIENT,
      _expiredDeadline(),
      _makeERC20Assets(DEFAULT_AMOUNT)
    );

    uint256 nativeAmount = _totalNativeForCommit(alice);
    vm.expectRevert(TermsLib.TermsExpired.selector);
    vm.prank(ALICE);
    omnibus.commit{value: nativeAmount}(lock, alice, bob);
  }

  function test_commit_revertsWhen_incorrectNativeAmount() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    uint256 correctAmount = _totalNativeForCommit(alice);

    vm.expectRevert(IOmnibus.IncorrectNativeAmountReceived.selector);
    vm.prank(ALICE);
    omnibus.commit{value: correctAmount + 1}(lock, alice, bob);
  }

  function test_commit_revertsWhen_excessNativeAmount() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    uint256 correctAmount = _totalNativeForCommit(alice);

    vm.expectRevert(IOmnibus.IncorrectNativeAmountReceived.selector);
    vm.prank(ALICE);
    omnibus.commit{value: correctAmount + 1 ether}(lock, alice, bob);
  }

  function test_commit_revertsWhen_insufficientNativeAmount() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    uint256 correctAmount = _totalNativeForCommit(alice);

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

    // Try to commit again
    vm.expectRevert(IOmnibus.InvalidLockAdvancement.selector);
    _commitFor(ALICE, lock, alice, bob);
  }

  function test_commit_revertsWhen_lockAlreadySpent() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    // Commit both and execute
    _commitBothParties(lock, alice, bob);
    omnibus.execute(SECRET, alice, bob);
    _assertLockState(lock, LockState.Spent);

    // Try to commit again
    vm.expectRevert(IOmnibus.InvalidLockAdvancement.selector);
    _commitFor(ALICE, lock, alice, bob);
  }

  function test_commit_revertsWhen_termsMismatchOnSecondCommit() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    // First commit
    _commitFor(ALICE, lock, alice, bob);

    // Second commit with different terms
    Terms memory bobModified = _makeTerms(
      block.chainid,
      BOB,
      BOB_RECIPIENT,
      _defaultDeadline(),
      _makeERC20Assets(DEFAULT_AMOUNT + 1 ether) // Different amount
    );

    vm.expectRevert(IOmnibus.TermsMismatch.selector);
    _commitFor(BOB, lock, bobModified, alice);
  }

  function test_commit_revertsWhen_zeroAmountAsset() public {
    Terms memory alice = _makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      _defaultDeadline(),
      _makeNativeAssets(0) // Zero amount
    );
    Terms memory bob = _bobTerms();

    vm.expectRevert(TermsLib.ZeroAmount.selector);
    vm.prank(ALICE);
    omnibus.commit{value: 0}(lock, alice, bob);
  }

  function test_commit_revertsWhen_invalidNativeAsset() public {
    Asset[] memory assets = new Asset[](1);
    assets[0] = Asset({assetType: AssetType.Native, target: address(1), id: 0, amount: DEFAULT_AMOUNT});

    Terms memory alice = _makeTerms(
      block.chainid, ALICE, ALICE_RECIPIENT, _defaultDeadline(), assets
    );
    Terms memory bob = _bobTerms();

    vm.expectRevert(TermsLib.InvalidNativeAsset.selector);
    vm.prank(ALICE);
    omnibus.commit{value: DEFAULT_AMOUNT}(lock, alice, bob);
  }

  function test_commit_revertsWhen_invalidERC20Asset() public {
    Asset[] memory assets = new Asset[](1);
    assets[0] = Asset({assetType: AssetType.ERC20, target: address(0), id: 0, amount: DEFAULT_AMOUNT}); // Zero target

    Terms memory alice = _makeTerms(
      block.chainid, ALICE, ALICE_RECIPIENT, _defaultDeadline(), assets
    );
    Terms memory bob = _bobTerms();

    vm.expectRevert(TermsLib.InvalidERC20Asset.selector);
    vm.prank(ALICE);
    omnibus.commit{value: 0}(lock, alice, bob);
  }

  function test_commit_revertsWhen_invalidERC721Asset() public {
    Asset[] memory assets = new Asset[](1);
    assets[0] = Asset({assetType: AssetType.ERC721, target: address(mockERC721), id: 0, amount: 1}); // Zero id

    Terms memory alice = _makeTerms(
      block.chainid, ALICE, ALICE_RECIPIENT, _defaultDeadline(), assets
    );
    Terms memory bob = _bobTerms();

    vm.expectRevert(TermsLib.InvalidERC721Asset.selector);
    vm.prank(ALICE);
    omnibus.commit{value: 0}(lock, alice, bob);
  }

  function test_commit_revertsWhen_invalidERC1155Asset() public {
    Asset[] memory assets = new Asset[](1);
    assets[0] = Asset({assetType: AssetType.ERC1155, target: address(mockERC1155), id: 0, amount: 100}); // Zero id

    Terms memory alice = _makeTerms(
      block.chainid, ALICE, ALICE_RECIPIENT, _defaultDeadline(), assets
    );
    Terms memory bob = _bobTerms();

    vm.expectRevert(TermsLib.InvalidERC1155Asset.selector);
    vm.prank(ALICE);
    omnibus.commit{value: 0}(lock, alice, bob);
  }

  // ============ Fee Tests ============

  function test_commit_requiresFeeOnTopOfNative() public {
    uint256 fee = 0.005 ether;
    omnibus.setCommitmentFee(fee);

    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    uint256 nativeAmount = _totalNativeForCommit(alice);
    uint256 omnibusBalanceBefore = address(omnibus).balance;

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
    vm.expectRevert(IOmnibus.IncorrectNativeAmountReceived.selector);
    vm.prank(ALICE);
    omnibus.commit{value: nativeAmount + fee - 1}(lock, alice, bob);
  }

  function test_commit_worksWithZeroFee() public {
    // Fee defaults to 0, should work as before
    assertEq(omnibus.commitmentFee(), 0);

    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    uint256 nativeAmount = _totalNativeForCommit(alice);

    vm.prank(ALICE);
    omnibus.commit{value: nativeAmount}(lock, alice, bob);

    _assertLockState(lock, LockState.Free);
  }

  function test_commit_withMaxFee() public {
    uint256 maxFee = omnibus.MAX_FEE();
    omnibus.setCommitmentFee(maxFee);

    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    uint256 nativeAmount = _totalNativeForCommit(alice);

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
    uint256 aliceNative = _totalNativeForCommit(alice);
    vm.prank(ALICE);
    omnibus.commit{value: aliceNative + fee}(lock, alice, bob);
    assertEq(omnibus.accruedFees(), fee);

    // second commit accrues another
    uint256 bobNative = _totalNativeForCommit(bob);
    vm.prank(BOB);
    omnibus.commit{value: bobNative + fee}(lock, bob, alice);
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
    vm.prank(ALICE);
    omnibus.commit{value: aliceNative + fee}(lock, alice, bob);

    vm.prank(BOB);
    omnibus.commit{value: bobNative + fee}(lock, bob, alice);

    // Two fees should be accumulated
    assertEq(address(omnibus).balance - omnibusBalanceBefore, aliceNative + bobNative + (2 * fee));
  }

  // ============ Fuzz Tests ============

  function testFuzz_commit_acceptsValidNativeAmount(uint256 amount) public {
    amount = bound(amount, 1, 50 ether);

    Terms memory alice = _makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      _defaultDeadline(),
      _makeNativeAssets(amount)
    );
    Terms memory bob = _bobTerms();

    vm.prank(ALICE);
    omnibus.commit{value: amount}(lock, alice, bob);

    _assertLockState(lock, LockState.Free);
  }

  function testFuzz_commit_acceptsValidDeadline(uint64 deadline) public {
    deadline = uint64(bound(deadline, block.timestamp + 1, type(uint64).max));

    Terms memory alice = _makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      deadline,
      _makeNativeAssets(DEFAULT_AMOUNT)
    );
    Terms memory bob = _makeTerms(
      block.chainid,
      BOB,
      BOB_RECIPIENT,
      deadline,
      _makeERC20Assets(DEFAULT_AMOUNT)
    );

    vm.prank(ALICE);
    omnibus.commit{value: DEFAULT_AMOUNT}(lock, alice, bob);

    _assertLockState(lock, LockState.Free);
  }
}
