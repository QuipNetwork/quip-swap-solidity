// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {IQuipPortal, LockState} from '../../../src/interfaces/IQuipPortal.sol';
import {QuipPortalTest} from '../QuipPortal.t.sol';

/// @title QuipPortal _enforceValidLock Tests
/// @dev Tests for QuipPortal._enforceValidLock
contract QuipPortal__enforceValidLock is QuipPortalTest {
  // ============ Success Cases ============

  function test_exposed_enforceValidLock_succeedsForUnusedLock() public view {
    // Should not revert for unused lock
    portalHarness.exposed_enforceValidLock(defaultLock);
  }

  function test_exposed_enforceValidLock_succeedsForFreeLock() public {
    // Advance to Free state
    portalHarness.exposed_advanceLock(defaultLock);
    assertEq(uint256(portalHarness.lockState(defaultLock)), uint256(LockState.Free));

    // Should not revert for Free lock
    portalHarness.exposed_enforceValidLock(defaultLock);
  }

  function test_exposed_enforceValidLock_doesNotMutateState() public {
    assertEq(uint256(portalHarness.lockState(defaultLock)), uint256(LockState.Unused));
    portalHarness.exposed_enforceValidLock(defaultLock);
    // State should remain Unused (enforce is view-only)
    assertEq(uint256(portalHarness.lockState(defaultLock)), uint256(LockState.Unused));
  }

  // ============ Revert Cases ============

  function test_exposed_enforceValidLock_revertsWhen_lockIsZero() public {
    vm.expectRevert(IQuipPortal.EmptyLock.selector);
    portalHarness.exposed_enforceValidLock(bytes32(0));
  }

  function test_exposed_enforceValidLock_revertsWhen_lockIsSpent() public {
    // Advance to Spent state
    portalHarness.exposed_advanceLock(defaultLock); // Unused → Free
    portalHarness.exposed_advanceLock(defaultLock); // Free → Spent

    vm.expectRevert(IQuipPortal.LockSpent.selector);
    portalHarness.exposed_enforceValidLock(defaultLock);
  }

  // ============ Fuzz Tests ============

  function testFuzz_exposed_enforceValidLock_succeedsForAnyNonZeroUnusedLock(bytes32 lock) public view {
    vm.assume(lock != bytes32(0));
    // Should not revert
    portalHarness.exposed_enforceValidLock(lock);
  }
}
