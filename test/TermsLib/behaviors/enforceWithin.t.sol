// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {TermsLib} from '../../../src/TermsLib.sol';
import {TermsLibTest} from '../TermsLib.t.sol';

/// @title TermsLib enforceWithin Tests
/// @dev Tests for TermsLib.enforceWithin — the half-open window primitive [lower, upper).
///      Lower bound is INCLUSIVE, upper bound is EXCLUSIVE. These boundary semantics are
///      the protocol's "one action per window" invariant; the tests pin them exactly.
contract TermsLib_enforceWithin is TermsLibTest {
  uint256 constant LOWER = 1000;
  uint256 constant UPPER = 2000;

  // ============ Success Cases ============

  function test_enforceWithin_succeedsAtLowerBound() public view {
    // lower is INCLUSIVE
    harness.exposed_enforceWithin(LOWER, UPPER, LOWER);
  }

  function test_enforceWithin_succeedsStrictlyInside() public view {
    harness.exposed_enforceWithin(LOWER, UPPER, 1500);
  }

  function test_enforceWithin_succeedsAtLastValidInstant() public view {
    // upper is EXCLUSIVE, so upper - 1 is the last accepted timestamp
    harness.exposed_enforceWithin(LOWER, UPPER, UPPER - 1);
  }

  function test_enforceWithin_succeedsForSingleInstantWindow() public view {
    // [t, t+1) accepts exactly t
    harness.exposed_enforceWithin(LOWER, LOWER + 1, LOWER);
  }

  // ============ Revert Cases: WindowViolated ============

  /// @dev REGRESSION GUARD: upper is exclusive. If `upper <= timestamp` were relaxed to
  ///      `<`, the shared boundary instant would be accepted by two adjacent windows,
  ///      breaking the one-action-per-window invariant. This test must stay red on that change.
  function test_enforceWithin_revertsWhen_atUpperBound() public {
    vm.expectRevert(TermsLib.WindowViolated.selector);
    harness.exposed_enforceWithin(LOWER, UPPER, UPPER);
  }

  function test_enforceWithin_revertsWhen_belowLowerBound() public {
    vm.expectRevert(TermsLib.WindowViolated.selector);
    harness.exposed_enforceWithin(LOWER, UPPER, LOWER - 1);
  }

  function test_enforceWithin_revertsWhen_aboveUpperBound() public {
    vm.expectRevert(TermsLib.WindowViolated.selector);
    harness.exposed_enforceWithin(LOWER, UPPER, UPPER + 1);
  }

  function test_enforceWithin_revertsWhen_singleInstantWindowAtUpper() public {
    // [t, t+1) rejects t+1
    vm.expectRevert(TermsLib.WindowViolated.selector);
    harness.exposed_enforceWithin(LOWER, LOWER + 1, LOWER + 1);
  }

  // ============ Revert Cases: InvalidRange ============

  function test_enforceWithin_revertsWhen_lowerEqualsUpper() public {
    // degenerate (empty) window: lower >= upper checked before the timestamp test,
    // so it reverts InvalidRange even when timestamp equals the bound
    vm.expectRevert(TermsLib.InvalidRange.selector);
    harness.exposed_enforceWithin(LOWER, LOWER, LOWER);
  }

  function test_enforceWithin_revertsWhen_lowerGreaterThanUpper() public {
    vm.expectRevert(TermsLib.InvalidRange.selector);
    harness.exposed_enforceWithin(UPPER, LOWER, 1500);
  }

  function test_enforceWithin_revertsWhen_bothZero() public {
    vm.expectRevert(TermsLib.InvalidRange.selector);
    harness.exposed_enforceWithin(0, 0, 0);
  }

  // ============ Fuzz Tests ============

  function testFuzz_enforceWithin_succeedsInside(uint256 lower, uint256 upper, uint256 timestamp) public view {
    lower = bound(lower, 0, type(uint256).max - 1);
    upper = bound(upper, lower + 1, type(uint256).max);
    timestamp = bound(timestamp, lower, upper - 1); // [lower, upper)
    harness.exposed_enforceWithin(lower, upper, timestamp);
  }

  function testFuzz_enforceWithin_revertsBelow(uint256 lower, uint256 upper, uint256 timestamp) public {
    lower = bound(lower, 1, type(uint256).max - 1);
    upper = bound(upper, lower + 1, type(uint256).max);
    timestamp = bound(timestamp, 0, lower - 1); // strictly below lower
    vm.expectRevert(TermsLib.WindowViolated.selector);
    harness.exposed_enforceWithin(lower, upper, timestamp);
  }

  function testFuzz_enforceWithin_revertsAtOrAboveUpper(uint256 lower, uint256 upper, uint256 timestamp) public {
    lower = bound(lower, 0, type(uint256).max - 1);
    upper = bound(upper, lower + 1, type(uint256).max);
    timestamp = bound(timestamp, upper, type(uint256).max); // at/above upper (exclusive)
    vm.expectRevert(TermsLib.WindowViolated.selector);
    harness.exposed_enforceWithin(lower, upper, timestamp);
  }

  function testFuzz_enforceWithin_revertsDegenerateRange(uint256 lower, uint256 upper, uint256 timestamp) public {
    // lower >= upper is always InvalidRange regardless of timestamp
    upper = bound(upper, 0, type(uint256).max);
    lower = bound(lower, upper, type(uint256).max);
    vm.expectRevert(TermsLib.InvalidRange.selector);
    harness.exposed_enforceWithin(lower, upper, timestamp);
  }
}
