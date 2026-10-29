// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {IOmnibus} from '../../../src/interfaces/IOmnibus.sol';
import {OmnibusTest} from '../Omnibus.t.sol';

/// @title Omnibus _enforceCorrectNative Tests
/// @dev Tests for Omnibus._enforceCorrectNative (via harness)
contract Omnibus__enforceCorrectNative is OmnibusTest {
  // ============ Success Cases ============

  function test_enforceCorrectNative_succeedsWhenEqual() public {
    omnibus.exposed_enforceCorrectNative{value: 1 ether}(1 ether);
  }

  function test_enforceCorrectNative_succeedsWithZero() public {
    omnibus.exposed_enforceCorrectNative{value: 0}(0);
  }

  function test_enforceCorrectNative_succeedsWithLargeAmount() public {
    uint256 largeAmount = 50 ether;
    omnibus.exposed_enforceCorrectNative{value: largeAmount}(largeAmount);
  }

  // ============ Revert Cases ============

  function test_enforceCorrectNative_revertsWhen_tooLittle() public {
    vm.expectRevert(IOmnibus.IncorrectNativeAmountReceived.selector);
    omnibus.exposed_enforceCorrectNative{value: 0.5 ether}(1 ether);
  }

  function test_enforceCorrectNative_revertsWhen_tooMuch() public {
    vm.expectRevert(IOmnibus.IncorrectNativeAmountReceived.selector);
    omnibus.exposed_enforceCorrectNative{value: 2 ether}(1 ether);
  }

  function test_enforceCorrectNative_revertsWhen_zeroExpectedNonZeroSent() public {
    vm.expectRevert(IOmnibus.IncorrectNativeAmountReceived.selector);
    omnibus.exposed_enforceCorrectNative{value: 1 wei}(0);
  }

  function test_enforceCorrectNative_revertsWhen_nonZeroExpectedZeroSent() public {
    vm.expectRevert(IOmnibus.IncorrectNativeAmountReceived.selector);
    omnibus.exposed_enforceCorrectNative{value: 0}(1 ether);
  }

  // ============ Fuzz Tests ============

  function testFuzz_enforceCorrectNative_succeedsWhenEqual(uint256 amount) public {
    amount = bound(amount, 0, address(this).balance);

    omnibus.exposed_enforceCorrectNative{value: amount}(amount);
  }

  function testFuzz_enforceCorrectNative_revertsWhenTooLittle(uint256 expected, uint256 sent) public {
    expected = bound(expected, 1, 50 ether);
    sent = bound(sent, 0, expected - 1);

    vm.expectRevert(IOmnibus.IncorrectNativeAmountReceived.selector);
    omnibus.exposed_enforceCorrectNative{value: sent}(expected);
  }

  function testFuzz_enforceCorrectNative_revertsWhenTooMuch(uint256 expected, uint256 extra) public {
    expected = bound(expected, 0, 25 ether);
    extra = bound(extra, 1, 25 ether);
    uint256 sent = expected + extra;

    vm.expectRevert(IOmnibus.IncorrectNativeAmountReceived.selector);
    omnibus.exposed_enforceCorrectNative{value: sent}(expected);
  }
}
