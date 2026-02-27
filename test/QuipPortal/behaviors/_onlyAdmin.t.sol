// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {IQuipPortal} from '../../../src/interfaces/IQuipPortal.sol';
import {QuipPortalTest} from '../QuipPortal.t.sol';

/// @title QuipPortal _onlyAdmin Tests
/// @dev Tests for QuipPortal._onlyAdmin
contract QuipPortal__onlyAdmin is QuipPortalTest {
  // ============ Success Cases ============

  function test_exposed_onlyAdmin_succeedsWhenCallerIsAdmin() public {
    vm.prank(ADMIN);
    portalHarness.exposed_onlyAdmin();
  }

  // ============ Revert Cases ============

  function test_exposed_onlyAdmin_revertsWhen_callerNotAdmin() public {
    vm.prank(ALICE);
    vm.expectRevert(IQuipPortal.NotAdmin.selector);
    portalHarness.exposed_onlyAdmin();
  }

  function test_exposed_onlyAdmin_revertsWhen_callerIsZeroAddress() public {
    vm.prank(address(0));
    vm.expectRevert(IQuipPortal.NotAdmin.selector);
    portalHarness.exposed_onlyAdmin();
  }

  // ============ Fuzz Tests ============

  function testFuzz_exposed_onlyAdmin_revertsWhen_callerNotAdmin(address caller) public {
    vm.assume(caller != ADMIN);

    vm.prank(caller);
    vm.expectRevert(IQuipPortal.NotAdmin.selector);
    portalHarness.exposed_onlyAdmin();
  }
}
