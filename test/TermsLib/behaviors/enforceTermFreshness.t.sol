// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {TermsLib} from '../../../src/TermsLib.sol';
import {TermsLibTest} from '../TermsLib.t.sol';

/// @title TermsLib enforceTermFreshness Tests
/// @dev Tests for TermsLib.enforceTermFreshness
contract TermsLib_enforceTermFreshness is TermsLibTest {
  // ============ Success Cases ============

  function test_enforceTermFreshness_succeedsWhenNotExpired() public view {
    uint64 futureExpiry = uint64(block.timestamp + 1 days);
    harness.exposed_enforceTermFreshness(futureExpiry);
  }

  function test_enforceTermFreshness_succeedsWithFarFutureExpiry() public view {
    uint64 farFutureExpiry = type(uint64).max;
    harness.exposed_enforceTermFreshness(farFutureExpiry);
  }

  function test_enforceTermFreshness_succeedsOneSecondBeforeExpiry() public view {
    uint64 expiry = uint64(block.timestamp + 1);
    harness.exposed_enforceTermFreshness(expiry);
  }

  // ============ Revert Cases ============

  function test_enforceTermFreshness_revertsWhen_expiryEqualsTimestamp() public {
    uint64 expiry = uint64(block.timestamp);
    vm.expectRevert(TermsLib.TermsExpired.selector);
    harness.exposed_enforceTermFreshness(expiry);
  }

  function test_enforceTermFreshness_revertsWhen_expired() public {
    uint64 pastExpiry = uint64(block.timestamp - 1);
    vm.expectRevert(TermsLib.TermsExpired.selector);
    harness.exposed_enforceTermFreshness(pastExpiry);
  }

  function test_enforceTermFreshness_revertsWhen_longExpired() public {
    // Warp to a future time so we can subtract 1 day without underflow
    vm.warp(2 days);
    uint64 longPastExpiry = uint64(block.timestamp - 1 days);
    vm.expectRevert(TermsLib.TermsExpired.selector);
    harness.exposed_enforceTermFreshness(longPastExpiry);
  }

  function test_enforceTermFreshness_revertsWhen_zeroExpiry() public {
    vm.expectRevert(TermsLib.TermsExpired.selector);
    harness.exposed_enforceTermFreshness(0);
  }

  // ============ Time-based Tests ============

  function test_enforceTermFreshness_expiresAtExactTime() public {
    uint64 expiry = uint64(block.timestamp + 100);

    // Should succeed before expiry
    harness.exposed_enforceTermFreshness(expiry);

    // Move time to exactly expiry
    vm.warp(expiry);

    // Should fail at exact expiry
    vm.expectRevert(TermsLib.TermsExpired.selector);
    harness.exposed_enforceTermFreshness(expiry);
  }

  function test_enforceTermFreshness_expiresAfterWarp() public {
    uint64 expiry = uint64(block.timestamp + 1 days);

    // Should succeed now
    harness.exposed_enforceTermFreshness(expiry);

    // Warp past expiry
    vm.warp(expiry + 1);

    // Should fail now
    vm.expectRevert(TermsLib.TermsExpired.selector);
    harness.exposed_enforceTermFreshness(expiry);
  }

  // ============ Fuzz Tests ============

  function testFuzz_enforceTermFreshness_succeedsWhenFresh(uint64 delta) public view {
    delta = uint64(bound(delta, 1, type(uint64).max - block.timestamp));
    uint64 expiry = uint64(block.timestamp) + delta;

    harness.exposed_enforceTermFreshness(expiry);
  }

  function testFuzz_enforceTermFreshness_revertsWhenStale(uint64 expiry) public {
    vm.assume(expiry <= block.timestamp);

    vm.expectRevert(TermsLib.TermsExpired.selector);
    harness.exposed_enforceTermFreshness(expiry);
  }
}
