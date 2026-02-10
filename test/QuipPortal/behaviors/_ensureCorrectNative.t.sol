// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {IQuipPortal} from '../../../src/interfaces/IQuipPortal.sol';
import {QuipPortalTest} from '../QuipPortal.t.sol';

/// @title QuipPortal _ensureCorrectNative Tests
/// @dev Tests for QuipPortal._ensureCorrectNative
contract QuipPortal__ensureCorrectNative is QuipPortalTest {
  // ============ Success Cases ============

  function test_exposed_ensureCorrectNative_succeedsWhenAmountsMatch() public {
    portalHarness.exposed_ensureCorrectNative{value: 1 ether}(1 ether);
  }

  function test_exposed_ensureCorrectNative_succeedsWithZero() public {
    portalHarness.exposed_ensureCorrectNative(0);
  }

  // ============ Revert Cases ============

  function test_exposed_ensureCorrectNative_revertsWhen_valueTooLow() public {
    vm.expectRevert(IQuipPortal.IncorrectNativeAmount.selector);
    portalHarness.exposed_ensureCorrectNative{value: 0.5 ether}(1 ether);
  }

  function test_exposed_ensureCorrectNative_revertsWhen_valueTooHigh() public {
    vm.expectRevert(IQuipPortal.IncorrectNativeAmount.selector);
    portalHarness.exposed_ensureCorrectNative{value: 1.5 ether}(1 ether);
  }

  function test_exposed_ensureCorrectNative_revertsWhen_valueIsZeroButExpected() public {
    vm.expectRevert(IQuipPortal.IncorrectNativeAmount.selector);
    portalHarness.exposed_ensureCorrectNative(1 ether);
  }

  // ============ Fuzz Tests ============

  function testFuzz_exposed_ensureCorrectNative_succeedsWithMatchingAmounts(uint256 amount) public {
    amount = bound(amount, 0, 100 ether);
    vm.deal(address(this), amount);

    portalHarness.exposed_ensureCorrectNative{value: amount}(amount);
  }

  function testFuzz_exposed_ensureCorrectNative_revertsWhen_mismatch(uint256 sent, uint256 expected) public {
    sent = bound(sent, 0, 100 ether);
    expected = bound(expected, 0, 100 ether);
    vm.assume(sent != expected);
    vm.deal(address(this), sent);

    vm.expectRevert(IQuipPortal.IncorrectNativeAmount.selector);
    portalHarness.exposed_ensureCorrectNative{value: sent}(expected);
  }
}
