// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {TermsLib} from '../../../src/TermsLib.sol';
import {TermsLibTest} from '../TermsLib.t.sol';

/// @title TermsLib enforceTermStaleness Tests
/// @dev Tests for TermsLib.enforceTermStaleness
contract TermsLib_enforceTermStaleness is TermsLibTest {
  // ============ Success Cases ============

  function test_enforceTermStaleness_succeedsWhenExpired() public {
    // Warp to a future time so we can subtract 1 without underflow
    vm.warp(1 hours);
    uint64 pastExpiry = uint64(block.timestamp - 1);
    harness.exposed_enforceTermStaleness(pastExpiry);
  }

  function test_enforceTermStaleness_succeedsWhenLongExpired() public {
    // Warp to a future time so we can subtract 1 day without underflow
    vm.warp(2 days);
    uint64 longPastExpiry = uint64(block.timestamp - 1 days);
    harness.exposed_enforceTermStaleness(longPastExpiry);
  }

  function test_enforceTermStaleness_succeedsAtExactExpiry() public {
    // Warp to a future time for consistent testing
    vm.warp(1 hours);
    uint64 expiry = uint64(block.timestamp);
    harness.exposed_enforceTermStaleness(expiry);
  }

  function test_enforceTermStaleness_succeedsWithZeroExpiry() public view {
    harness.exposed_enforceTermStaleness(0);
  }

  // ============ Revert Cases ============

  function test_enforceTermStaleness_revertsWhen_notExpired() public {
    uint64 futureExpiry = uint64(block.timestamp + 1);
    vm.expectRevert(TermsLib.TermsNotExpired.selector);
    harness.exposed_enforceTermStaleness(futureExpiry);
  }

  function test_enforceTermStaleness_revertsWhen_farFutureExpiry() public {
    uint64 farFutureExpiry = uint64(block.timestamp + 1 days);
    vm.expectRevert(TermsLib.TermsNotExpired.selector);
    harness.exposed_enforceTermStaleness(farFutureExpiry);
  }

  function test_enforceTermStaleness_revertsWhen_maxExpiry() public {
    uint64 maxExpiry = type(uint64).max;
    vm.expectRevert(TermsLib.TermsNotExpired.selector);
    harness.exposed_enforceTermStaleness(maxExpiry);
  }

  // ============ Time-based Tests ============

  function test_enforceTermStaleness_becomesStaleAtExactTime() public {
    uint64 expiry = uint64(block.timestamp + 100);

    // Should fail before expiry
    vm.expectRevert(TermsLib.TermsNotExpired.selector);
    harness.exposed_enforceTermStaleness(expiry);

    // Move time to exactly expiry
    vm.warp(expiry);

    // Should succeed at exact expiry
    harness.exposed_enforceTermStaleness(expiry);
  }

  function test_enforceTermStaleness_becomesStaleAfterWarp() public {
    uint64 expiry = uint64(block.timestamp + 1 days);

    // Should fail now
    vm.expectRevert(TermsLib.TermsNotExpired.selector);
    harness.exposed_enforceTermStaleness(expiry);

    // Warp to expiry
    vm.warp(expiry);

    // Should succeed now
    harness.exposed_enforceTermStaleness(expiry);
  }

  // ============ Fuzz Tests ============

  function testFuzz_enforceTermStaleness_succeedsWhenStale(uint64 expiry) public {
    vm.assume(expiry <= block.timestamp);
    harness.exposed_enforceTermStaleness(expiry);
  }

  function testFuzz_enforceTermStaleness_revertsWhenFresh(uint64 delta) public {
    delta = uint64(bound(delta, 1, type(uint64).max - block.timestamp));
    uint64 expiry = uint64(block.timestamp) + delta;

    vm.expectRevert(TermsLib.TermsNotExpired.selector);
    harness.exposed_enforceTermStaleness(expiry);
  }
}
