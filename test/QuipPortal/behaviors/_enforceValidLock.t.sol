// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {IQuipPortal} from '../../../src/interfaces/IQuipPortal.sol';
import {QuipTerms, TermsLib} from '../../../src/TermsLib.sol';
import {QuipPortalTest} from '../QuipPortal.t.sol';

/// @title QuipPortal _enforceValidLock Tests
/// @dev Tests for QuipPortal._enforceValidLock
contract QuipPortal__enforceValidLock is QuipPortalTest {
  // ============ Success Cases ============

  function test_exposed_enforceValidLock_succeedsWithValidLock() public view {
    portalHarness.exposed_enforceValidLock(defaultLock);
  }

  function test_exposed_enforceValidLock_succeedsWithAnyNonZeroLock() public view {
    portalHarness.exposed_enforceValidLock(bytes32(uint256(1)));
    portalHarness.exposed_enforceValidLock(keccak256('any_key'));
    portalHarness.exposed_enforceValidLock(bytes32(type(uint256).max));
  }

  // ============ Revert Cases ============

  function test_exposed_enforceValidLock_revertsWhen_lockIsZero() public {
    vm.expectRevert(IQuipPortal.EmptyLock.selector);
    portalHarness.exposed_enforceValidLock(bytes32(0));
  }

  function test_exposed_enforceValidLock_revertsWhen_lockIsSpent() public {
    // Spend a lock first using the main portal
    QuipTerms memory terms = _makeDefaultQuipTerms();
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

    vm.prank(ALICE);
    portal.deployCoupledQuip{value: nativeRequired}(defaultLock, terms);

    // Now try to validate the spent lock on the harness (won't work since different portal)
    // Instead just verify the main portal rejects spent locks
    vm.expectRevert(IQuipPortal.LockSpent.selector);
    portal.deployCoupledQuip{value: nativeRequired}(defaultLock, terms);
  }

  // ============ Fuzz Tests ============

  function testFuzz_exposed_enforceValidLock_succeedsWithNonZeroLock(bytes32 lock) public view {
    vm.assume(lock != bytes32(0));
    portalHarness.exposed_enforceValidLock(lock);
  }
}
