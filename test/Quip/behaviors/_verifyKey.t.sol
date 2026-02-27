// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {IQuip} from '../../../src/interfaces/IQuip.sol';
import {QuipTest} from '../Quip.t.sol';

/// @title Quip _verifyKey Tests
/// @dev Tests for Quip._verifyKey
contract Quip__verifyKey is QuipTest {
  function setUp() public override {
    super.setUp();
    // Set lock on harness for testing
    quipHarness.setLock(defaultLock);
  }

  // ============ Success Cases ============

  function test_exposed_verifyKey_succeedsWithCorrectKey() public view {
    quipHarness.exposed_verifyKey(DEFAULT_KEY);
  }

  function test_exposed_verifyKey_succeedsWhen_lockIsHashOfEmptyKey() public {
    bytes32 emptyKeyHash = keccak256('');
    quipHarness.setLock(emptyKeyHash);
    quipHarness.exposed_verifyKey('');
  }

  // ============ Revert Cases ============

  function test_exposed_verifyKey_revertsWhen_keyInvalid() public {
    bytes memory wrongKey = 'wrong_key';

    vm.expectRevert(IQuip.InvalidKey.selector);
    quipHarness.exposed_verifyKey(wrongKey);
  }

  function test_exposed_verifyKey_revertsWhen_keyEmpty() public {
    vm.expectRevert(IQuip.InvalidKey.selector);
    quipHarness.exposed_verifyKey('');
  }

  function test_exposed_verifyKey_revertsWhen_keySimilar() public {
    bytes memory similarKey = 'secret_key_12346'; // Different last char

    vm.expectRevert(IQuip.InvalidKey.selector);
    quipHarness.exposed_verifyKey(similarKey);
  }

  // ============ Fuzz Tests ============

  function testFuzz_exposed_verifyKey_revertsWithWrongKey(bytes memory wrongKey) public {
    vm.assume(keccak256(wrongKey) != defaultLock);

    vm.expectRevert(IQuip.InvalidKey.selector);
    quipHarness.exposed_verifyKey(wrongKey);
  }

  function testFuzz_exposed_verifyKey_succeedsWithMatchingKey(bytes memory key) public {
    vm.assume(key.length > 0);
    bytes32 lock = keccak256(key);
    quipHarness.setLock(lock);

    quipHarness.exposed_verifyKey(key);
  }
}
