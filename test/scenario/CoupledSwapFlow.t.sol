// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Vm} from 'forge-std-1.14.0/Vm.sol';

import {Quip} from '../../src/Quip.sol';
import {Asset, QuipTerms, TermsLib} from '../../src/TermsLib.sol';
import {IQuip} from '../../src/interfaces/IQuip.sol';
import {IQuipPortal} from '../../src/interfaces/IQuipPortal.sol';
import {AssetHelper} from '../utils/AssetHelper.sol';
import {TermsHelper} from '../utils/TermsHelper.sol';
import {TestBase} from '../utils/TestBase.sol';

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
    bytes memory key = abi.encodePacked('all_assets_key');
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
    uint256 bobRecipientNativeBefore = BOB_RECIPIENT.balance;
    uint256 bobRecipientERC20Before = mockERC20.balanceOf(BOB_RECIPIENT);
    uint256 bobRecipientERC1155Before = mockERC1155.balanceOf(BOB_RECIPIENT, ERC1155_TOKEN_ID);

    // Verify initial ownership
    assertEq(mockERC721.ownerOf(ERC721_TOKEN_ID), ALICE);

    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployCoupledQuip{value: nativeRequired}(lock, terms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    address quipAddr = _findQuipCreatedAddress(logs);
    Quip quip = Quip(payable(quipAddr));

    // Verify all assets transferred to quip
    assertEq(address(quip).balance, 0.5 ether);
    assertEq(mockERC20.balanceOf(address(quip)), 50 ether);
    assertEq(mockERC721.ownerOf(ERC721_TOKEN_ID), address(quip));
    assertEq(mockERC1155.balanceOf(address(quip), ERC1155_TOKEN_ID), 100);

    // Claim
    quip.claim(key, terms);

    // Verify all assets transferred to Bob's recipient
    assertEq(BOB_RECIPIENT.balance - bobRecipientNativeBefore, 0.5 ether, 'Native transfer failed');
    assertEq(mockERC20.balanceOf(BOB_RECIPIENT) - bobRecipientERC20Before, 50 ether, 'ERC20 transfer failed');
    assertEq(mockERC721.ownerOf(ERC721_TOKEN_ID), BOB_RECIPIENT, 'ERC721 transfer failed');
    assertEq(
      mockERC1155.balanceOf(BOB_RECIPIENT, ERC1155_TOKEN_ID) - bobRecipientERC1155Before, 100, 'ERC1155 transfer failed'
    );
  }

  function test_simulation_coupledSwapFullFlow_nativeForNative() public {
    // Setup: Alice offers 1 ETH, Bob should receive it
    bytes memory key = abi.encodePacked('native_swap_key');
    bytes32 lock = keccak256(key);

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

    // Step 1: Alice deploys coupled quip
    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployCoupledQuip{value: nativeRequired}(lock, terms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    address quipAddr = _findQuipCreatedAddress(logs);
    Quip quip = Quip(payable(quipAddr));

    // Verify quip state
    assertEq(quip.lock(), lock);
    assertEq(address(quip).balance, 1 ether);

    // Step 2: Anyone claims with the key (permissionless)
    vm.prank(CHARLIE);
    quip.claim(key, terms);

    // Verify final state
    assertEq(address(quip).balance, 0);
    assertEq(BOB_RECIPIENT.balance - bobRecipientBefore, 1 ether);
  }

  function test_simulation_coupledSwapFullFlow_erc20ForNative() public {
    bytes memory key = abi.encodePacked('erc20_native_key');
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

    uint256 bobRecipientERC20Before = mockERC20.balanceOf(BOB_RECIPIENT);

    // Alice deploys coupled quip (only creation fee needed)
    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployCoupledQuip{value: CREATION_FEE}(lock, terms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    address quipAddr = _findQuipCreatedAddress(logs);
    Quip quip = Quip(payable(quipAddr));

    // Verify ERC20 transferred to quip
    assertEq(mockERC20.balanceOf(address(quip)), 100 ether);

    // Claim
    quip.claim(key, terms);

    // Verify ERC20 transferred to Bob's recipient
    assertEq(mockERC20.balanceOf(BOB_RECIPIENT) - bobRecipientERC20Before, 100 ether);
  }

  function test_simulation_coupledSwapFullFlow_mixedAssets() public {
    bytes memory key = abi.encodePacked('mixed_assets_key');
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

    uint256 nativeRequired = CREATION_FEE + 0.5 ether;
    uint256 bobRecipientNativeBefore = BOB_RECIPIENT.balance;
    uint256 bobRecipientERC20Before = mockERC20.balanceOf(BOB_RECIPIENT);

    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployCoupledQuip{value: nativeRequired}(lock, terms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    address quipAddr = _findQuipCreatedAddress(logs);
    Quip quip = Quip(payable(quipAddr));

    // Claim
    quip.claim(key, terms);

    // Verify both assets transferred
    assertEq(BOB_RECIPIENT.balance - bobRecipientNativeBefore, 0.5 ether);
    assertEq(mockERC20.balanceOf(BOB_RECIPIENT) - bobRecipientERC20Before, 50 ether);
  }

  function test_simulation_coupledSwapFullFlow_multipleSwaps() public {
    // Simulate multiple independent swaps
    for (uint256 i = 0; i < 3; i++) {
      bytes memory key = abi.encodePacked('multi_swap_', i);
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

      vm.prank(ALICE);
      vm.recordLogs();
      portal.deployCoupledQuip{value: CREATION_FEE + 1 ether}(lock, terms);

      Vm.Log[] memory logs = vm.getRecordedLogs();
      address quipAddr = _findQuipCreatedAddress(logs);
      Quip quip = Quip(payable(quipAddr));

      quip.claim(key, terms);
      assertEq(address(quip).balance, 0);
    }
  }

  // ============ Fee Accumulation Tests ============

  function test_simulation_coupledSwap_accumulatesFees() public {
    uint256 swapCount = 5;
    uint256 initialFees = portal.accumulatedFees();

    for (uint256 i = 0; i < swapCount; i++) {
      bytes memory key = abi.encodePacked('fee_test_', i);
      bytes32 lock = keccak256(key);

      QuipTerms memory terms = _makeDefaultQuipTerms();
      uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

      vm.prank(ALICE);
      portal.deployCoupledQuip{value: nativeRequired}(lock, terms);
    }

    assertEq(portal.accumulatedFees() - initialFees, CREATION_FEE * swapCount);
  }
}
