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

/// @title Coupled Swap Flow Scenario Tests
/// @dev End-to-end tests for the coupled swap flow: deploy -> claim
contract CoupledSwapFlowTest is TestBase {
  using AssetHelper for *;
  using TermsHelper for *;

  function setUp() public override {
    super.setUp();
    _approveAll(ALICE);
    _approveAll(BOB);
  }

  // ============ Full Flow Tests ============

  function test_simulation_coupledSwapFullFlow_allAssetTypes() public {
    (WOTSPlus.WinternitzAddress memory pqOwner, bytes32 privateKey) = _uniqueKeyPair(1);
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
    uint256 bobRecipientNativeBefore = BOB_RECIPIENT.balance;
    uint256 bobRecipientERC20Before = mockERC20.balanceOf(BOB_RECIPIENT);
    uint256 bobRecipientERC1155Before = mockERC1155.balanceOf(BOB_RECIPIENT, ERC1155_TOKEN_ID);

    // verify initial ownership
    assertEq(mockERC721.ownerOf(ERC721_TOKEN_ID), ALICE);

    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployCoupledQuip{value: nativeRequired}(pqOwner, terms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    address quipAddr = _findQuipCreatedAddress(logs);
    Quip quip = Quip(payable(quipAddr));

    // verify all assets transferred to quip
    assertEq(address(quip).balance, 0.5 ether);
    assertEq(mockERC20.balanceOf(address(quip)), 50 ether);
    assertEq(mockERC721.ownerOf(ERC721_TOKEN_ID), address(quip));
    assertEq(mockERC1155.balanceOf(address(quip), ERC1155_TOKEN_ID), 100);

    // verify pqOwner state before claim
    assertEq(uint256(portal.pqOwnerState(pqOwnerHash)), uint256(PqOwnerState.Free), 'PqOwner should be Free before claim');

    // claim
    WOTSPlus.WinternitzElements memory signature = _signTerms(privateKey, terms);
    quip.claim(signature, terms);

    // verify final pqOwner state
    assertEq(uint256(portal.pqOwnerState(pqOwnerHash)), uint256(PqOwnerState.Spent), 'PqOwner should be Spent after claim');

    // verify final quip state
    assertEq(quip.pqOwnerHash(), pqOwnerHash, 'Quip pqOwnerHash unchanged');
    assertEq(quip.termsDigest(), _digestTermsCanonically(terms), 'Quip termsDigest unchanged');
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

  function test_simulation_coupledSwapFullFlow_nativeForNative() public {
    // setup: Alice offers 1 ETH, Bob should receive it
    (WOTSPlus.WinternitzAddress memory pqOwner, bytes32 privateKey) = _uniqueKeyPair(2);
    bytes32 pqOwnerHash = _computePqOwnerHash(pqOwner);

    QuipTerms memory terms = TermsHelper.makeQuipTerms(
      ALICE,
      ALICE_RECIPIENT,
      BOB,
      BOB_RECIPIENT,
      _defaultExpiry(),
      _defaultExpiry(),
      _makeNativeAssets(1 ether),
      _makeNativeAssets(2 ether)
    );

    uint256 nativeRequired = CREATION_FEE + 1 ether;
    uint256 bobRecipientBefore = BOB_RECIPIENT.balance;

    // step 1: Alice deploys coupled quip
    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployCoupledQuip{value: nativeRequired}(pqOwner, terms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    address quipAddr = _findQuipCreatedAddress(logs);
    Quip quip = Quip(payable(quipAddr));

    // verify quip state
    (bytes32 publicSeed, bytes32 publicKeyHash) = quip.pqOwner();
    assertEq(publicSeed, pqOwner.publicSeed);
    assertEq(publicKeyHash, pqOwner.publicKeyHash);
    assertEq(address(quip).balance, 1 ether);

    // step 2: Anyone claims with the signature (permissionless)
    WOTSPlus.WinternitzElements memory signature = _signTerms(privateKey, terms);
    vm.prank(CHARLIE);
    quip.claim(signature, terms);

    // verify final pqOwner state
    assertEq(uint256(portal.pqOwnerState(pqOwnerHash)), uint256(PqOwnerState.Spent), 'PqOwner should be Spent');

    // verify final quip state
    assertEq(quip.termsDigest(), _digestTermsCanonically(terms), 'Quip termsDigest unchanged');
    assertEq(address(quip).balance, 0, 'Quip should be empty');

    // verify assets transferred
    assertEq(BOB_RECIPIENT.balance - bobRecipientBefore, 1 ether);
  }

  function test_simulation_coupledSwapFullFlow_erc20ForNative() public {
    (WOTSPlus.WinternitzAddress memory pqOwner, bytes32 privateKey) = _uniqueKeyPair(3);
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

    uint256 bobRecipientERC20Before = mockERC20.balanceOf(BOB_RECIPIENT);

    // Alice deploys coupled quip (only creation fee needed)
    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployCoupledQuip{value: CREATION_FEE}(pqOwner, terms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    address quipAddr = _findQuipCreatedAddress(logs);
    Quip quip = Quip(payable(quipAddr));

    // verify ERC20 transferred to quip
    assertEq(mockERC20.balanceOf(address(quip)), 100 ether);

    // claim
    WOTSPlus.WinternitzElements memory signature = _signTerms(privateKey, terms);
    quip.claim(signature, terms);

    // verify final pqOwner state
    assertEq(uint256(portal.pqOwnerState(pqOwnerHash)), uint256(PqOwnerState.Spent), 'PqOwner should be Spent');

    // verify final quip state
    assertEq(address(quip).balance, 0, 'Quip should be empty');
    assertEq(mockERC20.balanceOf(address(quip)), 0, 'Quip ERC20 should be empty');

    // verify ERC20 transferred to Bob's recipient
    assertEq(mockERC20.balanceOf(BOB_RECIPIENT) - bobRecipientERC20Before, 100 ether);
  }

  function test_simulation_coupledSwapFullFlow_mixedAssets() public {
    (WOTSPlus.WinternitzAddress memory pqOwner, bytes32 privateKey) = _uniqueKeyPair(4);
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

    uint256 nativeRequired = CREATION_FEE + 0.5 ether;
    uint256 bobRecipientNativeBefore = BOB_RECIPIENT.balance;
    uint256 bobRecipientERC20Before = mockERC20.balanceOf(BOB_RECIPIENT);

    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployCoupledQuip{value: nativeRequired}(pqOwner, terms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    address quipAddr = _findQuipCreatedAddress(logs);
    Quip quip = Quip(payable(quipAddr));

    // claim
    WOTSPlus.WinternitzElements memory signature = _signTerms(privateKey, terms);
    quip.claim(signature, terms);

    // verify final pqOwner state
    assertEq(uint256(portal.pqOwnerState(pqOwnerHash)), uint256(PqOwnerState.Spent), 'PqOwner should be Spent');

    // verify final quip state
    assertEq(address(quip).balance, 0, 'Quip should be empty');
    assertEq(mockERC20.balanceOf(address(quip)), 0, 'Quip ERC20 should be empty');

    // verify both assets transferred
    assertEq(BOB_RECIPIENT.balance - bobRecipientNativeBefore, 0.5 ether);
    assertEq(mockERC20.balanceOf(BOB_RECIPIENT) - bobRecipientERC20Before, 50 ether);
  }

  function test_simulation_coupledSwapFullFlow_multipleSwaps() public {
    // simulate multiple independent swaps
    for (uint256 i = 0; i < 3; i++) {
      (WOTSPlus.WinternitzAddress memory pqOwner, bytes32 privateKey) = _uniqueKeyPair(100 + i);
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

      vm.prank(ALICE);
      vm.recordLogs();
      portal.deployCoupledQuip{value: CREATION_FEE + 1 ether}(pqOwner, terms);

      Vm.Log[] memory logs = vm.getRecordedLogs();
      address quipAddr = _findQuipCreatedAddress(logs);
      Quip quip = Quip(payable(quipAddr));

      WOTSPlus.WinternitzElements memory signature = _signTerms(privateKey, terms);
      quip.claim(signature, terms);

      // verify final state for each swap
      assertEq(uint256(portal.pqOwnerState(pqOwnerHash)), uint256(PqOwnerState.Spent), 'PqOwner should be Spent');
      assertEq(address(quip).balance, 0, 'Quip should be empty');
    }
  }

  // ============ Fee Accumulation Tests ============

  function test_simulation_coupledSwap_accumulatesFees() public {
    uint256 swapCount = 5;
    uint256 initialFees = portal.accumulatedFees();

    for (uint256 i = 0; i < swapCount; i++) {
      (WOTSPlus.WinternitzAddress memory pqOwner,) = _uniqueKeyPair(200 + i);

      QuipTerms memory terms = _makeDefaultQuipTerms();
      uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

      vm.prank(ALICE);
      portal.deployCoupledQuip{value: nativeRequired}(pqOwner, terms);
    }

    assertEq(portal.accumulatedFees() - initialFees, CREATION_FEE * swapCount);
  }
}
