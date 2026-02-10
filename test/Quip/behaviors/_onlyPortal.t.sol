// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {IQuip} from '../../../src/interfaces/IQuip.sol';
import {QuipTest} from '../Quip.t.sol';

/// @title Quip _onlyPortal Tests
/// @dev Tests for Quip._onlyPortal modifier
///      Note: Testing _onlyPortal requires a properly deployed clone since PORTAL_FROM_BYTECODE()
///      reads the portal address from the clone's bytecode. We test via initializeCoupled which
///      uses the onlyPortal modifier.
contract Quip__onlyPortal is QuipTest {
  // ============ Success Cases ============

  function test_exposed_onlyPortal_succeedsWhen_calledByPortal() public {
    // The onlyPortal modifier succeeds when called by the portal during initialization
    // This is implicitly tested by deployedQuip being successfully initialized
    // We can verify by checking the quip is properly set up
    assertEq(deployedQuip.PORTAL_FROM_BYTECODE(), address(portal));
    assertEq(deployedQuip.lock(), defaultLock);
  }

  // ============ Revert Cases ============

  function test_exposed_onlyPortal_revertsWhen_calledByNonPortal() public {
    // Calling a function protected by onlyPortal from a non-portal address reverts
    vm.expectRevert(IQuip.CallerNotPortal.selector);
    deployedQuip.initializeCoupled(bytes32(uint256(1)), bytes32(uint256(2)));
  }

  // ============ Fuzz Tests ============

  function testFuzz_exposed_onlyPortal_revertsWhen_calledByRandomAddress(address caller) public {
    vm.assume(caller != address(portal));
    vm.assume(caller != address(0));

    vm.prank(caller);
    vm.expectRevert(IQuip.CallerNotPortal.selector);
    deployedQuip.initializeCoupled(bytes32(uint256(1)), bytes32(uint256(2)));
  }
}
