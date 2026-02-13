// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Vm} from 'forge-std-1.14.0/Vm.sol';

import {Quip} from '../../../src/Quip.sol';
import {Asset, PartyTerms} from '../../../src/TermsLib.sol';
import {IQuipPortal, PqOwnerState} from '../../../src/interfaces/IQuipPortal.sol';
import {AssetHelper} from '../../utils/AssetHelper.sol';
import {TermsHelper} from '../../utils/TermsHelper.sol';
import {QuipPortalTest} from '../QuipPortal.t.sol';
import {WOTSPlus} from '@quip.network/hashsigs-solidity-0.1.0/contracts/WOTSPlus.sol';

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
    portal.deployUncoupledQuip{value: CREATION_FEE}(defaultPqOwner, terms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    address quipAddr = _findQuipProposedAddress(logs);
    Quip quip = Quip(payable(quipAddr));

    // verify pqOwner state transitioned to Free (first deployment)
    assertEq(uint256(portal.pqOwnerState(defaultPqOwnerHash)), uint256(PqOwnerState.Free));

    // verify quip is initialized correctly
    (bytes32 publicSeed, bytes32 publicKeyHash) = quip.pqOwner();
    assertEq(publicSeed, defaultPqOwner.publicSeed);
    assertEq(publicKeyHash, defaultPqOwner.publicKeyHash);
    assertEq(quip.termsDigest(), _digestPartyTerms(terms));
    assertTrue(quip.INIT_UNCOUPLED());
    assertEq(quip.PORTAL_FROM_BYTECODE(), address(portal));

    // verify no assets transferred (uncoupled quip has no balance)
    assertEq(quipAddr.balance, 0);
  }

  function test_deployUncoupledQuip_transitionsPqOwnerFromUnusedToFree() public {
    PartyTerms memory terms = _makeDefaultPartyTerms();

    assertEq(uint256(portal.pqOwnerState(defaultPqOwnerHash)), uint256(PqOwnerState.Unused));

    vm.prank(ALICE);
    portal.deployUncoupledQuip{value: CREATION_FEE}(defaultPqOwner, terms);

    assertEq(uint256(portal.pqOwnerState(defaultPqOwnerHash)), uint256(PqOwnerState.Free));
  }

  function test_deployUncoupledQuip_transitionsPqOwnerFromFreeToSpent_sameChainSwap() public {
    PartyTerms memory terms = _makeDefaultPartyTerms();

    // Alice deploys first quip (Unused → Free)
    vm.prank(ALICE);
    portal.deployUncoupledQuip{value: CREATION_FEE}(defaultPqOwner, terms);
    assertEq(uint256(portal.pqOwnerState(defaultPqOwnerHash)), uint256(PqOwnerState.Free));

    // Bob deploys second quip with same pqOwner (Free → Spent) - enables same-chain swaps
    vm.prank(BOB);
    portal.deployUncoupledQuip{value: CREATION_FEE}(defaultPqOwner, terms);
    assertEq(uint256(portal.pqOwnerState(defaultPqOwnerHash)), uint256(PqOwnerState.Spent));
  }

  function test_deployUncoupledQuip_accumulatesFeesAndIncreasesPortalBalance() public {
    PartyTerms memory terms = _makeDefaultPartyTerms();
    uint256 feesBefore = portal.accumulatedFees();
    uint256 portalBalanceBefore = address(portal).balance;

    vm.prank(ALICE);
    portal.deployUncoupledQuip{value: CREATION_FEE}(defaultPqOwner, terms);

    assertEq(portal.accumulatedFees() - feesBefore, CREATION_FEE);
    assertEq(address(portal).balance - portalBalanceBefore, CREATION_FEE);
  }

  function test_deployUncoupledQuip_emitsQuipProposedEvent() public {
    PartyTerms memory terms = _makeDefaultPartyTerms();

    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployUncoupledQuip{value: CREATION_FEE}(defaultPqOwner, terms);

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

  function test_deployUncoupledQuip_initializesQuipWithCorrectPqOwner() public {
    PartyTerms memory terms = _makeDefaultPartyTerms();

    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployUncoupledQuip{value: CREATION_FEE}(defaultPqOwner, terms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    address quipAddr = _findQuipProposedAddress(logs);
    Quip quip = Quip(payable(quipAddr));

    (bytes32 publicSeed, bytes32 publicKeyHash) = quip.pqOwner();
    assertEq(publicSeed, defaultPqOwner.publicSeed);
    assertEq(publicKeyHash, defaultPqOwner.publicKeyHash);
  }

  function test_deployUncoupledQuip_initializesQuipWithCorrectTermsDigest() public {
    PartyTerms memory terms = _makeDefaultPartyTerms();

    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployUncoupledQuip{value: CREATION_FEE}(defaultPqOwner, terms);

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
    portal.deployUncoupledQuip{value: CREATION_FEE}(defaultPqOwner, terms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    address quipAddr = _findQuipProposedAddress(logs);
    Quip quip = Quip(payable(quipAddr));

    assertTrue(quip.INIT_UNCOUPLED());
  }

  // ============ Revert Cases ============

  function test_deployUncoupledQuip_revertsWhen_pqOwnerPublicSeedIsZero() public {
    WOTSPlus.WinternitzAddress memory badPqOwner = WOTSPlus.WinternitzAddress({
      publicSeed: bytes32(0),
      publicKeyHash: bytes32(uint256(1))
    });
    PartyTerms memory terms = _makeDefaultPartyTerms();

    vm.prank(ALICE);
    vm.expectRevert(IQuipPortal.EmptyPqOwner.selector);
    portal.deployUncoupledQuip{value: CREATION_FEE}(badPqOwner, terms);
  }

  function test_deployUncoupledQuip_revertsWhen_pqOwnerPublicKeyHashIsZero() public {
    WOTSPlus.WinternitzAddress memory badPqOwner = WOTSPlus.WinternitzAddress({
      publicSeed: bytes32(uint256(1)),
      publicKeyHash: bytes32(0)
    });
    PartyTerms memory terms = _makeDefaultPartyTerms();

    vm.prank(ALICE);
    vm.expectRevert(IQuipPortal.EmptyPqOwner.selector);
    portal.deployUncoupledQuip{value: CREATION_FEE}(badPqOwner, terms);
  }

  function test_deployUncoupledQuip_revertsWhen_pqOwnerIsSpent() public {
    PartyTerms memory terms = _makeDefaultPartyTerms();

    // first deployment by Alice (Unused → Free)
    vm.prank(ALICE);
    portal.deployUncoupledQuip{value: CREATION_FEE}(defaultPqOwner, terms);

    // second deployment by Bob (Free → Spent)
    vm.prank(BOB);
    portal.deployUncoupledQuip{value: CREATION_FEE}(defaultPqOwner, terms);

    // third deployment by Charlie should fail - pqOwner is fully spent
    vm.prank(CHARLIE);
    vm.expectRevert(IQuipPortal.PqOwnerSpent.selector);
    portal.deployUncoupledQuip{value: CREATION_FEE}(defaultPqOwner, terms);
  }

  function test_deployUncoupledQuip_revertsWhen_sameDeployerUsesPqOwnerTwice() public {
    PartyTerms memory terms = _makeDefaultPartyTerms();

    // first deployment by Alice
    vm.prank(ALICE);
    portal.deployUncoupledQuip{value: CREATION_FEE}(defaultPqOwner, terms);

    // second deployment by Alice with same pqOwner fails (deterministic address collision)
    vm.prank(ALICE);
    vm.expectRevert(); // LibClone.DeploymentFailed or similar
    portal.deployUncoupledQuip{value: CREATION_FEE}(defaultPqOwner, terms);
  }

  function test_deployUncoupledQuip_revertsWhen_signatoryIsZero() public {
    PartyTerms memory terms = _makeDefaultPartyTerms();
    terms.signatory = address(0);

    vm.prank(ALICE);
    vm.expectRevert(IQuipPortal.EmptyParty.selector);
    portal.deployUncoupledQuip{value: CREATION_FEE}(defaultPqOwner, terms);
  }

  function test_deployUncoupledQuip_revertsWhen_recipientIsZero() public {
    PartyTerms memory terms = _makeDefaultPartyTerms();
    terms.recipient = address(0);

    vm.prank(ALICE);
    vm.expectRevert(IQuipPortal.EmptyRecipient.selector);
    portal.deployUncoupledQuip{value: CREATION_FEE}(defaultPqOwner, terms);
  }

  function test_deployUncoupledQuip_revertsWhen_expiryInPast() public {
    PartyTerms memory terms = _makeDefaultPartyTerms();
    terms.expiry = _expiredTimestamp();

    vm.prank(ALICE);
    vm.expectRevert(IQuipPortal.InvalidExpiry.selector);
    portal.deployUncoupledQuip{value: CREATION_FEE}(defaultPqOwner, terms);
  }

  function test_deployUncoupledQuip_revertsWhen_assetsEmpty() public {
    PartyTerms memory terms = _makeDefaultPartyTerms();
    terms.assets = new Asset[](0);

    vm.prank(ALICE);
    vm.expectRevert(IQuipPortal.EmptyAssets.selector);
    portal.deployUncoupledQuip{value: CREATION_FEE}(defaultPqOwner, terms);
  }

  function test_deployUncoupledQuip_revertsWhen_incorrectNativeAmount() public {
    PartyTerms memory terms = _makeDefaultPartyTerms();

    vm.prank(ALICE);
    vm.expectRevert(IQuipPortal.IncorrectNativeAmount.selector);
    portal.deployUncoupledQuip{value: CREATION_FEE - 1}(defaultPqOwner, terms);
  }

  function test_deployUncoupledQuip_revertsWhen_excessNativeAmount() public {
    PartyTerms memory terms = _makeDefaultPartyTerms();

    vm.prank(ALICE);
    vm.expectRevert(IQuipPortal.IncorrectNativeAmount.selector);
    portal.deployUncoupledQuip{value: CREATION_FEE + 1}(defaultPqOwner, terms);
  }

  // ============ Fuzz Tests ============

  function testFuzz_deployUncoupledQuip_withVariousPqOwners(bytes32 seed) public {
    (WOTSPlus.WinternitzAddress memory pqOwner,) = _generateKeyPair(seed);
    bytes32 pqOwnerHash = _computePqOwnerHash(pqOwner);
    vm.assume(portal.pqOwnerState(pqOwnerHash) == PqOwnerState.Unused);

    PartyTerms memory terms = _makeDefaultPartyTerms();

    vm.prank(ALICE);
    portal.deployUncoupledQuip{value: CREATION_FEE}(pqOwner, terms);

    assertEq(uint256(portal.pqOwnerState(pqOwnerHash)), uint256(PqOwnerState.Free));
  }
}
