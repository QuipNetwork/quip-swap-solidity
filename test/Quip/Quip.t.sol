// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Vm} from 'forge-std-1.14.0/Vm.sol';

import {Quip} from '../../src/Quip.sol';
import {Asset, QuipTerms, TermsLib} from '../../src/TermsLib.sol';
import {IQuip} from '../../src/interfaces/IQuip.sol';
import {IQuipPortal} from '../../src/interfaces/IQuipPortal.sol';
import {QuipHarness} from '../harness/QuipHarness.sol';
import {TestBase} from '../utils/TestBase.sol';

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
    portal.deployCoupledQuip{value: nativeRequired}(defaultLock, terms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    address quipAddr = _findQuipCreatedAddress(logs);
    deployedQuip = Quip(payable(quipAddr));
  }

  function test_setUp() public view {
    // Check harness deployment
    assertNotEq(address(quipHarness), address(0));

    // Check deployed quip
    assertNotEq(address(deployedQuip), address(0));
    assertEq(deployedQuip.VERSION(), 1);
    assertEq(deployedQuip.lock(), defaultLock);
    assertFalse(deployedQuip.INIT_UNCOUPLED());
  }

  function test_PORTAL_FROM_BYTECODE_returnsDeployingPortal() public view {
    assertEq(deployedQuip.PORTAL_FROM_BYTECODE(), address(portal));
  }

  function test_setUp_deployedQuipHasCorrectTermsDigest() public view {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    bytes32 expectedDigest = _digestQuipTerms(terms);
    assertEq(deployedQuip.termsDigest(), expectedDigest);
  }

  function test_setUp_deployedQuipHasCorrectBalance() public view {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    uint256 expectedBalance = TermsLib.totalNativeAmount(terms.partyAssets);
    assertEq(address(deployedQuip).balance, expectedBalance);
  }

  // ============ Helper Functions ============

  function _deployQuipWithTerms(bytes32 lock, QuipTerms memory terms) internal returns (Quip) {
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployCoupledQuip{value: nativeRequired}(lock, terms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    address quipAddr = _findQuipCreatedAddress(logs);
    return Quip(payable(quipAddr));
  }
}
