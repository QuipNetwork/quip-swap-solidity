// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {IQuipPortal} from '../../../src/interfaces/IQuipPortal.sol';
import {QuipPortalTest} from '../QuipPortal.t.sol';

/// @title QuipPortal setCreationFee Tests
/// @dev Tests for QuipPortal.setCreationFee
contract QuipPortal_setCreationFee is QuipPortalTest {
  // ============ Success Cases ============

  function test_setCreationFee_updatesCreationFee() public {
    uint256 newFee = 0.05 ether;

    vm.prank(ADMIN);
    portal.setCreationFee(newFee);

    assertEq(portal.creationFee(), newFee);
  }

  function test_setCreationFee_allowsZeroFee() public {
    vm.prank(ADMIN);
    portal.setCreationFee(0);

    assertEq(portal.creationFee(), 0);
  }

  function test_setCreationFee_allowsMaxFee() public {
    vm.prank(ADMIN);
    portal.setCreationFee(MAX_FEE);

    assertEq(portal.creationFee(), MAX_FEE);
  }

  function test_setCreationFee_emitsCreationFeeUpdatedEvent() public {
    uint256 newFee = 0.05 ether;

    vm.prank(ADMIN);
    vm.expectEmit(false, false, false, true);
    emit IQuipPortal.CreationFeeUpdated(newFee);
    portal.setCreationFee(newFee);
  }

  function test_setCreationFee_allowsMultipleUpdates() public {
    vm.startPrank(ADMIN);

    portal.setCreationFee(0.02 ether);
    assertEq(portal.creationFee(), 0.02 ether);

    portal.setCreationFee(0.05 ether);
    assertEq(portal.creationFee(), 0.05 ether);

    portal.setCreationFee(0);
    assertEq(portal.creationFee(), 0);

    vm.stopPrank();
  }

  // ============ Revert Cases ============

  function test_setCreationFee_revertsWhen_callerNotAdmin() public {
    vm.prank(ALICE);
    vm.expectRevert(IQuipPortal.NotAdmin.selector);
    portal.setCreationFee(0.05 ether);
  }

  function test_setCreationFee_revertsWhen_feeExceedsMax() public {
    vm.prank(ADMIN);
    vm.expectRevert(IQuipPortal.FeeExceedsMax.selector);
    portal.setCreationFee(MAX_FEE + 1);
  }

  // ============ Fuzz Tests ============

  function testFuzz_setCreationFee_withinMaxBound(uint256 newFee) public {
    newFee = bound(newFee, 0, MAX_FEE);

    vm.prank(ADMIN);
    portal.setCreationFee(newFee);

    assertEq(portal.creationFee(), newFee);
  }

  function testFuzz_setCreationFee_revertsWhen_exceedsMax(uint256 newFee) public {
    newFee = bound(newFee, MAX_FEE + 1, type(uint256).max);

    vm.prank(ADMIN);
    vm.expectRevert(IQuipPortal.FeeExceedsMax.selector);
    portal.setCreationFee(newFee);
  }
}
