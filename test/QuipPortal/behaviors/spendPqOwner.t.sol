// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Vm} from 'forge-std-1.14.0/Vm.sol';

import {Quip} from '../../../src/Quip.sol';
import {QuipPortal} from '../../../src/QuipPortal.sol';
import {QuipTerms, TermsLib} from '../../../src/TermsLib.sol';
import {IQuipPortal, PqOwnerState} from '../../../src/interfaces/IQuipPortal.sol';
import {QuipPortalTest} from '../QuipPortal.t.sol';
import {LibClone} from 'solady-0.1.26/utils/LibClone.sol';
import {WOTSPlus} from '@quip.network/hashsigs-solidity-0.1.0/contracts/WOTSPlus.sol';

/// @title Malicious Quip that inherits from Quip but adds a direct spendPqOwner call
/// @dev Deployed via LibClone to have portal address in correct bytecode position
contract MaliciousQuip is Quip {
  /// @notice Directly calls spendPqOwner on the portal (bypassing claim/reclaim)
  function callSpendPqOwner(bytes32 _pqOwnerHash) external {
    IQuipPortal(PORTAL_FROM_BYTECODE()).spendPqOwner(_pqOwnerHash);
  }
}

/// @title QuipPortal spendPqOwner Tests
/// @dev Tests for QuipPortal.spendPqOwner
contract QuipPortal_spendPqOwner is QuipPortalTest {
  Quip public spendPqOwnerQuip;
  WOTSPlus.WinternitzAddress public testPqOwner;
  bytes32 public testPqOwnerHash;
  bytes32 public testPrivateKey;

  // ============ setUp ============

  function setUp() public override {
    super.setUp();

    // deploy a quip to set QUIP_CODEHASH and have a valid pqOwner
    (testPqOwner, testPrivateKey) = _uniqueKeyPair(200);
    testPqOwnerHash = _computePqOwnerHash(testPqOwner);
    QuipTerms memory terms = _makeDefaultQuipTerms();
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployCoupledQuip{value: nativeRequired}(testPqOwner, terms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    address quipAddr = _findQuipCreatedAddress(logs);
    spendPqOwnerQuip = Quip(payable(quipAddr));
  }

  // ============ test_setUp ============

  /// @dev Override test_setUp because this test deploys a quip in setUp, so accumulatedFees != 0
  function test_setUp() public view override {
    assertEq(portal.VERSION(), 1);
    assertEq(portal.MAX_FEE(), MAX_FEE);
    assertEq(portal.creationFee(), CREATION_FEE);
    // accumulatedFees is CREATION_FEE because we deployed a quip in setUp
    assertEq(portal.accumulatedFees(), CREATION_FEE);
    assertEq(portal.admin(), ADMIN);
    // pqOwner should be Free after single deployment
    assertEq(uint256(portal.pqOwnerState(testPqOwnerHash)), uint256(PqOwnerState.Free));
  }

  // ============ Happy Paths ============

  function test_spendPqOwner_transitionsFromFreeToSpent() public {
    // verify initial state
    assertEq(uint256(portal.pqOwnerState(testPqOwnerHash)), uint256(PqOwnerState.Free));

    // trigger spendPqOwner via claim (which calls spendPqOwner internally)
    QuipTerms memory terms = _makeDefaultQuipTerms();
    WOTSPlus.WinternitzElements memory signature = _signTerms(testPrivateKey, terms);
    spendPqOwnerQuip.claim(signature, terms);

    // verify final state
    assertEq(uint256(portal.pqOwnerState(testPqOwnerHash)), uint256(PqOwnerState.Spent));
  }

  function test_spendPqOwner_isIdempotentWhenAlreadySpent() public {
    // setup: deploy two quips with the same pqOwner (same-chain swap scenario)
    (WOTSPlus.WinternitzAddress memory newPqOwner, bytes32 newPrivateKey) = _uniqueKeyPair(201);
    bytes32 newPqOwnerHash = _computePqOwnerHash(newPqOwner);
    QuipTerms memory terms = _makeDefaultQuipTerms();
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

    // verify initial state
    assertEq(uint256(portal.pqOwnerState(newPqOwnerHash)), uint256(PqOwnerState.Unused));

    // Alice deploys first quip (Unused -> Free)
    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployCoupledQuip{value: nativeRequired}(newPqOwner, terms);
    Vm.Log[] memory logs = vm.getRecordedLogs();
    address aliceQuipAddr = _findQuipCreatedAddress(logs);
    Quip aliceQuip = Quip(payable(aliceQuipAddr));

    // verify state after first deployment
    assertEq(uint256(portal.pqOwnerState(newPqOwnerHash)), uint256(PqOwnerState.Free));

    // Bob deploys second quip with same pqOwner (Free -> Spent)
    vm.prank(BOB);
    vm.recordLogs();
    portal.deployCoupledQuip{value: nativeRequired}(newPqOwner, terms);
    Vm.Log[] memory logs2 = vm.getRecordedLogs();
    address bobQuipAddr = _findQuipCreatedAddress(logs2);
    Quip bobQuip = Quip(payable(bobQuipAddr));

    // verify state after second deployment
    assertEq(uint256(portal.pqOwnerState(newPqOwnerHash)), uint256(PqOwnerState.Spent));

    // Alice's quip can still claim (spendPqOwner is idempotent when already Spent)
    WOTSPlus.WinternitzElements memory signature = _signTerms(newPrivateKey, terms);
    aliceQuip.claim(signature, terms);

    // verify state unchanged after first claim
    assertEq(uint256(portal.pqOwnerState(newPqOwnerHash)), uint256(PqOwnerState.Spent));

    // Bob's quip can also claim (spendPqOwner is idempotent)
    bobQuip.claim(signature, terms);

    // verify final state
    assertEq(uint256(portal.pqOwnerState(newPqOwnerHash)), uint256(PqOwnerState.Spent));
  }

  function test_spendPqOwner_emitsSpentPqOwner() public {
    // verify initial state
    assertEq(uint256(portal.pqOwnerState(testPqOwnerHash)), uint256(PqOwnerState.Free));

    QuipTerms memory terms = _makeDefaultQuipTerms();
    WOTSPlus.WinternitzElements memory signature = _signTerms(testPrivateKey, terms);

    vm.recordLogs();
    spendPqOwnerQuip.claim(signature, terms);

    // verify final state
    assertEq(uint256(portal.pqOwnerState(testPqOwnerHash)), uint256(PqOwnerState.Spent));

    Vm.Log[] memory logs = vm.getRecordedLogs();
    bool found = false;
    for (uint256 i = 0; i < logs.length; i++) {
      if (logs[i].topics[0] == IQuipPortal.SpentPqOwner.selector) {
        assertEq(logs[i].topics[1], testPqOwnerHash); // indexed pqOwnerHash
        found = true;
        break;
      }
    }
    assertTrue(found, 'SpentPqOwner not found');
  }

  function test_QUIP_CODEHASH_setOnFirstDeployment() public {
    // deploy fresh portal
    Quip freshQuipImpl = new Quip();
    QuipPortal freshPortal = new QuipPortal(ADMIN, address(freshQuipImpl), MAX_FEE, CREATION_FEE);

    // initially zero
    assertEq(freshPortal.QUIP_CODEHASH(), bytes32(0));

    // deploy first quip
    (WOTSPlus.WinternitzAddress memory pqOwner,) = _uniqueKeyPair(300);
    bytes32 pqOwnerHash = _computePqOwnerHash(pqOwner);
    QuipTerms memory terms = _makeDefaultQuipTerms();
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

    // verify pqOwner state before
    assertEq(uint256(freshPortal.pqOwnerState(pqOwnerHash)), uint256(PqOwnerState.Unused));

    vm.prank(ALICE);
    vm.recordLogs();
    freshPortal.deployCoupledQuip{value: nativeRequired}(pqOwner, terms);

    // verify pqOwner state after
    assertEq(uint256(freshPortal.pqOwnerState(pqOwnerHash)), uint256(PqOwnerState.Free));

    Vm.Log[] memory logs = vm.getRecordedLogs();
    address quip1Addr = _findQuipCreatedAddress(logs);

    // QUIP_CODEHASH should now be set
    bytes32 expectedHash = freshPortal.QUIP_CODEHASH();
    assertTrue(expectedHash != bytes32(0));
    assertEq(expectedHash, quip1Addr.codehash);
  }

  function test_QUIP_CODEHASH_sameForAllClones() public {
    // deploy fresh portal
    Quip freshQuipImpl = new Quip();
    QuipPortal freshPortal = new QuipPortal(ADMIN, address(freshQuipImpl), MAX_FEE, CREATION_FEE);

    QuipTerms memory terms = _makeDefaultQuipTerms();
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

    // deploy first quip
    (WOTSPlus.WinternitzAddress memory pqOwner1,) = _uniqueKeyPair(301);
    bytes32 pqOwnerHash1 = _computePqOwnerHash(pqOwner1);

    // verify initial state
    assertEq(uint256(freshPortal.pqOwnerState(pqOwnerHash1)), uint256(PqOwnerState.Unused));

    vm.prank(ALICE);
    vm.recordLogs();
    freshPortal.deployCoupledQuip{value: nativeRequired}(pqOwner1, terms);
    Vm.Log[] memory logs1 = vm.getRecordedLogs();
    address quip1 = _findQuipCreatedAddress(logs1);

    // verify state after first deployment
    assertEq(uint256(freshPortal.pqOwnerState(pqOwnerHash1)), uint256(PqOwnerState.Free));

    // deploy second quip with different pqOwner
    (WOTSPlus.WinternitzAddress memory pqOwner2,) = _uniqueKeyPair(302);
    bytes32 pqOwnerHash2 = _computePqOwnerHash(pqOwner2);

    // verify initial state for second pqOwner
    assertEq(uint256(freshPortal.pqOwnerState(pqOwnerHash2)), uint256(PqOwnerState.Unused));

    vm.prank(BOB);
    vm.recordLogs();
    freshPortal.deployCoupledQuip{value: nativeRequired}(pqOwner2, terms);
    Vm.Log[] memory logs2 = vm.getRecordedLogs();
    address quip2 = _findQuipCreatedAddress(logs2);

    // verify state after second deployment
    assertEq(uint256(freshPortal.pqOwnerState(pqOwnerHash2)), uint256(PqOwnerState.Free));

    // both quips should have the same codehash
    assertEq(quip1.codehash, quip2.codehash);

    // and it should match the stored QUIP_CODEHASH
    assertEq(quip1.codehash, freshPortal.QUIP_CODEHASH());
  }

  // ============ Reversions ============

  function test_spendPqOwner_revertsWhen_calledByEOA() public {
    // verify initial state
    assertEq(uint256(portal.pqOwnerState(testPqOwnerHash)), uint256(PqOwnerState.Free));

    // EOA tries to call spendPqOwner directly
    vm.prank(ALICE);
    vm.expectRevert(IQuipPortal.CallerNotQuip.selector);
    portal.spendPqOwner(testPqOwnerHash);

    // verify pqOwner state unchanged
    assertEq(uint256(portal.pqOwnerState(testPqOwnerHash)), uint256(PqOwnerState.Free));
  }

  function test_spendPqOwner_revertsWhen_calledByArbitraryContract() public {
    // verify initial state
    assertEq(uint256(portal.pqOwnerState(testPqOwnerHash)), uint256(PqOwnerState.Free));

    // any random contract that's not a quip clone
    vm.prank(address(mockERC20));
    vm.expectRevert(IQuipPortal.CallerNotQuip.selector);
    portal.spendPqOwner(testPqOwnerHash);

    // verify pqOwner state unchanged
    assertEq(uint256(portal.pqOwnerState(testPqOwnerHash)), uint256(PqOwnerState.Free));
  }

  function test_spendPqOwner_revertsWhen_noQuipsDeployedYet() public {
    // deploy a fresh portal with no quips deployed
    Quip freshQuipImpl = new Quip();
    QuipPortal freshPortal = new QuipPortal(ADMIN, address(freshQuipImpl), MAX_FEE, CREATION_FEE);

    // QUIP_CODEHASH is bytes32(0) since no quips deployed
    assertEq(freshPortal.QUIP_CODEHASH(), bytes32(0));

    // any caller will fail because their codehash won't match bytes32(0)
    vm.prank(ALICE);
    vm.expectRevert(IQuipPortal.CallerNotQuip.selector);
    freshPortal.spendPqOwner(testPqOwnerHash);
  }

  // ============ Attacks ============

  function test_spendPqOwner_revertsWhen_calledByMaliciousQuip() public {
    // verify initial state
    assertEq(uint256(portal.pqOwnerState(testPqOwnerHash)), uint256(PqOwnerState.Free));

    // deploy MaliciousQuip implementation
    MaliciousQuip maliciousImpl = new MaliciousQuip();

    // deploy as clone with portal address in bytecode (like real quips)
    address maliciousClone = LibClone.clone(address(maliciousImpl), abi.encode(address(portal)));

    // verify the malicious clone can read the portal address correctly
    assertEq(MaliciousQuip(payable(maliciousClone)).PORTAL_FROM_BYTECODE(), address(portal));

    // verify the malicious clone has a DIFFERENT codehash than legitimate quips
    assertTrue(maliciousClone.codehash != portal.QUIP_CODEHASH(), 'Codehash should differ');

    // attacker tries to spend a pqOwner via malicious quip
    vm.expectRevert(IQuipPortal.CallerNotQuip.selector);
    MaliciousQuip(payable(maliciousClone)).callSpendPqOwner(testPqOwnerHash);

    // verify pqOwner state unchanged
    assertEq(uint256(portal.pqOwnerState(testPqOwnerHash)), uint256(PqOwnerState.Free));
  }
}
