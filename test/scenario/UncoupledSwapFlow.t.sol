// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Vm} from 'forge-std-1.14.0/Vm.sol';

import {Quip} from '../../src/Quip.sol';
import {Asset, PartyTerms, QuipTerms, TermsLib} from '../../src/TermsLib.sol';
import {IQuip} from '../../src/interfaces/IQuip.sol';
import {PqOwnerState} from '../../src/interfaces/IQuipPortal.sol';
import {AssetHelper} from '../utils/AssetHelper.sol';
import {TermsHelper} from '../utils/TermsHelper.sol';
import {TestBase} from '../utils/TestBase.sol';
import {WOTSPlus} from '@quip.network/hashsigs-solidity-0.1.0/contracts/WOTSPlus.sol';

/// @title Uncoupled Swap Flow Scenario Tests
/// @dev End-to-end tests for the uncoupled swap flow: deploy -> couple -> claim
contract UncoupledSwapFlowTest is TestBase {
  using AssetHelper for *;
  using TermsHelper for *;

  function setUp() public override {
    super.setUp();
    _approveAll(ALICE);
    _approveAll(BOB);
  }

  // ============ Full Flow Tests ============

  function test_simulation_uncoupledSwapFullFlow_allAssetTypes() public {
    (WOTSPlus.WinternitzAddress memory pqOwner, bytes32 privateKey) = _uniqueKeyPair(1);
    bytes32 pqOwnerHash = _computePqOwnerHash(pqOwner);

    Asset[] memory partyAssets = AssetHelper.toArray(
      _makeNativeAssets(0.5 ether)[0],
      _makeERC20Assets(50 ether)[0],
      _makeERC721Assets(ERC721_TOKEN_ID)[0],
      _makeERC1155Assets(ERC1155_TOKEN_ID, 100)[0]
    );

    PartyTerms memory partyTerms = TermsHelper.makePartyTerms(ALICE, ALICE_RECIPIENT, _defaultExpiry(), partyAssets);

    PartyTerms memory counterpartyTerms =
      TermsHelper.makePartyTerms(BOB, BOB_RECIPIENT, _defaultExpiry(), _makeNativeAssets(1 ether));

    uint256 bobRecipientNativeBefore = BOB_RECIPIENT.balance;
    uint256 bobRecipientERC20Before = mockERC20.balanceOf(BOB_RECIPIENT);
    uint256 bobRecipientERC1155Before = mockERC1155.balanceOf(BOB_RECIPIENT, ERC1155_TOKEN_ID);

    // verify initial ownership
    assertEq(mockERC721.ownerOf(ERC721_TOKEN_ID), ALICE);

    // step 1: Deploy uncoupled
    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployUncoupledQuip{value: CREATION_FEE}(pqOwner, partyTerms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    address quipAddr = _findQuipProposedAddress(logs);
    Quip quip = Quip(payable(quipAddr));

    // verify uncoupled state - no assets transferred yet
    assertTrue(quip.INIT_UNCOUPLED());
    assertEq(address(quip).balance, 0);

    _approveAllForQuip(ALICE, address(quip));

    // step 2: Couple
    uint256 nativeToCommit = TermsLib.totalNativeAmount(partyAssets);
    vm.prank(ALICE);
    quip.coupleQuip{value: nativeToCommit}(partyTerms, counterpartyTerms);

    // verify all assets transferred to quip
    assertEq(address(quip).balance, 0.5 ether);
    assertEq(mockERC20.balanceOf(address(quip)), 50 ether);
    assertEq(mockERC721.ownerOf(ERC721_TOKEN_ID), address(quip));
    assertEq(mockERC1155.balanceOf(address(quip), ERC1155_TOKEN_ID), 100);

    // verify pqOwner state before claim
    assertEq(uint256(portal.pqOwnerState(pqOwnerHash)), uint256(PqOwnerState.Free), 'PqOwner should be Free before claim');

    // step 3: Claim
    QuipTerms memory coupledTerms = _coupleTerms(partyTerms, counterpartyTerms);
    WOTSPlus.WinternitzElements memory signature = _signTerms(privateKey, coupledTerms);
    quip.claim(signature, coupledTerms);

    // verify final pqOwner state
    assertEq(uint256(portal.pqOwnerState(pqOwnerHash)), uint256(PqOwnerState.Spent), 'PqOwner should be Spent after claim');

    // verify final quip state
    assertEq(quip.termsDigest(), _digestTermsCanonically(coupledTerms), 'Quip termsDigest should be coupled');
    assertEq(address(quip).balance, 0, 'Quip should be empty');
    assertEq(mockERC20.balanceOf(address(quip)), 0, 'Quip ERC20 should be empty');
    assertEq(mockERC1155.balanceOf(address(quip), ERC1155_TOKEN_ID), 0, 'Quip ERC1155 should be empty');

    // verify all assets transferred to Bob's recipient
    assertEq(BOB_RECIPIENT.balance - bobRecipientNativeBefore, 0.5 ether, 'Native transfer failed');
    assertEq(mockERC20.balanceOf(BOB_RECIPIENT) - bobRecipientERC20Before, 50 ether, 'ERC20 transfer failed');
    assertEq(mockERC721.ownerOf(ERC721_TOKEN_ID), BOB_RECIPIENT, 'ERC721 transfer failed');
    assertEq(
      mockERC1155.balanceOf(BOB_RECIPIENT, ERC1155_TOKEN_ID) - bobRecipientERC1155Before, 100, 'ERC1155 transfer failed'
    );
  }

  function test_simulation_uncoupledSwapFullFlow() public {
    // setup
    (WOTSPlus.WinternitzAddress memory pqOwner, bytes32 privateKey) = _uniqueKeyPair(2);
    bytes32 pqOwnerHash = _computePqOwnerHash(pqOwner);

    PartyTerms memory partyTerms =
      TermsHelper.makePartyTerms(ALICE, ALICE_RECIPIENT, _defaultExpiry(), _makeNativeAssets(1 ether));

    PartyTerms memory counterpartyTerms =
      TermsHelper.makePartyTerms(BOB, BOB_RECIPIENT, _defaultExpiry(), _makeNativeAssets(2 ether));

    uint256 bobRecipientBefore = BOB_RECIPIENT.balance;

    // step 1: Alice deploys uncoupled quip (proposal)
    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployUncoupledQuip{value: CREATION_FEE}(pqOwner, partyTerms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    address quipAddr = _findQuipProposedAddress(logs);
    Quip quip = Quip(payable(quipAddr));

    // verify initial state
    assertTrue(quip.INIT_UNCOUPLED());
    assertEq(address(quip).balance, 0); // no assets transferred yet

    // approve quip for Alice's asset transfers
    _approveAllForQuip(ALICE, address(quip));

    // step 2: Alice couples the quip with counterparty terms
    uint256 nativeToCommit = TermsLib.totalNativeAmount(partyTerms.assets);

    vm.prank(ALICE);
    quip.coupleQuip{value: nativeToCommit}(partyTerms, counterpartyTerms);

    // verify coupled state
    assertEq(address(quip).balance, nativeToCommit);

    // step 3: Anyone claims with the signature
    QuipTerms memory coupledTerms = _coupleTerms(partyTerms, counterpartyTerms);
    WOTSPlus.WinternitzElements memory signature = _signTerms(privateKey, coupledTerms);

    vm.prank(CHARLIE);
    quip.claim(signature, coupledTerms);

    // verify final pqOwner state
    assertEq(uint256(portal.pqOwnerState(pqOwnerHash)), uint256(PqOwnerState.Spent), 'PqOwner should be Spent');

    // verify final quip state
    assertEq(quip.termsDigest(), _digestTermsCanonically(coupledTerms), 'Quip termsDigest should be coupled');
    assertEq(address(quip).balance, 0, 'Quip should be empty');

    // verify assets transferred
    assertEq(BOB_RECIPIENT.balance - bobRecipientBefore, 1 ether);
  }

  function test_simulation_uncoupledSwapFullFlow_withERC20() public {
    (WOTSPlus.WinternitzAddress memory pqOwner, bytes32 privateKey) = _uniqueKeyPair(3);
    bytes32 pqOwnerHash = _computePqOwnerHash(pqOwner);

    PartyTerms memory partyTerms =
      TermsHelper.makePartyTerms(ALICE, ALICE_RECIPIENT, _defaultExpiry(), _makeERC20Assets(100 ether));

    PartyTerms memory counterpartyTerms =
      TermsHelper.makePartyTerms(BOB, BOB_RECIPIENT, _defaultExpiry(), _makeNativeAssets(1 ether));

    uint256 bobRecipientERC20Before = mockERC20.balanceOf(BOB_RECIPIENT);

    // step 1: Deploy uncoupled
    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployUncoupledQuip{value: CREATION_FEE}(pqOwner, partyTerms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    address quipAddr = _findQuipProposedAddress(logs);
    Quip quip = Quip(payable(quipAddr));

    _approveAllForQuip(ALICE, address(quip));

    // step 2: Couple
    vm.prank(ALICE);
    quip.coupleQuip(partyTerms, counterpartyTerms);

    // verify ERC20 transferred to quip
    assertEq(mockERC20.balanceOf(address(quip)), 100 ether);

    // step 3: Claim
    QuipTerms memory coupledTerms = _coupleTerms(partyTerms, counterpartyTerms);
    WOTSPlus.WinternitzElements memory signature = _signTerms(privateKey, coupledTerms);
    quip.claim(signature, coupledTerms);

    // verify final pqOwner state
    assertEq(uint256(portal.pqOwnerState(pqOwnerHash)), uint256(PqOwnerState.Spent), 'PqOwner should be Spent');

    // verify final quip state
    assertEq(mockERC20.balanceOf(address(quip)), 0, 'Quip ERC20 should be empty');

    // verify assets transferred
    assertEq(mockERC20.balanceOf(BOB_RECIPIENT) - bobRecipientERC20Before, 100 ether);
  }

  function test_simulation_uncoupledSwap_proposalCanBeAbandoned() public {
    (WOTSPlus.WinternitzAddress memory pqOwner,) = _uniqueKeyPair(4);
    bytes32 pqOwnerHash = _computePqOwnerHash(pqOwner);

    PartyTerms memory partyTerms =
      TermsHelper.makePartyTerms(ALICE, ALICE_RECIPIENT, _defaultExpiry(), _makeNativeAssets(1 ether));

    // deploy uncoupled
    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployUncoupledQuip{value: CREATION_FEE}(pqOwner, partyTerms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    address quipAddr = _findQuipProposedAddress(logs);
    Quip quip = Quip(payable(quipAddr));

    // verify quip exists but has no assets
    assertTrue(quip.INIT_UNCOUPLED());
    assertEq(address(quip).balance, 0);

    // Alice can simply not couple - no assets at risk
    // the pqOwner is Free (first deployment), so a counterparty could still deploy
    assertEq(uint256(portal.pqOwnerState(pqOwnerHash)), uint256(PqOwnerState.Free));
  }

  // ============ Coupling Restrictions ============

  function test_simulation_uncoupledSwap_onlySignatoryCanCouple() public {
    (WOTSPlus.WinternitzAddress memory pqOwner,) = _uniqueKeyPair(5);

    PartyTerms memory partyTerms =
      TermsHelper.makePartyTerms(ALICE, ALICE_RECIPIENT, _defaultExpiry(), _makeNativeAssets(1 ether));

    PartyTerms memory counterpartyTerms =
      TermsHelper.makePartyTerms(BOB, BOB_RECIPIENT, _defaultExpiry(), _makeNativeAssets(1 ether));

    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployUncoupledQuip{value: CREATION_FEE}(pqOwner, partyTerms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    address quipAddr = _findQuipProposedAddress(logs);
    Quip quip = Quip(payable(quipAddr));

    // Bob cannot couple (only Alice can)
    vm.prank(BOB);
    vm.expectRevert(IQuip.UnauthorizedCaller.selector);
    quip.coupleQuip{value: 1 ether}(partyTerms, counterpartyTerms);
  }
}
