// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {IQuipPortal} from '../../src/interfaces/IQuipPortal.sol';
import {QuipPortalHarness} from '../harness/QuipPortalHarness.sol';
import {TestBase} from '../utils/TestBase.sol';

/// @title QuipPortal Base Test
/// @dev Base contract for testing QuipPortal
contract QuipPortalTest is TestBase {
  QuipPortalHarness public portalHarness;

  function setUp() public virtual override {
    super.setUp();

    // Deploy harness for internal function testing
    portalHarness = new QuipPortalHarness(ADMIN, address(quipImpl), MAX_FEE, CREATION_FEE);

    // Fund actors and approve
    _approveAll(ALICE);
    _approveAll(BOB);
  }

  function test_setUp() public view virtual {
    // Check portal deployment
    assertEq(portal.VERSION(), 1);
    assertEq(portal.MAX_FEE(), MAX_FEE);
    assertEq(portal.creationFee(), CREATION_FEE);
    assertEq(portal.accumulatedFees(), 0);
    assertEq(portal.admin(), ADMIN);

    // Check actors are funded
    assertGt(ALICE.balance, 0);
    assertGt(BOB.balance, 0);
    assertGt(mockERC20.balanceOf(ALICE), 0);
    assertGt(mockERC20.balanceOf(BOB), 0);
  }

  function test_setUp_portalHarness() public view {
    assertEq(portalHarness.VERSION(), 1);
    assertEq(portalHarness.MAX_FEE(), MAX_FEE);
    assertEq(portalHarness.creationFee(), CREATION_FEE);
    assertEq(portalHarness.admin(), ADMIN);
  }

  // ============ Constructor Tests ============

  function test_constructor_setsAdmin() public view {
    assertEq(portal.admin(), ADMIN);
  }

  function test_constructor_setsMaxFee() public view {
    assertEq(portal.MAX_FEE(), MAX_FEE);
  }

  function test_constructor_setsCreationFee() public view {
    assertEq(portal.creationFee(), CREATION_FEE);
  }

  function test_constructor_revertsWhen_adminIsZeroAddress() public {
    vm.expectRevert(IQuipPortal.EmptyAddress.selector);
    new QuipPortalHarness(address(0), address(quipImpl), MAX_FEE, CREATION_FEE);
  }

  function test_constructor_revertsWhen_quipImplIsZeroAddress() public {
    vm.expectRevert(IQuipPortal.EmptyAddress.selector);
    new QuipPortalHarness(ADMIN, address(0), MAX_FEE, CREATION_FEE);
  }

  function test_constructor_revertsWhen_creationFeeExceedsMax() public {
    vm.expectRevert(IQuipPortal.FeeExceedsMax.selector);
    new QuipPortalHarness(ADMIN, address(quipImpl), MAX_FEE, MAX_FEE + 1);
  }

  function test_constructor_allowsCreationFeeEqualToMax() public {
    QuipPortalHarness newPortal = new QuipPortalHarness(ADMIN, address(quipImpl), MAX_FEE, MAX_FEE);
    assertEq(newPortal.creationFee(), MAX_FEE);
  }
}
