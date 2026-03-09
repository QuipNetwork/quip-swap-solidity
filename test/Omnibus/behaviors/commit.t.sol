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
    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Free));
  }

  function test_commit_sameChainSecondCommit() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    // First commit
    _commitFor(ALICE, lock, alice, bob);
    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Free));

    // Second commit transitions to Committed
    _commitFor(BOB, lock, bob, alice);
    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Committed));
  }

  function test_commit_crossChainCommit() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobCrossChainTerms();

    uint256 nativeAmount = _totalNativeForCommit(alice);
    vm.prank(ALICE);
    omnibus.commit{value: nativeAmount}(lock, alice, bob);

    // Cross-chain commit transitions directly to Committed
    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Committed));
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

  function test_commit_withERC20Collateral() public {
    Asset memory erc20Collateral = _makeERC20Asset(COLLATERAL_AMOUNT);
    Terms memory alice = _makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      _defaultDeadline(),
      erc20Collateral,
      _makeERC20Assets(DEFAULT_AMOUNT)
    );
    Terms memory bob = _bobTerms();

    uint256 aliceBalanceBefore = mockERC20.balanceOf(ALICE);
    uint256 omnibusBalanceBefore = mockERC20.balanceOf(address(omnibus));

    vm.prank(ALICE);
    omnibus.commit(lock, alice, bob);

    assertEq(aliceBalanceBefore - mockERC20.balanceOf(ALICE), COLLATERAL_AMOUNT + DEFAULT_AMOUNT);
    assertEq(mockERC20.balanceOf(address(omnibus)) - omnibusBalanceBefore, COLLATERAL_AMOUNT + DEFAULT_AMOUNT);
  }

  function test_commit_withERC721Collateral() public {
    // ALICE owns tokens 1, 2, 3 from setUp minting
    uint256 tokenId = 1;
    Asset memory erc721Collateral = _makeERC721Asset(tokenId);
    Terms memory alice = _makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      _defaultDeadline(),
      erc721Collateral,
      _makeERC20Assets(DEFAULT_AMOUNT)
    );
    Terms memory bob = _bobTerms();

    assertEq(mockERC721.ownerOf(tokenId), ALICE);

    vm.prank(ALICE);
    omnibus.commit(lock, alice, bob);

    assertEq(mockERC721.ownerOf(tokenId), address(omnibus));
  }

  function test_commit_withERC1155Collateral() public {
    Asset memory erc1155Collateral = _makeERC1155Asset(ERC1155_TOKEN_ID, 100);
    Terms memory alice = _makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      _defaultDeadline(),
      erc1155Collateral,
      _makeERC20Assets(DEFAULT_AMOUNT)
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
      _makeNativeAsset(COLLATERAL_AMOUNT),
      mixedAssets
    );
    Terms memory bob = _bobTerms();

    uint256 nativeAmount = COLLATERAL_AMOUNT + 1 ether;
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

    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Free));
  }

  // ============ State Transition Tests ============

  function test_commit_lockStateUnusedToFree() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Unused));
    _commitFor(ALICE, lock, alice, bob);
    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Free));
  }

  function test_commit_lockStateFreeToCommitted() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    _commitFor(ALICE, lock, alice, bob);
    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Free));

    _commitFor(BOB, lock, bob, alice);
    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Committed));
  }

  function test_commit_lockStateUnusedToCommitted() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobCrossChainTerms();

    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Unused));
    _commitFor(ALICE, lock, alice, bob);
    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Committed));
  }

  // ============ Revert Cases ============

  function test_commit_revertsWhen_partyChainIdMismatch() public {
    Terms memory alice = _makeTerms(
      OTHER_CHAIN_ID, // Wrong chain
      ALICE,
      ALICE_RECIPIENT,
      _defaultDeadline(),
      _makeNativeAsset(COLLATERAL_AMOUNT),
      _makeNativeAssets(DEFAULT_AMOUNT)
    );
    Terms memory bob = _bobTerms();

    vm.expectRevert(TermsLib.InvalidChainId.selector);
    vm.prank(ALICE);
    omnibus.commit{value: COLLATERAL_AMOUNT + DEFAULT_AMOUNT}(lock, alice, bob);
  }

  function test_commit_revertsWhen_partyDeadlineExpired() public {
    Terms memory alice = _makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      _expiredDeadline(),
      _makeNativeAsset(COLLATERAL_AMOUNT),
      _makeNativeAssets(DEFAULT_AMOUNT)
    );
    Terms memory bob = _bobTerms();

    vm.expectRevert(TermsLib.TermsExpired.selector);
    vm.prank(ALICE);
    omnibus.commit{value: COLLATERAL_AMOUNT + DEFAULT_AMOUNT}(lock, alice, bob);
  }

  function test_commit_revertsWhen_counterpartyDeadlineExpired() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _makeTerms(
      block.chainid,
      BOB,
      BOB_RECIPIENT,
      _expiredDeadline(),
      _makeNativeAsset(COLLATERAL_AMOUNT),
      _makeERC20Assets(DEFAULT_AMOUNT)
    );

    vm.expectRevert(TermsLib.TermsExpired.selector);
    vm.prank(ALICE);
    omnibus.commit{value: COLLATERAL_AMOUNT + DEFAULT_AMOUNT}(lock, alice, bob);
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
    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Committed));

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
    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Spent));

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
      _makeNativeAsset(COLLATERAL_AMOUNT),
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
      _makeNativeAsset(0), // Zero collateral amount
      _makeNativeAssets(DEFAULT_AMOUNT)
    );
    Terms memory bob = _bobTerms();

    vm.expectRevert(TermsLib.ZeroAmount.selector);
    vm.prank(ALICE);
    omnibus.commit{value: DEFAULT_AMOUNT}(lock, alice, bob);
  }

  function test_commit_revertsWhen_invalidNativeAsset() public {
    Asset memory invalidNative =
      Asset({assetType: AssetType.Native, target: address(1), id: 0, amount: COLLATERAL_AMOUNT});

    Terms memory alice = _makeTerms(
      block.chainid, ALICE, ALICE_RECIPIENT, _defaultDeadline(), invalidNative, _makeNativeAssets(DEFAULT_AMOUNT)
    );
    Terms memory bob = _bobTerms();

    vm.expectRevert(TermsLib.InvalidNativeAsset.selector);
    vm.prank(ALICE);
    omnibus.commit{value: COLLATERAL_AMOUNT + DEFAULT_AMOUNT}(lock, alice, bob);
  }

  function test_commit_revertsWhen_invalidERC20Asset() public {
    Asset memory invalidERC20 =
      Asset({assetType: AssetType.ERC20, target: address(0), id: 0, amount: COLLATERAL_AMOUNT}); // Zero target

    Terms memory alice = _makeTerms(
      block.chainid, ALICE, ALICE_RECIPIENT, _defaultDeadline(), invalidERC20, _makeNativeAssets(DEFAULT_AMOUNT)
    );
    Terms memory bob = _bobTerms();

    vm.expectRevert(TermsLib.InvalidERC20Asset.selector);
    vm.prank(ALICE);
    omnibus.commit{value: DEFAULT_AMOUNT}(lock, alice, bob);
  }

  function test_commit_revertsWhen_invalidERC721Asset() public {
    Asset memory invalidERC721 =
      Asset({assetType: AssetType.ERC721, target: address(mockERC721), id: 0, amount: 1}); // Zero id

    Terms memory alice = _makeTerms(
      block.chainid, ALICE, ALICE_RECIPIENT, _defaultDeadline(), invalidERC721, _makeNativeAssets(DEFAULT_AMOUNT)
    );
    Terms memory bob = _bobTerms();

    vm.expectRevert(TermsLib.InvalidERC721Asset.selector);
    vm.prank(ALICE);
    omnibus.commit{value: DEFAULT_AMOUNT}(lock, alice, bob);
  }

  function test_commit_revertsWhen_invalidERC1155Asset() public {
    Asset memory invalidERC1155 =
      Asset({assetType: AssetType.ERC1155, target: address(mockERC1155), id: 0, amount: 100}); // Zero id

    Terms memory alice = _makeTerms(
      block.chainid, ALICE, ALICE_RECIPIENT, _defaultDeadline(), invalidERC1155, _makeNativeAssets(DEFAULT_AMOUNT)
    );
    Terms memory bob = _bobTerms();

    vm.expectRevert(TermsLib.InvalidERC1155Asset.selector);
    vm.prank(ALICE);
    omnibus.commit{value: DEFAULT_AMOUNT}(lock, alice, bob);
  }

  // ============ Fuzz Tests ============

  function testFuzz_commit_acceptsValidNativeAmount(uint256 amount) public {
    amount = bound(amount, 1, 50 ether);

    Terms memory alice = _makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      _defaultDeadline(),
      _makeNativeAsset(amount),
      _makeERC20Assets(DEFAULT_AMOUNT)
    );
    Terms memory bob = _bobTerms();

    vm.prank(ALICE);
    omnibus.commit{value: amount}(lock, alice, bob);

    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Free));
  }

  function testFuzz_commit_acceptsValidDeadline(uint64 deadline) public {
    deadline = uint64(bound(deadline, block.timestamp + 1, type(uint64).max));

    Terms memory alice = _makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      deadline,
      _makeNativeAsset(COLLATERAL_AMOUNT),
      _makeNativeAssets(DEFAULT_AMOUNT)
    );
    Terms memory bob = _makeTerms(
      block.chainid,
      BOB,
      BOB_RECIPIENT,
      deadline,
      _makeNativeAsset(COLLATERAL_AMOUNT),
      _makeERC20Assets(DEFAULT_AMOUNT)
    );

    vm.prank(ALICE);
    omnibus.commit{value: COLLATERAL_AMOUNT + DEFAULT_AMOUNT}(lock, alice, bob);

    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Free));
  }
}
