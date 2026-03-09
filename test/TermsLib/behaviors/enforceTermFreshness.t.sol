// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Asset, Terms, TermsLib} from '../../../src/TermsLib.sol';
import {TermsLibTest} from '../TermsLib.t.sol';
import {AssetHelper} from '../../utils/AssetHelper.sol';

/// @title TermsLib enforceTermFreshness Tests
/// @dev Tests for TermsLib.enforceTermFreshness
contract TermsLib_enforceTermFreshness is TermsLibTest {
  using AssetHelper for *;
  // ============ Helpers ============

  function _makeTermsWithDeadline(uint64 deadline) internal view returns (Terms memory) {
    return Terms({
      chainId: block.chainid,
      signatory: ALICE,
      recipient: ALICE_RECIPIENT,
      deadline: deadline,
      collateral: _makeNativeAsset(0.1 ether),
      assets: _makeNativeAsset(1 ether).toArray()
    });
  }

  // ============ Success Cases ============

  function test_enforceTermFreshness_succeedsWhenNotExpired() public view {
    Terms memory terms = _makeTermsWithDeadline(uint64(block.timestamp + 1 days));
    harness.exposed_enforceTermFreshness(terms);
  }

  function test_enforceTermFreshness_succeedsWithFarFutureDeadline() public view {
    Terms memory terms = _makeTermsWithDeadline(type(uint64).max);
    harness.exposed_enforceTermFreshness(terms);
  }

  function test_enforceTermFreshness_succeedsOneSecondBeforeDeadline() public view {
    Terms memory terms = _makeTermsWithDeadline(uint64(block.timestamp + 1));
    harness.exposed_enforceTermFreshness(terms);
  }

  // ============ Revert Cases ============

  function test_enforceTermFreshness_revertsWhen_deadlineEqualsTimestamp() public {
    Terms memory terms = _makeTermsWithDeadline(uint64(block.timestamp));
    vm.expectRevert(TermsLib.TermsExpired.selector);
    harness.exposed_enforceTermFreshness(terms);
  }

  function test_enforceTermFreshness_revertsWhen_expired() public {
    Terms memory terms = _makeTermsWithDeadline(uint64(block.timestamp - 1));
    vm.expectRevert(TermsLib.TermsExpired.selector);
    harness.exposed_enforceTermFreshness(terms);
  }

  function test_enforceTermFreshness_revertsWhen_longExpired() public {
    // warp to a future time so we can subtract 1 day without underflow
    vm.warp(2 days);
    Terms memory terms = _makeTermsWithDeadline(uint64(block.timestamp - 1 days));
    vm.expectRevert(TermsLib.TermsExpired.selector);
    harness.exposed_enforceTermFreshness(terms);
  }

  function test_enforceTermFreshness_revertsWhen_zeroDeadline() public {
    Terms memory terms = _makeTermsWithDeadline(0);
    vm.expectRevert(TermsLib.TermsExpired.selector);
    harness.exposed_enforceTermFreshness(terms);
  }

  // ============ Time-based Tests ============

  function test_enforceTermFreshness_expiresAtExactTime() public {
    uint64 deadline = uint64(block.timestamp + 100);
    Terms memory terms = _makeTermsWithDeadline(deadline);

    // should succeed before deadline
    harness.exposed_enforceTermFreshness(terms);

    // move time to exactly deadline
    vm.warp(deadline);

    // should fail at exact deadline
    vm.expectRevert(TermsLib.TermsExpired.selector);
    harness.exposed_enforceTermFreshness(terms);
  }

  function test_enforceTermFreshness_expiresAfterWarp() public {
    uint64 deadline = uint64(block.timestamp + 1 days);
    Terms memory terms = _makeTermsWithDeadline(deadline);

    // should succeed now
    harness.exposed_enforceTermFreshness(terms);

    // warp past deadline
    vm.warp(deadline + 1);

    // should fail now
    vm.expectRevert(TermsLib.TermsExpired.selector);
    harness.exposed_enforceTermFreshness(terms);
  }

  // ============ Fuzz Tests ============

  function testFuzz_enforceTermFreshness_succeedsWhenFresh(uint64 delta) public view {
    delta = uint64(bound(delta, 1, type(uint64).max - block.timestamp));
    uint64 deadline = uint64(block.timestamp) + delta;
    Terms memory terms = _makeTermsWithDeadline(deadline);

    harness.exposed_enforceTermFreshness(terms);
  }

  function testFuzz_enforceTermFreshness_revertsWhenStale(uint64 deadline) public {
    vm.assume(deadline <= block.timestamp);
    Terms memory terms = _makeTermsWithDeadline(deadline);

    vm.expectRevert(TermsLib.TermsExpired.selector);
    harness.exposed_enforceTermFreshness(terms);
  }
}
