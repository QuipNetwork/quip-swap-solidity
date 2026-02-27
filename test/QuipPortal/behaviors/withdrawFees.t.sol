// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {QuipTerms, TermsLib} from '../../../src/TermsLib.sol';
import {IQuipPortal, PqOwnerState} from '../../../src/interfaces/IQuipPortal.sol';
import {QuipPortalTest} from '../QuipPortal.t.sol';

/// @title QuipPortal withdrawFees Tests
/// @dev Tests for QuipPortal.withdrawFees
contract QuipPortal_withdrawFees is QuipPortalTest {
  function setUp() public override {
    super.setUp();
    // Accumulate some fees by deploying a quip
    _accumulateFees();
  }

  function test_setUp() public view override {
    // override parent's test_setUp since we modify state in setUp
    assertEq(portal.accumulatedFees(), CREATION_FEE);
    assertEq(uint256(portal.pqOwnerState(defaultPqOwnerHash)), uint256(PqOwnerState.Free));
  }

  function _accumulateFees() internal {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

    vm.prank(ALICE);
    portal.deployCoupledQuip{value: nativeRequired}(defaultPqOwner, terms);
  }

  // ============ Success Cases ============
  function test_withdrawFees_transfersFeesToReceiver() public {
    uint256 receiverBefore = CHARLIE.balance;
    uint256 fees = portal.accumulatedFees();

    vm.prank(ADMIN);
    portal.withdrawFees(CHARLIE, fees);

    assertEq(CHARLIE.balance - receiverBefore, fees);
  }

  function test_withdrawFees_reducesAccumulatedFees() public {
    uint256 fees = portal.accumulatedFees();

    vm.prank(ADMIN);
    portal.withdrawFees(CHARLIE, fees);

    assertEq(portal.accumulatedFees(), 0);
  }

  function test_withdrawFees_partialWithdrawal() public {
    uint256 fees = portal.accumulatedFees();
    uint256 partialAmount = fees / 2;

    vm.prank(ADMIN);
    portal.withdrawFees(CHARLIE, partialAmount);

    assertEq(portal.accumulatedFees(), fees - partialAmount);
  }

  function test_withdrawFees_emitsFeesWithdrawnEvent() public {
    uint256 fees = portal.accumulatedFees();

    vm.prank(ADMIN);
    vm.expectEmit(true, false, false, true);
    emit IQuipPortal.FeesWithdrawn(CHARLIE, fees);
    portal.withdrawFees(CHARLIE, fees);
  }

  function test_withdrawFees_allowsZeroAmountWithdrawal() public {
    vm.prank(ADMIN);
    portal.withdrawFees(CHARLIE, 0);
  }

  function test_withdrawFees_multipleWithdrawals() public {
    uint256 fees = portal.accumulatedFees();
    uint256 amount1 = fees / 3;
    uint256 amount2 = fees / 3;

    vm.startPrank(ADMIN);
    portal.withdrawFees(CHARLIE, amount1);
    portal.withdrawFees(CHARLIE, amount2);
    vm.stopPrank();

    assertEq(portal.accumulatedFees(), fees - amount1 - amount2);
  }

  // ============ Revert Cases ============

  function test_withdrawFees_revertsWhen_callerNotAdmin() public {
    uint256 fees = portal.accumulatedFees();

    vm.prank(ALICE);
    vm.expectRevert(IQuipPortal.NotAdmin.selector);
    portal.withdrawFees(CHARLIE, fees);
  }

  function test_withdrawFees_revertsWhen_amountExceedsFees() public {
    uint256 fees = portal.accumulatedFees();

    vm.prank(ADMIN);
    vm.expectRevert(IQuipPortal.InsufficientFees.selector);
    portal.withdrawFees(CHARLIE, fees + 1);
  }

  // ============ Fuzz Tests ============

  function testFuzz_withdrawFees_partialAmounts(uint256 amount) public {
    uint256 fees = portal.accumulatedFees();
    amount = bound(amount, 0, fees);

    uint256 receiverBefore = CHARLIE.balance;

    vm.prank(ADMIN);
    portal.withdrawFees(CHARLIE, amount);

    assertEq(CHARLIE.balance - receiverBefore, amount);
    assertEq(portal.accumulatedFees(), fees - amount);
  }
}
