// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {IOmnibus, LockState} from '../../../src/interfaces/IOmnibus.sol';
import {OmnibusTest} from '../Omnibus.t.sol';

/// @title Omnibus _advanceLockTo Tests
/// @dev Tests for Omnibus._advanceLockTo (via harness)
contract Omnibus__advanceLockTo is OmnibusTest {
  // ============ Valid Transitions ============

  function test_advanceLockTo_unusedToFree() public {
    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Unused));

    omnibus.exposed_advanceLockTo(lock, LockState.Unused, LockState.Free);

    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Free));
  }

  function test_advanceLockTo_unusedToCommitted() public {
    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Unused));

    omnibus.exposed_advanceLockTo(lock, LockState.Unused, LockState.Committed);

    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Committed));
  }

  function test_advanceLockTo_freeToCommitted() public {
    omnibus.setLockState(lock, LockState.Free);

    omnibus.exposed_advanceLockTo(lock, LockState.Free, LockState.Committed);

    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Committed));
  }

  function test_advanceLockTo_freeToSpent() public {
    omnibus.setLockState(lock, LockState.Free);

    omnibus.exposed_advanceLockTo(lock, LockState.Free, LockState.Spent);

    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Spent));
  }

  function test_advanceLockTo_committedToSpent() public {
    omnibus.setLockState(lock, LockState.Committed);

    omnibus.exposed_advanceLockTo(lock, LockState.Committed, LockState.Spent);

    assertEq(uint8(omnibus.lockState(lock)), uint8(LockState.Spent));
  }

  // ============ Invalid Transitions ============

  function test_advanceLockTo_revertsWhen_unusedToUnused() public {
    vm.expectRevert(IOmnibus.InvalidLockAdvancement.selector);
    omnibus.exposed_advanceLockTo(lock, LockState.Unused, LockState.Unused);
  }

  function test_advanceLockTo_revertsWhen_unusedToSpent() public {
    vm.expectRevert(IOmnibus.InvalidLockAdvancement.selector);
    omnibus.exposed_advanceLockTo(lock, LockState.Unused, LockState.Spent);
  }

  function test_advanceLockTo_revertsWhen_freeToUnused() public {
    omnibus.setLockState(lock, LockState.Free);

    vm.expectRevert(IOmnibus.InvalidLockAdvancement.selector);
    omnibus.exposed_advanceLockTo(lock, LockState.Free, LockState.Unused);
  }

  function test_advanceLockTo_revertsWhen_freeToFree() public {
    omnibus.setLockState(lock, LockState.Free);

    vm.expectRevert(IOmnibus.InvalidLockAdvancement.selector);
    omnibus.exposed_advanceLockTo(lock, LockState.Free, LockState.Free);
  }

  function test_advanceLockTo_revertsWhen_committedToUnused() public {
    omnibus.setLockState(lock, LockState.Committed);

    vm.expectRevert(IOmnibus.InvalidLockAdvancement.selector);
    omnibus.exposed_advanceLockTo(lock, LockState.Committed, LockState.Unused);
  }

  function test_advanceLockTo_revertsWhen_committedToFree() public {
    omnibus.setLockState(lock, LockState.Committed);

    vm.expectRevert(IOmnibus.InvalidLockAdvancement.selector);
    omnibus.exposed_advanceLockTo(lock, LockState.Committed, LockState.Free);
  }

  function test_advanceLockTo_revertsWhen_committedToCommitted() public {
    omnibus.setLockState(lock, LockState.Committed);

    vm.expectRevert(IOmnibus.InvalidLockAdvancement.selector);
    omnibus.exposed_advanceLockTo(lock, LockState.Committed, LockState.Committed);
  }

  function test_advanceLockTo_revertsWhen_spentToUnused() public {
    omnibus.setLockState(lock, LockState.Spent);

    vm.expectRevert(IOmnibus.InvalidLockAdvancement.selector);
    omnibus.exposed_advanceLockTo(lock, LockState.Spent, LockState.Unused);
  }

  function test_advanceLockTo_revertsWhen_spentToFree() public {
    omnibus.setLockState(lock, LockState.Spent);

    vm.expectRevert(IOmnibus.InvalidLockAdvancement.selector);
    omnibus.exposed_advanceLockTo(lock, LockState.Spent, LockState.Free);
  }

  function test_advanceLockTo_revertsWhen_spentToCommitted() public {
    omnibus.setLockState(lock, LockState.Spent);

    vm.expectRevert(IOmnibus.InvalidLockAdvancement.selector);
    omnibus.exposed_advanceLockTo(lock, LockState.Spent, LockState.Committed);
  }

  function test_advanceLockTo_revertsWhen_spentToSpent() public {
    omnibus.setLockState(lock, LockState.Spent);

    vm.expectRevert(IOmnibus.InvalidLockAdvancement.selector);
    omnibus.exposed_advanceLockTo(lock, LockState.Spent, LockState.Spent);
  }
}
