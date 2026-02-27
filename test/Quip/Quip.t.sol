// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Vm} from 'forge-std-1.14.0/Vm.sol';

import {Quip} from '../../src/Quip.sol';
import {QuipTerms, TermsLib} from '../../src/TermsLib.sol';
import {QuipHarness} from '../harness/QuipHarness.sol';
import {TestBase} from '../utils/TestBase.sol';
import {WOTSPlus} from '@quip.network/hashsigs-solidity-0.1.0/contracts/WOTSPlus.sol';

/// @title Quip Base Test
/// @dev Base contract for testing Quip
contract QuipTest is TestBase {
  QuipHarness public quipHarness;

  // Deployed quip via portal for integration tests
  Quip public deployedQuip;

  function setUp() public virtual override {
    super.setUp();

    // Deploy standalone harness for internal function testing
    quipHarness = new QuipHarness();

    // Fund actors and approve
    _approveAll(ALICE);
    _approveAll(BOB);

    // Deploy a quip via portal for integration tests
    QuipTerms memory terms = _makeDefaultQuipTerms();
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployCoupledQuip{value: nativeRequired}(defaultPqOwner, terms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    address quipAddr = _findQuipCreatedAddress(logs);
    deployedQuip = Quip(payable(quipAddr));
  }

  function test_setUp() public view {
    // check harness deployment
    assertNotEq(address(quipHarness), address(0));

    // check deployed quip
    assertNotEq(address(deployedQuip), address(0));
    assertEq(deployedQuip.VERSION(), 1);
    (bytes32 publicSeed, bytes32 publicKeyHash) = deployedQuip.pqOwner();
    assertEq(publicSeed, defaultPqOwner.publicSeed);
    assertEq(publicKeyHash, defaultPqOwner.publicKeyHash);
    assertFalse(deployedQuip.INIT_UNCOUPLED());
  }

  function test_PORTAL_FROM_BYTECODE_returnsDeployingPortal() public view {
    assertEq(deployedQuip.PORTAL_FROM_BYTECODE(), address(portal));
  }

  function test_setUp_deployedQuipHasCorrectTermsDigest() public view {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    bytes32 expectedDigest = _digestTermsCanonically(terms);
    assertEq(deployedQuip.termsDigest(), expectedDigest);
  }

  function test_setUp_deployedQuipHasCorrectBalance() public view {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    uint256 expectedBalance = TermsLib.totalNativeAmount(terms.partyAssets);
    assertEq(address(deployedQuip).balance, expectedBalance);
  }

  // ============ Helper Functions ============

  function _deployQuipWithTerms(
    WOTSPlus.WinternitzAddress memory pqOwner,
    QuipTerms memory terms
  ) internal returns (Quip) {
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployCoupledQuip{value: nativeRequired}(pqOwner, terms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    address quipAddr = _findQuipCreatedAddress(logs);
    return Quip(payable(quipAddr));
  }
}
