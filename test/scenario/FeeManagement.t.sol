// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {IQuipPortal} from '../../src/interfaces/IQuipPortal.sol';
import {QuipTerms, TermsLib} from '../../src/TermsLib.sol';
import {TestBase} from '../utils/TestBase.sol';

/// @title Fee Management Scenario Tests
/// @dev Tests for fee collection and withdrawal workflows
contract FeeManagementTest is TestBase {
  function setUp() public override {
    super.setUp();
    _approveAll(ALICE);
  }

  // ============ Fee Collection Tests ============

  function test_simulation_feeCollection_singleDeployment() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

    uint256 feesBefore = portal.accumulatedFees();

    vm.prank(ALICE);
    portal.deployCoupledQuip{value: nativeRequired}(defaultLock, terms);

    assertEq(portal.accumulatedFees() - feesBefore, CREATION_FEE);
  }

  function test_simulation_feeCollection_multipleDeployments() public {
    uint256 deployCount = 5;
    uint256 feesBefore = portal.accumulatedFees();

    for (uint256 i = 0; i < deployCount; i++) {
      bytes32 lock = _uniqueLock(i);
      QuipTerms memory terms = _makeDefaultQuipTerms();
      uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

      vm.prank(ALICE);
      portal.deployCoupledQuip{value: nativeRequired}(lock, terms);
    }

    assertEq(portal.accumulatedFees() - feesBefore, CREATION_FEE * deployCount);
  }

  function test_simulation_feeCollection_withZeroFee() public {
    // Set fee to zero
    vm.prank(ADMIN);
    portal.setCreationFee(0);

    QuipTerms memory terms = _makeDefaultQuipTerms();
    uint256 nativeRequired = TermsLib.totalNativeAmount(terms.partyAssets);

    uint256 feesBefore = portal.accumulatedFees();

    vm.prank(ALICE);
    portal.deployCoupledQuip{value: nativeRequired}(defaultLock, terms);

    assertEq(portal.accumulatedFees(), feesBefore); // No change
  }

  // ============ Fee Withdrawal Tests ============

  function test_simulation_feeWithdrawal_fullWithdrawal() public {
    // Accumulate fees
    for (uint256 i = 0; i < 3; i++) {
      bytes32 lock = _uniqueLock(i);
      QuipTerms memory terms = _makeDefaultQuipTerms();
      uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

      vm.prank(ALICE);
      portal.deployCoupledQuip{value: nativeRequired}(lock, terms);
    }

    uint256 totalFees = portal.accumulatedFees();
    uint256 adminBefore = ADMIN.balance;

    vm.prank(ADMIN);
    portal.withdrawFees(ADMIN, totalFees);

    assertEq(ADMIN.balance - adminBefore, totalFees);
    assertEq(portal.accumulatedFees(), 0);
  }

  function test_simulation_feeWithdrawal_partialWithdrawals() public {
    // Accumulate fees
    for (uint256 i = 0; i < 5; i++) {
      bytes32 lock = _uniqueLock(i);
      QuipTerms memory terms = _makeDefaultQuipTerms();
      uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

      vm.prank(ALICE);
      portal.deployCoupledQuip{value: nativeRequired}(lock, terms);
    }

    uint256 totalFees = portal.accumulatedFees();

    // Withdraw in parts
    vm.startPrank(ADMIN);
    portal.withdrawFees(ADMIN, totalFees / 2);
    assertEq(portal.accumulatedFees(), totalFees - totalFees / 2);

    portal.withdrawFees(ADMIN, portal.accumulatedFees());
    assertEq(portal.accumulatedFees(), 0);
    vm.stopPrank();
  }

  function test_simulation_feeWithdrawal_toDifferentReceiver() public {
    // Accumulate fees
    QuipTerms memory terms = _makeDefaultQuipTerms();
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

    vm.prank(ALICE);
    portal.deployCoupledQuip{value: nativeRequired}(defaultLock, terms);

    uint256 fees = portal.accumulatedFees();
    uint256 charlieBefore = CHARLIE.balance;

    // Withdraw to different address
    vm.prank(ADMIN);
    portal.withdrawFees(CHARLIE, fees);

    assertEq(CHARLIE.balance - charlieBefore, fees);
  }

  // ============ Fee Update Tests ============

  function test_simulation_feeUpdate_affectsFutureDeployments() public {
    uint256 newFee = 0.05 ether;

    // Deploy with original fee
    bytes32 lock1 = _uniqueLock(1);
    QuipTerms memory terms = _makeDefaultQuipTerms();

    vm.prank(ALICE);
    portal.deployCoupledQuip{value: CREATION_FEE + 1 ether}(lock1, terms);

    uint256 feesAfterFirst = portal.accumulatedFees();
    assertEq(feesAfterFirst, CREATION_FEE);

    // Update fee
    vm.prank(ADMIN);
    portal.setCreationFee(newFee);

    // Deploy with new fee
    bytes32 lock2 = _uniqueLock(2);
    terms = _makeDefaultQuipTerms();

    vm.prank(ALICE);
    portal.deployCoupledQuip{value: newFee + 1 ether}(lock2, terms);

    assertEq(portal.accumulatedFees() - feesAfterFirst, newFee);
  }

  // ============ Edge Cases ============

  function test_simulation_feeManagement_maxFee() public {
    // Set to max fee
    vm.prank(ADMIN);
    portal.setCreationFee(MAX_FEE);

    QuipTerms memory terms = _makeDefaultQuipTerms();
    uint256 nativeRequired = MAX_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

    vm.prank(ALICE);
    portal.deployCoupledQuip{value: nativeRequired}(defaultLock, terms);

    assertEq(portal.accumulatedFees(), MAX_FEE);
  }

  function test_simulation_feeManagement_withdrawZero() public {
    // Accumulate some fees
    QuipTerms memory terms = _makeDefaultQuipTerms();
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

    vm.prank(ALICE);
    portal.deployCoupledQuip{value: nativeRequired}(defaultLock, terms);

    uint256 feesBefore = portal.accumulatedFees();

    // Withdraw zero
    vm.prank(ADMIN);
    portal.withdrawFees(ADMIN, 0);

    assertEq(portal.accumulatedFees(), feesBefore);
  }
}
