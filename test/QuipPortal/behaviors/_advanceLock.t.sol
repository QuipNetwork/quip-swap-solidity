// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {LockState} from '../../../src/interfaces/IQuipPortal.sol';
import {QuipPortalTest} from '../QuipPortal.t.sol';

/// @title QuipPortal _advanceLock Tests
/// @dev Tests for QuipPortal._advanceLock
contract QuipPortal__advanceLock is QuipPortalTest {
  // ============ Happy Paths ============

  function test_exposed_advanceLock_transitionsFromUnusedToFree() public {
    assertEq(uint256(portalHarness.lockState(defaultLock)), uint256(LockState.Unused));
    portalHarness.exposed_advanceLock(defaultLock);
    assertEq(uint256(portalHarness.lockState(defaultLock)), uint256(LockState.Free));
  }

  function test_exposed_advanceLock_transitionsFromFreeToSpent() public {
    // First call: Unused → Free
    portalHarness.exposed_advanceLock(defaultLock);
    assertEq(uint256(portalHarness.lockState(defaultLock)), uint256(LockState.Free));

    // Second call: Free → Spent
    portalHarness.exposed_advanceLock(defaultLock);
    assertEq(uint256(portalHarness.lockState(defaultLock)), uint256(LockState.Spent));
  }

  function test_exposed_advanceLock_remainsSpentWhenAlreadySpent() public {
    // Advance to Spent
    portalHarness.exposed_advanceLock(defaultLock); // Unused → Free
    portalHarness.exposed_advanceLock(defaultLock); // Free → Spent
    assertEq(uint256(portalHarness.lockState(defaultLock)), uint256(LockState.Spent));

    // Third call: Spent → Spent (no change)
    portalHarness.exposed_advanceLock(defaultLock);
    assertEq(uint256(portalHarness.lockState(defaultLock)), uint256(LockState.Spent));
  }

  function testFuzz_exposed_advanceLock_transitionsFromUnusedToFree(bytes32 lock) public {
    vm.assume(lock != bytes32(0));
    assertEq(uint256(portalHarness.lockState(lock)), uint256(LockState.Unused));
    portalHarness.exposed_advanceLock(lock);
    assertEq(uint256(portalHarness.lockState(lock)), uint256(LockState.Free));
  }
}
