// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Vm} from 'forge-std-1.14.0/Vm.sol';

import {Quip} from '../../src/Quip.sol';
import {Asset, QuipTerms, TermsLib} from '../../src/TermsLib.sol';
import {PqOwnerState} from '../../src/interfaces/IQuipPortal.sol';
import {AssetHelper} from '../utils/AssetHelper.sol';
import {TermsHelper} from '../utils/TermsHelper.sol';
import {TestBase} from '../utils/TestBase.sol';
import {WOTSPlus} from '@quip.network/hashsigs-solidity-0.1.0/contracts/WOTSPlus.sol';

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
    (WOTSPlus.WinternitzAddress memory pqOwner,) = _uniqueKeyPair(1);
    bytes32 pqOwnerHash = _computePqOwnerHash(pqOwner);

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

    // verify initial ownership
    assertEq(mockERC721.ownerOf(ERC721_TOKEN_ID), ALICE);

    // step 1: Deploy quip
    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployCoupledQuip{value: nativeRequired}(pqOwner, terms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    address quipAddr = _findQuipCreatedAddress(logs);
    Quip quip = Quip(payable(quipAddr));

    // verify all assets locked in quip
    assertEq(address(quip).balance, 0.5 ether);
    assertEq(mockERC20.balanceOf(address(quip)), 50 ether);
    assertEq(mockERC721.ownerOf(ERC721_TOKEN_ID), address(quip));
    assertEq(mockERC1155.balanceOf(address(quip), ERC1155_TOKEN_ID), 100);

    // verify pqOwner state before reclaim
    assertEq(uint256(portal.pqOwnerState(pqOwnerHash)), uint256(PqOwnerState.Free), 'PqOwner should be Free before reclaim');

    // step 2: Time passes, swap is never claimed
    vm.warp(terms.partyExpiry);

    // step 3: Reclaim
    vm.prank(CHARLIE);
    quip.reclaim(terms);

    // verify final pqOwner state
    assertEq(uint256(portal.pqOwnerState(pqOwnerHash)), uint256(PqOwnerState.Spent), 'PqOwner should be Spent after reclaim');

    // verify final quip state
    assertEq(quip.termsDigest(), _digestTermsCanonically(terms), 'Quip termsDigest unchanged');
    assertEq(address(quip).balance, 0, 'Quip should be empty');
    assertEq(mockERC20.balanceOf(address(quip)), 0, 'Quip ERC20 should be empty');
    assertEq(mockERC1155.balanceOf(address(quip), ERC1155_TOKEN_ID), 0, 'Quip ERC1155 should be empty');

    // verify all assets returned to Alice's recipient
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
    (WOTSPlus.WinternitzAddress memory pqOwner,) = _uniqueKeyPair(2);
    bytes32 pqOwnerHash = _computePqOwnerHash(pqOwner);

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

    // step 1: Alice deploys quip
    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployCoupledQuip{value: nativeRequired}(pqOwner, terms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    address quipAddr = _findQuipCreatedAddress(logs);
    Quip quip = Quip(payable(quipAddr));

    // verify assets locked
    assertEq(address(quip).balance, 1 ether);

    // step 2: Time passes, swap is never claimed
    vm.warp(terms.partyExpiry);

    // step 3: Anyone can trigger reclaim after expiry
    vm.prank(CHARLIE);
    quip.reclaim(terms);

    // verify final pqOwner state
    assertEq(uint256(portal.pqOwnerState(pqOwnerHash)), uint256(PqOwnerState.Spent), 'PqOwner should be Spent');

    // verify final quip state
    assertEq(address(quip).balance, 0, 'Quip should be empty');

    // verify assets returned to party recipient
    assertEq(ALICE_RECIPIENT.balance - aliceRecipientBefore, 1 ether);
  }

  function test_simulation_reclaimFullFlow_erc20Assets() public {
    (WOTSPlus.WinternitzAddress memory pqOwner,) = _uniqueKeyPair(3);
    bytes32 pqOwnerHash = _computePqOwnerHash(pqOwner);

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

    // deploy
    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployCoupledQuip{value: CREATION_FEE}(pqOwner, terms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    address quipAddr = _findQuipCreatedAddress(logs);
    Quip quip = Quip(payable(quipAddr));

    // verify ERC20 locked
    assertEq(mockERC20.balanceOf(address(quip)), 100 ether);

    // wait for expiry and reclaim
    vm.warp(terms.partyExpiry);
    quip.reclaim(terms);

    // verify final pqOwner state
    assertEq(uint256(portal.pqOwnerState(pqOwnerHash)), uint256(PqOwnerState.Spent), 'PqOwner should be Spent');

    // verify final quip state
    assertEq(mockERC20.balanceOf(address(quip)), 0, 'Quip ERC20 should be empty');

    // verify ERC20 returned
    assertEq(mockERC20.balanceOf(ALICE_RECIPIENT) - aliceRecipientERC20Before, 100 ether);
  }

  function test_simulation_reclaimFullFlow_mixedAssets() public {
    (WOTSPlus.WinternitzAddress memory pqOwner,) = _uniqueKeyPair(4);
    bytes32 pqOwnerHash = _computePqOwnerHash(pqOwner);

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

    // deploy
    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployCoupledQuip{value: CREATION_FEE + 0.5 ether}(pqOwner, terms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    address quipAddr = _findQuipCreatedAddress(logs);
    Quip quip = Quip(payable(quipAddr));

    // expire and reclaim
    vm.warp(terms.partyExpiry);
    quip.reclaim(terms);

    // verify final pqOwner state
    assertEq(uint256(portal.pqOwnerState(pqOwnerHash)), uint256(PqOwnerState.Spent), 'PqOwner should be Spent');

    // verify final quip state
    assertEq(address(quip).balance, 0, 'Quip should be empty');
    assertEq(mockERC20.balanceOf(address(quip)), 0, 'Quip ERC20 should be empty');

    // verify all assets returned
    assertEq(ALICE_RECIPIENT.balance - aliceRecipientNativeBefore, 0.5 ether);
    assertEq(mockERC20.balanceOf(ALICE_RECIPIENT) - aliceRecipientERC20Before, 50 ether);
  }

  // ============ Race Condition Tests ============

  function test_simulation_claimBeforeReclaim_claimWins() public {
    (WOTSPlus.WinternitzAddress memory pqOwner, bytes32 privateKey) = _uniqueKeyPair(5);
    bytes32 pqOwnerHash = _computePqOwnerHash(pqOwner);

    QuipTerms memory terms = _makeDefaultQuipTerms();
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployCoupledQuip{value: nativeRequired}(pqOwner, terms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    address quipAddr = _findQuipCreatedAddress(logs);
    Quip quip = Quip(payable(quipAddr));

    uint256 counterpartyRecipientBefore = terms.counterpartyRecipient.balance;

    // claim before expiry
    WOTSPlus.WinternitzElements memory signature = _signTerms(privateKey, terms);
    quip.claim(signature, terms);

    // verify final pqOwner state
    assertEq(uint256(portal.pqOwnerState(pqOwnerHash)), uint256(PqOwnerState.Spent), 'PqOwner should be Spent after claim');

    // verify final quip state
    assertEq(address(quip).balance, 0, 'Quip should be empty');

    // verify counterparty got assets
    uint256 expectedAmount = TermsLib.totalNativeAmount(terms.partyAssets);
    assertEq(terms.counterpartyRecipient.balance - counterpartyRecipientBefore, expectedAmount);

    // now try to reclaim after expiry - should fail
    vm.warp(terms.partyExpiry);
    vm.expectRevert();
    quip.reclaim(terms);
  }

  function test_simulation_reclaimBeforeClaim_reclaimWins() public {
    (WOTSPlus.WinternitzAddress memory pqOwner, bytes32 privateKey) = _uniqueKeyPair(6);
    bytes32 pqOwnerHash = _computePqOwnerHash(pqOwner);

    QuipTerms memory terms = _makeDefaultQuipTerms();
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployCoupledQuip{value: nativeRequired}(pqOwner, terms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    address quipAddr = _findQuipCreatedAddress(logs);
    Quip quip = Quip(payable(quipAddr));

    uint256 partyRecipientBefore = terms.partyRecipient.balance;

    // wait for expiry and reclaim
    vm.warp(terms.partyExpiry);
    quip.reclaim(terms);

    // verify final pqOwner state
    assertEq(uint256(portal.pqOwnerState(pqOwnerHash)), uint256(PqOwnerState.Spent), 'PqOwner should be Spent after reclaim');

    // verify final quip state
    assertEq(address(quip).balance, 0, 'Quip should be empty');

    // verify party got assets back
    uint256 expectedAmount = TermsLib.totalNativeAmount(terms.partyAssets);
    assertEq(terms.partyRecipient.balance - partyRecipientBefore, expectedAmount);

    // now try to claim - should fail
    WOTSPlus.WinternitzElements memory signature = _signTerms(privateKey, terms);
    vm.expectRevert();
    quip.claim(signature, terms);
  }
}
