// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Terms, TermsLib} from '../../../src/TermsLib.sol';
import {TermsLibTest} from '../TermsLib.t.sol';
import {AssetHelper} from '../../utils/AssetHelper.sol';
import {TermsHelper} from '../../utils/TermsHelper.sol';

/// @title TermsLib enforceTermStaleness Tests
/// @dev Tests for TermsLib.enforceTermStaleness
contract TermsLib_enforceTermStaleness is TermsLibTest {
  using AssetHelper for *;
  using TermsHelper for *;

  /// @notice Creates terms with specified deadline
  function _makeTermsWithDeadline(uint64 deadline) internal view returns (Terms memory) {
    return TermsHelper.makeTerms(
      block.chainid,
      ALICE,
      ALICE_RECIPIENT,
      deadline,
      _makeNativeAsset(1 ether).toArray()
    );
  }

  // ============ Success Cases ============

  function test_enforceTermStaleness_succeedsWhenExpired() public {
    vm.warp(1 hours);
    Terms memory terms = _makeTermsWithDeadline(uint64(block.timestamp - 1));
    harness.exposed_enforceTermStaleness(terms);
  }

  function test_enforceTermStaleness_succeedsWhenLongExpired() public {
    vm.warp(2 days);
    Terms memory terms = _makeTermsWithDeadline(uint64(block.timestamp - 1 days));
    harness.exposed_enforceTermStaleness(terms);
  }

  function test_enforceTermStaleness_succeedsAtExactExpiry() public {
    vm.warp(1 hours);
    Terms memory terms = _makeTermsWithDeadline(uint64(block.timestamp));
    harness.exposed_enforceTermStaleness(terms);
  }

  function test_enforceTermStaleness_succeedsWithZeroExpiry() public view {
    Terms memory terms = _makeTermsWithDeadline(0);
    harness.exposed_enforceTermStaleness(terms);
  }

  // ============ Revert Cases ============

  function test_enforceTermStaleness_revertsWhen_notExpired() public {
    Terms memory terms = _makeTermsWithDeadline(uint64(block.timestamp + 1));
    vm.expectRevert(TermsLib.TermsNotExpired.selector);
    harness.exposed_enforceTermStaleness(terms);
  }

  function test_enforceTermStaleness_revertsWhen_farFutureExpiry() public {
    Terms memory terms = _makeTermsWithDeadline(uint64(block.timestamp + 1 days));
    vm.expectRevert(TermsLib.TermsNotExpired.selector);
    harness.exposed_enforceTermStaleness(terms);
  }

  function test_enforceTermStaleness_revertsWhen_maxExpiry() public {
    Terms memory terms = _makeTermsWithDeadline(type(uint64).max);
    vm.expectRevert(TermsLib.TermsNotExpired.selector);
    harness.exposed_enforceTermStaleness(terms);
  }

  // ============ Time-based Tests ============

  function test_enforceTermStaleness_becomesStaleAtExactTime() public {
    uint64 deadline = uint64(block.timestamp + 100);
    Terms memory terms = _makeTermsWithDeadline(deadline);

    // Should fail before expiry
    vm.expectRevert(TermsLib.TermsNotExpired.selector);
    harness.exposed_enforceTermStaleness(terms);

    // Move time to exactly expiry
    vm.warp(deadline);

    // Should succeed at exact expiry
    harness.exposed_enforceTermStaleness(terms);
  }

  function test_enforceTermStaleness_becomesStaleAfterWarp() public {
    uint64 deadline = uint64(block.timestamp + 1 days);
    Terms memory terms = _makeTermsWithDeadline(deadline);

    // Should fail now
    vm.expectRevert(TermsLib.TermsNotExpired.selector);
    harness.exposed_enforceTermStaleness(terms);

    // Warp to expiry
    vm.warp(deadline);

    // Should succeed now
    harness.exposed_enforceTermStaleness(terms);
  }

  // ============ Fuzz Tests ============

  function testFuzz_enforceTermStaleness_succeedsWhenStale(uint64 deadline) public view {
    vm.assume(deadline <= block.timestamp);
    Terms memory terms = _makeTermsWithDeadline(deadline);
    harness.exposed_enforceTermStaleness(terms);
  }

  function testFuzz_enforceTermStaleness_revertsWhenFresh(uint64 delta) public {
    delta = uint64(bound(delta, 1, type(uint64).max - block.timestamp));
    uint64 deadline = uint64(block.timestamp) + delta;
    Terms memory terms = _makeTermsWithDeadline(deadline);

    vm.expectRevert(TermsLib.TermsNotExpired.selector);
    harness.exposed_enforceTermStaleness(terms);
  }
}
