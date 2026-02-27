// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {IQuipPortal} from '../../../src/interfaces/IQuipPortal.sol';
import {QuipPortalTest} from '../QuipPortal.t.sol';

/// @title QuipPortal _enforceNonEmptyAddress Tests
/// @dev Tests for QuipPortal._enforceNonEmptyAddress
contract QuipPortal__enforceNonEmptyAddress is QuipPortalTest {
  // ============ Success Cases ============

  function test_exposed_enforceNonEmptyAddress_succeedsWithNonZeroAddress() public view {
    portalHarness.exposed_enforceNonEmptyAddress(ALICE);
  }

  function test_exposed_enforceNonEmptyAddress_succeedsWithContractAddress() public view {
    portalHarness.exposed_enforceNonEmptyAddress(address(portal));
  }

  function test_exposed_enforceNonEmptyAddress_succeedsWithAddress1() public view {
    portalHarness.exposed_enforceNonEmptyAddress(address(1));
  }

  // ============ Revert Cases ============

  function test_exposed_enforceNonEmptyAddress_revertsWhen_addressIsZero() public {
    vm.expectRevert(IQuipPortal.EmptyAddress.selector);
    portalHarness.exposed_enforceNonEmptyAddress(address(0));
  }

  // ============ Fuzz Tests ============

  function testFuzz_exposed_enforceNonEmptyAddress_succeedsWithNonZeroAddress(address addr) public view {
    vm.assume(addr != address(0));
    portalHarness.exposed_enforceNonEmptyAddress(addr);
  }
}
