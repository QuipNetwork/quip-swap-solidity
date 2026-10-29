// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {IOmnibus, LockState} from '../../../src/interfaces/IOmnibus.sol';
import {OmnibusTest} from '../Omnibus.t.sol';

/// @title Omnibus _enforceCommittedLock Tests
/// @dev Tests for Omnibus._enforceCommittedLock (via harness)
contract Omnibus__enforceCommittedLock is OmnibusTest {
  // ============ Success Cases ============

  function test_enforceCommittedLock_succeedsWhenCommitted() public view {
    omnibus.exposed_enforceCommittedLock(LockState.Committed);
  }

  // ============ Revert Cases ============

  function test_enforceCommittedLock_revertsWhen_unused() public {
    vm.expectRevert(IOmnibus.InvalidLockState.selector);
    omnibus.exposed_enforceCommittedLock(LockState.Unused);
  }

  function test_enforceCommittedLock_revertsWhen_free() public {
    vm.expectRevert(IOmnibus.InvalidLockState.selector);
    omnibus.exposed_enforceCommittedLock(LockState.Free);
  }

  function test_enforceCommittedLock_revertsWhen_spent() public {
    vm.expectRevert(IOmnibus.InvalidLockState.selector);
    omnibus.exposed_enforceCommittedLock(LockState.Spent);
  }
}
