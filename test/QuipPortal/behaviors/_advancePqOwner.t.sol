// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {PqOwnerState} from '../../../src/interfaces/IQuipPortal.sol';
import {QuipPortalTest} from '../QuipPortal.t.sol';

/// @title QuipPortal _advancePqOwner Tests
/// @dev Tests for QuipPortal._advancePqOwner
contract QuipPortal__advancePqOwner is QuipPortalTest {
  // ============ Happy Paths ============

  function test_exposed_advancePqOwner_transitionsFromUnusedToFree() public {
    assertEq(uint256(portalHarness.pqOwnerState(defaultPqOwnerHash)), uint256(PqOwnerState.Unused));
    portalHarness.exposed_advancePqOwner(defaultPqOwnerHash);
    assertEq(uint256(portalHarness.pqOwnerState(defaultPqOwnerHash)), uint256(PqOwnerState.Free));
  }

  function test_exposed_advancePqOwner_transitionsFromFreeToSpent() public {
    // first call: Unused → Free
    portalHarness.exposed_advancePqOwner(defaultPqOwnerHash);
    assertEq(uint256(portalHarness.pqOwnerState(defaultPqOwnerHash)), uint256(PqOwnerState.Free));

    // second call: Free → Spent
    portalHarness.exposed_advancePqOwner(defaultPqOwnerHash);
    assertEq(uint256(portalHarness.pqOwnerState(defaultPqOwnerHash)), uint256(PqOwnerState.Spent));
  }

  function test_exposed_advancePqOwner_remainsSpentWhenAlreadySpent() public {
    // advance to Spent
    portalHarness.exposed_advancePqOwner(defaultPqOwnerHash); // Unused → Free
    portalHarness.exposed_advancePqOwner(defaultPqOwnerHash); // Free → Spent
    assertEq(uint256(portalHarness.pqOwnerState(defaultPqOwnerHash)), uint256(PqOwnerState.Spent));

    // third call: Spent → Spent (no change)
    portalHarness.exposed_advancePqOwner(defaultPqOwnerHash);
    assertEq(uint256(portalHarness.pqOwnerState(defaultPqOwnerHash)), uint256(PqOwnerState.Spent));
  }

  function testFuzz_exposed_advancePqOwner_transitionsFromUnusedToFree(bytes32 pqOwnerHash) public {
    vm.assume(pqOwnerHash != bytes32(0));
    assertEq(uint256(portalHarness.pqOwnerState(pqOwnerHash)), uint256(PqOwnerState.Unused));
    portalHarness.exposed_advancePqOwner(pqOwnerHash);
    assertEq(uint256(portalHarness.pqOwnerState(pqOwnerHash)), uint256(PqOwnerState.Free));
  }
}
