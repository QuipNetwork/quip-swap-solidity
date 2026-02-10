// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Vm} from 'forge-std-1.14.0/Vm.sol';

import {Quip} from '../../../src/Quip.sol';
import {Asset, AssetType, QuipTerms, TermsLib} from '../../../src/TermsLib.sol';
import {IQuipPortal} from '../../../src/interfaces/IQuipPortal.sol';
import {AssetHelper} from '../../utils/AssetHelper.sol';
import {TermsHelper} from '../../utils/TermsHelper.sol';
import {QuipPortalTest} from '../QuipPortal.t.sol';

/// @title QuipPortal deployCoupledQuip Tests
/// @dev Tests for QuipPortal.deployCoupledQuip
contract QuipPortal_deployCoupledQuip is QuipPortalTest {
  using AssetHelper for *;
  using TermsHelper for *;

  // ============ Success Cases ============

  function test_deployCoupledQuip_deploysAndInitializesQuip() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployCoupledQuip{value: nativeRequired}(defaultLock, terms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    address quipAddr = _findQuipCreatedAddress(logs);
    Quip quip = Quip(payable(quipAddr));

    // Verify lock is spent
    assertTrue(portal.isLockSpent(defaultLock));

    // Verify quip is initialized correctly
    assertEq(quip.lock(), defaultLock);
    assertEq(quip.termsDigest(), _digestQuipTerms(terms));
    assertFalse(quip.INIT_UNCOUPLED());
    assertEq(quip.PORTAL_FROM_BYTECODE(), address(portal));
  }

  function test_deployCoupledQuip_setsLockAsSpent() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

    assertFalse(portal.isLockSpent(defaultLock));

    vm.prank(ALICE);
    portal.deployCoupledQuip{value: nativeRequired}(defaultLock, terms);

    assertTrue(portal.isLockSpent(defaultLock));
  }

  function test_deployCoupledQuip_accumulatesFeesAndIncreasesPortalBalance() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);
    uint256 feesBefore = portal.accumulatedFees();
    uint256 portalBalanceBefore = address(portal).balance;

    vm.prank(ALICE);
    portal.deployCoupledQuip{value: nativeRequired}(defaultLock, terms);

    assertEq(portal.accumulatedFees() - feesBefore, CREATION_FEE);
    assertEq(address(portal).balance - portalBalanceBefore, CREATION_FEE);
  }

  function test_deployCoupledQuip_transfersAllAssetTypes() public {
    // Build party assets with all 4 asset types
    Asset[] memory partyAssets = new Asset[](4);
    partyAssets[0] = Asset({assetType: AssetType.Native, target: address(0), id: 0, amount: 1 ether});
    partyAssets[1] = Asset({assetType: AssetType.ERC20, target: address(mockERC20), id: 0, amount: 100 ether});
    partyAssets[2] = Asset({assetType: AssetType.ERC721, target: address(mockERC721), id: ERC721_TOKEN_ID, amount: 1});
    partyAssets[3] =
      Asset({assetType: AssetType.ERC1155, target: address(mockERC1155), id: ERC1155_TOKEN_ID, amount: 50});

    QuipTerms memory terms = TermsHelper.makeSimpleQuipTerms(
      ALICE, BOB, _defaultExpiry(), _defaultExpiry(), partyAssets, _makeNativeAssets(1 ether)
    );

    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(partyAssets);

    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployCoupledQuip{value: nativeRequired}(defaultLock, terms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    address quip = _findQuipCreatedAddress(logs);

    // Verify all assets transferred to quip
    assertEq(quip.balance, 1 ether);
    assertEq(mockERC20.balanceOf(quip), 100 ether);
    assertEq(mockERC721.ownerOf(ERC721_TOKEN_ID), quip);
    assertEq(mockERC1155.balanceOf(quip, ERC1155_TOKEN_ID), 50);
  }

  function test_deployCoupledQuip_emitsQuipCreatedEvent() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployCoupledQuip{value: nativeRequired}(defaultLock, terms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    bool found = false;
    for (uint256 i = 0; i < logs.length; i++) {
      if (logs[i].topics[0] == IQuipPortal.QuipCreated.selector) {
        found = true;
        break;
      }
    }
    assertTrue(found, 'QuipCreated event not found');
  }

  function test_deployCoupledQuip_initializesQuipWithCorrectLock() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployCoupledQuip{value: nativeRequired}(defaultLock, terms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    address quipAddr = _findQuipCreatedAddress(logs);
    Quip quip = Quip(payable(quipAddr));

    assertEq(quip.lock(), defaultLock);
  }

  function test_deployCoupledQuip_initializesQuipWithCorrectTermsDigest() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployCoupledQuip{value: nativeRequired}(defaultLock, terms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    address quipAddr = _findQuipCreatedAddress(logs);
    Quip quip = Quip(payable(quipAddr));

    bytes32 expectedDigest = _digestQuipTerms(terms);
    assertEq(quip.termsDigest(), expectedDigest);
  }

  // ============ Revert Cases ============

  function test_deployCoupledQuip_revertsWhen_lockIsZero() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

    vm.prank(ALICE);
    vm.expectRevert(IQuipPortal.EmptyLock.selector);
    portal.deployCoupledQuip{value: nativeRequired}(bytes32(0), terms);
  }

  function test_deployCoupledQuip_revertsWhen_lockIsSpent() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

    // First deployment
    vm.prank(ALICE);
    portal.deployCoupledQuip{value: nativeRequired}(defaultLock, terms);

    // Second deployment with same lock should fail
    vm.prank(ALICE);
    vm.expectRevert(IQuipPortal.LockSpent.selector);
    portal.deployCoupledQuip{value: nativeRequired}(defaultLock, terms);
  }

  function test_deployCoupledQuip_revertsWhen_partyIsZero() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    terms.party = address(0);
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

    vm.prank(ALICE);
    vm.expectRevert(IQuipPortal.EmptyParty.selector);
    portal.deployCoupledQuip{value: nativeRequired}(defaultLock, terms);
  }

  function test_deployCoupledQuip_revertsWhen_counterpartyIsZero() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    terms.counterparty = address(0);
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

    vm.prank(ALICE);
    vm.expectRevert(IQuipPortal.EmptyParty.selector);
    portal.deployCoupledQuip{value: nativeRequired}(defaultLock, terms);
  }

  function test_deployCoupledQuip_revertsWhen_partyRecipientIsZero() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    terms.partyRecipient = address(0);
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

    vm.prank(ALICE);
    vm.expectRevert(IQuipPortal.EmptyRecipient.selector);
    portal.deployCoupledQuip{value: nativeRequired}(defaultLock, terms);
  }

  function test_deployCoupledQuip_revertsWhen_counterpartyRecipientIsZero() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    terms.counterpartyRecipient = address(0);
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

    vm.prank(ALICE);
    vm.expectRevert(IQuipPortal.EmptyRecipient.selector);
    portal.deployCoupledQuip{value: nativeRequired}(defaultLock, terms);
  }

  function test_deployCoupledQuip_revertsWhen_partyExpiryInPast() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    terms.partyExpiry = _expiredTimestamp();
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

    vm.prank(ALICE);
    vm.expectRevert(IQuipPortal.InvalidExpiry.selector);
    portal.deployCoupledQuip{value: nativeRequired}(defaultLock, terms);
  }

  function test_deployCoupledQuip_revertsWhen_counterpartyExpiryInPast() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    terms.counterpartyExpiry = _expiredTimestamp();
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

    vm.prank(ALICE);
    vm.expectRevert(IQuipPortal.InvalidExpiry.selector);
    portal.deployCoupledQuip{value: nativeRequired}(defaultLock, terms);
  }

  function test_deployCoupledQuip_revertsWhen_partyAssetsEmpty() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    terms.partyAssets = new Asset[](0);
    uint256 nativeRequired = CREATION_FEE;

    vm.prank(ALICE);
    vm.expectRevert(IQuipPortal.EmptyAssets.selector);
    portal.deployCoupledQuip{value: nativeRequired}(defaultLock, terms);
  }

  function test_deployCoupledQuip_revertsWhen_counterpartyAssetsEmpty() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    terms.counterpartyAssets = new Asset[](0);
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

    vm.prank(ALICE);
    vm.expectRevert(IQuipPortal.EmptyAssets.selector);
    portal.deployCoupledQuip{value: nativeRequired}(defaultLock, terms);
  }

  function test_deployCoupledQuip_revertsWhen_incorrectNativeAmount() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

    vm.prank(ALICE);
    vm.expectRevert(IQuipPortal.IncorrectNativeAmount.selector);
    portal.deployCoupledQuip{value: nativeRequired - 1}(defaultLock, terms);
  }

  function test_deployCoupledQuip_revertsWhen_assetAmountZero() public {
    Asset[] memory partyAssets = _makeNativeAssets(0);
    partyAssets[0].amount = 0;
    QuipTerms memory terms = TermsHelper.makeSimpleQuipTerms(
      ALICE, BOB, _defaultExpiry(), _defaultExpiry(), partyAssets, _makeNativeAssets(1 ether)
    );

    vm.prank(ALICE);
    vm.expectRevert(TermsLib.ZeroAmount.selector);
    portal.deployCoupledQuip{value: CREATION_FEE}(defaultLock, terms);
  }

  // ============ Fuzz Tests ============

  function testFuzz_deployCoupledQuip_withVariousNativeAmounts(uint256 amount) public {
    amount = bound(amount, 1, 10 ether);

    Asset[] memory partyAssets = _makeNativeAssets(amount);
    QuipTerms memory terms = TermsHelper.makeSimpleQuipTerms(
      ALICE, BOB, _defaultExpiry(), _defaultExpiry(), partyAssets, _makeNativeAssets(1 ether)
    );

    uint256 nativeRequired = CREATION_FEE + amount;

    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployCoupledQuip{value: nativeRequired}(defaultLock, terms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    address quip = _findQuipCreatedAddress(logs);

    assertEq(quip.balance, amount);
  }

  function testFuzz_deployCoupledQuip_withVariousLocks(bytes32 lock) public {
    vm.assume(lock != bytes32(0));

    QuipTerms memory terms = _makeDefaultQuipTerms();
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

    vm.prank(ALICE);
    portal.deployCoupledQuip{value: nativeRequired}(lock, terms);

    assertTrue(portal.isLockSpent(lock));
  }
}
