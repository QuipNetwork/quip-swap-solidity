// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Vm} from 'forge-std-1.14.0/Vm.sol';

import {Quip} from '../../src/Quip.sol';
import {Asset, QuipTerms, TermsLib} from '../../src/TermsLib.sol';
import {LockState} from '../../src/interfaces/IQuipPortal.sol';
import {AssetHelper} from '../utils/AssetHelper.sol';
import {TermsHelper} from '../utils/TermsHelper.sol';
import {TestBase} from '../utils/TestBase.sol';

/// @title Reclaim Flow Scenario Tests
/// @dev End-to-end tests for the reclaim flow after expiry
contract ReclaimFlowTest is TestBase {
  using AssetHelper for *;
  using TermsHelper for *;

  function setUp() public override {
    super.setUp();
    _approveAll(ALICE);
  }

  // ============ Full Flow Tests ============

  function test_simulation_reclaimFullFlow_allAssetTypes() public {
    bytes memory key = abi.encodePacked('reclaim_all_assets_key');
    bytes32 lock = keccak256(key);

    Asset[] memory partyAssets = AssetHelper.toArray(
      _makeNativeAssets(0.5 ether)[0],
      _makeERC20Assets(50 ether)[0],
      _makeERC721Assets(ERC721_TOKEN_ID)[0],
      _makeERC1155Assets(ERC1155_TOKEN_ID, 100)[0]
    );

    QuipTerms memory terms = TermsHelper.makeQuipTerms(
      ALICE,
      ALICE_RECIPIENT,
      BOB,
      BOB_RECIPIENT,
      _defaultExpiry(),
      _defaultExpiry(),
      partyAssets,
      _makeNativeAssets(1 ether)
    );

    uint256 nativeRequired = CREATION_FEE + 0.5 ether;
    uint256 aliceRecipientNativeBefore = ALICE_RECIPIENT.balance;
    uint256 aliceRecipientERC20Before = mockERC20.balanceOf(ALICE_RECIPIENT);
    uint256 aliceRecipientERC1155Before = mockERC1155.balanceOf(ALICE_RECIPIENT, ERC1155_TOKEN_ID);

    // Verify initial ownership
    assertEq(mockERC721.ownerOf(ERC721_TOKEN_ID), ALICE);

    // Step 1: Deploy quip
    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployCoupledQuip{value: nativeRequired}(lock, terms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    address quipAddr = _findQuipCreatedAddress(logs);
    Quip quip = Quip(payable(quipAddr));

    // Verify all assets locked in quip
    assertEq(address(quip).balance, 0.5 ether);
    assertEq(mockERC20.balanceOf(address(quip)), 50 ether);
    assertEq(mockERC721.ownerOf(ERC721_TOKEN_ID), address(quip));
    assertEq(mockERC1155.balanceOf(address(quip), ERC1155_TOKEN_ID), 100);

    // Verify lock state before reclaim
    assertEq(uint256(portal.lockState(lock)), uint256(LockState.Free), 'Lock should be Free before reclaim');

    // Step 2: Time passes, swap is never claimed
    vm.warp(terms.partyExpiry);

    // Step 3: Reclaim
    vm.prank(CHARLIE);
    quip.reclaim(terms);

    // Verify final lock state
    assertEq(uint256(portal.lockState(lock)), uint256(LockState.Spent), 'Lock should be Spent after reclaim');

    // Verify final quip state
    assertEq(quip.lock(), lock, 'Quip lock unchanged');
    assertEq(quip.termsDigest(), TermsLib.digestTermsMemory(terms), 'Quip termsDigest unchanged');
    assertEq(address(quip).balance, 0, 'Quip should be empty');
    assertEq(mockERC20.balanceOf(address(quip)), 0, 'Quip ERC20 should be empty');
    assertEq(mockERC1155.balanceOf(address(quip), ERC1155_TOKEN_ID), 0, 'Quip ERC1155 should be empty');

    // Verify all assets returned to Alice's recipient
    assertEq(ALICE_RECIPIENT.balance - aliceRecipientNativeBefore, 0.5 ether, 'Native reclaim failed');
    assertEq(mockERC20.balanceOf(ALICE_RECIPIENT) - aliceRecipientERC20Before, 50 ether, 'ERC20 reclaim failed');
    assertEq(mockERC721.ownerOf(ERC721_TOKEN_ID), ALICE_RECIPIENT, 'ERC721 reclaim failed');
    assertEq(
      mockERC1155.balanceOf(ALICE_RECIPIENT, ERC1155_TOKEN_ID) - aliceRecipientERC1155Before,
      100,
      'ERC1155 reclaim failed'
    );
  }

  function test_simulation_reclaimFullFlow_nativeAssets() public {
    bytes memory key = abi.encodePacked('reclaim_native_key');
    bytes32 lock = keccak256(key);

    QuipTerms memory terms = TermsHelper.makeQuipTerms(
      ALICE,
      ALICE_RECIPIENT,
      BOB,
      BOB_RECIPIENT,
      _defaultExpiry(),
      _defaultExpiry(),
      _makeNativeAssets(1 ether),
      _makeNativeAssets(1 ether)
    );

    uint256 nativeRequired = CREATION_FEE + 1 ether;
    uint256 aliceRecipientBefore = ALICE_RECIPIENT.balance;

    // Step 1: Alice deploys quip
    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployCoupledQuip{value: nativeRequired}(lock, terms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    address quipAddr = _findQuipCreatedAddress(logs);
    Quip quip = Quip(payable(quipAddr));

    // Verify assets locked
    assertEq(address(quip).balance, 1 ether);

    // Step 2: Time passes, swap is never claimed
    vm.warp(terms.partyExpiry);

    // Step 3: Anyone can trigger reclaim after expiry
    vm.prank(CHARLIE);
    quip.reclaim(terms);

    // Verify final lock state
    assertEq(uint256(portal.lockState(lock)), uint256(LockState.Spent), 'Lock should be Spent');

    // Verify final quip state
    assertEq(quip.lock(), lock, 'Quip lock unchanged');
    assertEq(address(quip).balance, 0, 'Quip should be empty');

    // Verify assets returned to party recipient
    assertEq(ALICE_RECIPIENT.balance - aliceRecipientBefore, 1 ether);
  }

  function test_simulation_reclaimFullFlow_erc20Assets() public {
    bytes memory key = abi.encodePacked('reclaim_erc20_key');
    bytes32 lock = keccak256(key);

    QuipTerms memory terms = TermsHelper.makeQuipTerms(
      ALICE,
      ALICE_RECIPIENT,
      BOB,
      BOB_RECIPIENT,
      _defaultExpiry(),
      _defaultExpiry(),
      _makeERC20Assets(100 ether),
      _makeNativeAssets(1 ether)
    );

    uint256 aliceRecipientERC20Before = mockERC20.balanceOf(ALICE_RECIPIENT);

    // Deploy
    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployCoupledQuip{value: CREATION_FEE}(lock, terms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    address quipAddr = _findQuipCreatedAddress(logs);
    Quip quip = Quip(payable(quipAddr));

    // Verify ERC20 locked
    assertEq(mockERC20.balanceOf(address(quip)), 100 ether);

    // Wait for expiry and reclaim
    vm.warp(terms.partyExpiry);
    quip.reclaim(terms);

    // Verify final lock state
    assertEq(uint256(portal.lockState(lock)), uint256(LockState.Spent), 'Lock should be Spent');

    // Verify final quip state
    assertEq(quip.lock(), lock, 'Quip lock unchanged');
    assertEq(mockERC20.balanceOf(address(quip)), 0, 'Quip ERC20 should be empty');

    // Verify ERC20 returned
    assertEq(mockERC20.balanceOf(ALICE_RECIPIENT) - aliceRecipientERC20Before, 100 ether);
  }

  function test_simulation_reclaimFullFlow_mixedAssets() public {
    bytes memory key = abi.encodePacked('reclaim_mixed_key');
    bytes32 lock = keccak256(key);

    Asset[] memory partyAssets = AssetHelper.toArray(_makeNativeAssets(0.5 ether)[0], _makeERC20Assets(50 ether)[0]);

    QuipTerms memory terms = TermsHelper.makeQuipTerms(
      ALICE,
      ALICE_RECIPIENT,
      BOB,
      BOB_RECIPIENT,
      _defaultExpiry(),
      _defaultExpiry(),
      partyAssets,
      _makeNativeAssets(1 ether)
    );

    uint256 aliceRecipientNativeBefore = ALICE_RECIPIENT.balance;
    uint256 aliceRecipientERC20Before = mockERC20.balanceOf(ALICE_RECIPIENT);

    // Deploy
    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployCoupledQuip{value: CREATION_FEE + 0.5 ether}(lock, terms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    address quipAddr = _findQuipCreatedAddress(logs);
    Quip quip = Quip(payable(quipAddr));

    // Expire and reclaim
    vm.warp(terms.partyExpiry);
    quip.reclaim(terms);

    // Verify final lock state
    assertEq(uint256(portal.lockState(lock)), uint256(LockState.Spent), 'Lock should be Spent');

    // Verify final quip state
    assertEq(quip.lock(), lock, 'Quip lock unchanged');
    assertEq(address(quip).balance, 0, 'Quip should be empty');
    assertEq(mockERC20.balanceOf(address(quip)), 0, 'Quip ERC20 should be empty');

    // Verify all assets returned
    assertEq(ALICE_RECIPIENT.balance - aliceRecipientNativeBefore, 0.5 ether);
    assertEq(mockERC20.balanceOf(ALICE_RECIPIENT) - aliceRecipientERC20Before, 50 ether);
  }

  // ============ Race Condition Tests ============

  function test_simulation_claimBeforeReclaim_claimWins() public {
    bytes memory key = abi.encodePacked('race_claim_key');
    bytes32 lock = keccak256(key);

    QuipTerms memory terms = _makeDefaultQuipTerms();
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployCoupledQuip{value: nativeRequired}(lock, terms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    address quipAddr = _findQuipCreatedAddress(logs);
    Quip quip = Quip(payable(quipAddr));

    uint256 counterpartyRecipientBefore = terms.counterpartyRecipient.balance;

    // Claim before expiry
    quip.claim(key, terms);

    // Verify final lock state
    assertEq(uint256(portal.lockState(lock)), uint256(LockState.Spent), 'Lock should be Spent after claim');

    // Verify final quip state
    assertEq(quip.lock(), lock, 'Quip lock unchanged');
    assertEq(address(quip).balance, 0, 'Quip should be empty');

    // Verify counterparty got assets
    uint256 expectedAmount = TermsLib.totalNativeAmount(terms.partyAssets);
    assertEq(terms.counterpartyRecipient.balance - counterpartyRecipientBefore, expectedAmount);

    // Now try to reclaim after expiry - should fail
    vm.warp(terms.partyExpiry);
    vm.expectRevert();
    quip.reclaim(terms);
  }

  function test_simulation_reclaimBeforeClaim_reclaimWins() public {
    bytes memory key = abi.encodePacked('race_reclaim_key');
    bytes32 lock = keccak256(key);

    QuipTerms memory terms = _makeDefaultQuipTerms();
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployCoupledQuip{value: nativeRequired}(lock, terms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    address quipAddr = _findQuipCreatedAddress(logs);
    Quip quip = Quip(payable(quipAddr));

    uint256 partyRecipientBefore = terms.partyRecipient.balance;

    // Wait for expiry and reclaim
    vm.warp(terms.partyExpiry);
    quip.reclaim(terms);

    // Verify final lock state
    assertEq(uint256(portal.lockState(lock)), uint256(LockState.Spent), 'Lock should be Spent after reclaim');

    // Verify final quip state
    assertEq(quip.lock(), lock, 'Quip lock unchanged');
    assertEq(address(quip).balance, 0, 'Quip should be empty');

    // Verify party got assets back
    uint256 expectedAmount = TermsLib.totalNativeAmount(terms.partyAssets);
    assertEq(terms.partyRecipient.balance - partyRecipientBefore, expectedAmount);

    // Now try to claim - should fail
    vm.expectRevert();
    quip.claim(key, terms);
  }
}
