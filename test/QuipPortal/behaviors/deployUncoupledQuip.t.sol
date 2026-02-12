// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Vm} from 'forge-std-1.14.0/Vm.sol';

import {Quip} from '../../../src/Quip.sol';
import {Asset, PartyTerms} from '../../../src/TermsLib.sol';
import {IQuipPortal, LockState} from '../../../src/interfaces/IQuipPortal.sol';
import {AssetHelper} from '../../utils/AssetHelper.sol';
import {TermsHelper} from '../../utils/TermsHelper.sol';
import {QuipPortalTest} from '../QuipPortal.t.sol';

/// @title QuipPortal deployUncoupledQuip Tests
/// @dev Tests for QuipPortal.deployUncoupledQuip
contract QuipPortal_deployUncoupledQuip is QuipPortalTest {
  using AssetHelper for *;
  using TermsHelper for *;

  // ============ Success Cases ============

  function test_deployUncoupledQuip_deploysAndInitializesQuip() public {
    PartyTerms memory terms = _makeDefaultPartyTerms();

    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployUncoupledQuip{value: CREATION_FEE}(defaultLock, terms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    address quipAddr = _findQuipProposedAddress(logs);
    Quip quip = Quip(payable(quipAddr));

    // Verify lock state transitioned to Free (first deployment)
    assertEq(uint256(portal.lockState(defaultLock)), uint256(LockState.Free));

    // Verify quip is initialized correctly
    assertEq(quip.lock(), defaultLock);
    assertEq(quip.termsDigest(), _digestPartyTerms(terms));
    assertTrue(quip.INIT_UNCOUPLED());
    assertEq(quip.PORTAL_FROM_BYTECODE(), address(portal));

    // Verify no assets transferred (uncoupled quip has no balance)
    assertEq(quipAddr.balance, 0);
  }

  function test_deployUncoupledQuip_transitionsLockFromUnusedToFree() public {
    PartyTerms memory terms = _makeDefaultPartyTerms();

    assertEq(uint256(portal.lockState(defaultLock)), uint256(LockState.Unused));

    vm.prank(ALICE);
    portal.deployUncoupledQuip{value: CREATION_FEE}(defaultLock, terms);

    assertEq(uint256(portal.lockState(defaultLock)), uint256(LockState.Free));
  }

  function test_deployUncoupledQuip_transitionsLockFromFreeToSpent_sameChainSwap() public {
    PartyTerms memory terms = _makeDefaultPartyTerms();

    // Alice deploys first quip (Unused → Free)
    vm.prank(ALICE);
    portal.deployUncoupledQuip{value: CREATION_FEE}(defaultLock, terms);
    assertEq(uint256(portal.lockState(defaultLock)), uint256(LockState.Free));

    // Bob deploys second quip with same lock (Free → Spent) - enables same-chain swaps
    vm.prank(BOB);
    portal.deployUncoupledQuip{value: CREATION_FEE}(defaultLock, terms);
    assertEq(uint256(portal.lockState(defaultLock)), uint256(LockState.Spent));
  }

  function test_deployUncoupledQuip_accumulatesFeesAndIncreasesPortalBalance() public {
    PartyTerms memory terms = _makeDefaultPartyTerms();
    uint256 feesBefore = portal.accumulatedFees();
    uint256 portalBalanceBefore = address(portal).balance;

    vm.prank(ALICE);
    portal.deployUncoupledQuip{value: CREATION_FEE}(defaultLock, terms);

    assertEq(portal.accumulatedFees() - feesBefore, CREATION_FEE);
    assertEq(address(portal).balance - portalBalanceBefore, CREATION_FEE);
  }

  function test_deployUncoupledQuip_emitsQuipProposedEvent() public {
    PartyTerms memory terms = _makeDefaultPartyTerms();

    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployUncoupledQuip{value: CREATION_FEE}(defaultLock, terms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    bool found = false;
    for (uint256 i = 0; i < logs.length; i++) {
      if (logs[i].topics[0] == IQuipPortal.QuipProposed.selector) {
        found = true;
        break;
      }
    }
    assertTrue(found, 'QuipProposed event not found');
  }

  function test_deployUncoupledQuip_initializesQuipWithCorrectLock() public {
    PartyTerms memory terms = _makeDefaultPartyTerms();

    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployUncoupledQuip{value: CREATION_FEE}(defaultLock, terms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    address quipAddr = _findQuipProposedAddress(logs);
    Quip quip = Quip(payable(quipAddr));

    assertEq(quip.lock(), defaultLock);
  }

  function test_deployUncoupledQuip_initializesQuipWithCorrectTermsDigest() public {
    PartyTerms memory terms = _makeDefaultPartyTerms();

    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployUncoupledQuip{value: CREATION_FEE}(defaultLock, terms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    address quipAddr = _findQuipProposedAddress(logs);
    Quip quip = Quip(payable(quipAddr));

    bytes32 expectedDigest = _digestPartyTerms(terms);
    assertEq(quip.termsDigest(), expectedDigest);
  }

  function test_deployUncoupledQuip_setsInitUncoupledTrue() public {
    PartyTerms memory terms = _makeDefaultPartyTerms();

    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployUncoupledQuip{value: CREATION_FEE}(defaultLock, terms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    address quipAddr = _findQuipProposedAddress(logs);
    Quip quip = Quip(payable(quipAddr));

    assertTrue(quip.INIT_UNCOUPLED());
  }

  // ============ Revert Cases ============

  function test_deployUncoupledQuip_revertsWhen_lockIsZero() public {
    PartyTerms memory terms = _makeDefaultPartyTerms();

    vm.prank(ALICE);
    vm.expectRevert(IQuipPortal.EmptyLock.selector);
    portal.deployUncoupledQuip{value: CREATION_FEE}(bytes32(0), terms);
  }

  function test_deployUncoupledQuip_revertsWhen_lockIsSpent() public {
    PartyTerms memory terms = _makeDefaultPartyTerms();

    // First deployment by Alice (Unused → Free)
    vm.prank(ALICE);
    portal.deployUncoupledQuip{value: CREATION_FEE}(defaultLock, terms);

    // Second deployment by Bob (Free → Spent)
    vm.prank(BOB);
    portal.deployUncoupledQuip{value: CREATION_FEE}(defaultLock, terms);

    // Third deployment by Charlie should fail - lock is fully spent
    vm.prank(CHARLIE);
    vm.expectRevert(IQuipPortal.LockSpent.selector);
    portal.deployUncoupledQuip{value: CREATION_FEE}(defaultLock, terms);
  }

  function test_deployUncoupledQuip_revertsWhen_sameDeployerUsesLockTwice() public {
    PartyTerms memory terms = _makeDefaultPartyTerms();

    // First deployment by Alice
    vm.prank(ALICE);
    portal.deployUncoupledQuip{value: CREATION_FEE}(defaultLock, terms);

    // Second deployment by Alice with same lock fails (deterministic address collision)
    vm.prank(ALICE);
    vm.expectRevert(); // LibClone.DeploymentFailed or similar
    portal.deployUncoupledQuip{value: CREATION_FEE}(defaultLock, terms);
  }

  function test_deployUncoupledQuip_revertsWhen_signatoryIsZero() public {
    PartyTerms memory terms = _makeDefaultPartyTerms();
    terms.signatory = address(0);

    vm.prank(ALICE);
    vm.expectRevert(IQuipPortal.EmptyParty.selector);
    portal.deployUncoupledQuip{value: CREATION_FEE}(defaultLock, terms);
  }

  function test_deployUncoupledQuip_revertsWhen_recipientIsZero() public {
    PartyTerms memory terms = _makeDefaultPartyTerms();
    terms.recipient = address(0);

    vm.prank(ALICE);
    vm.expectRevert(IQuipPortal.EmptyRecipient.selector);
    portal.deployUncoupledQuip{value: CREATION_FEE}(defaultLock, terms);
  }

  function test_deployUncoupledQuip_revertsWhen_expiryInPast() public {
    PartyTerms memory terms = _makeDefaultPartyTerms();
    terms.expiry = _expiredTimestamp();

    vm.prank(ALICE);
    vm.expectRevert(IQuipPortal.InvalidExpiry.selector);
    portal.deployUncoupledQuip{value: CREATION_FEE}(defaultLock, terms);
  }

  function test_deployUncoupledQuip_revertsWhen_assetsEmpty() public {
    PartyTerms memory terms = _makeDefaultPartyTerms();
    terms.assets = new Asset[](0);

    vm.prank(ALICE);
    vm.expectRevert(IQuipPortal.EmptyAssets.selector);
    portal.deployUncoupledQuip{value: CREATION_FEE}(defaultLock, terms);
  }

  function test_deployUncoupledQuip_revertsWhen_incorrectNativeAmount() public {
    PartyTerms memory terms = _makeDefaultPartyTerms();

    vm.prank(ALICE);
    vm.expectRevert(IQuipPortal.IncorrectNativeAmount.selector);
    portal.deployUncoupledQuip{value: CREATION_FEE - 1}(defaultLock, terms);
  }

  function test_deployUncoupledQuip_revertsWhen_excessNativeAmount() public {
    PartyTerms memory terms = _makeDefaultPartyTerms();

    vm.prank(ALICE);
    vm.expectRevert(IQuipPortal.IncorrectNativeAmount.selector);
    portal.deployUncoupledQuip{value: CREATION_FEE + 1}(defaultLock, terms);
  }

  // ============ Fuzz Tests ============

  function testFuzz_deployUncoupledQuip_withVariousLocks(bytes32 lock) public {
    vm.assume(lock != bytes32(0));

    PartyTerms memory terms = _makeDefaultPartyTerms();

    vm.prank(ALICE);
    portal.deployUncoupledQuip{value: CREATION_FEE}(lock, terms);

    assertEq(uint256(portal.lockState(lock)), uint256(LockState.Free));
  }
}
