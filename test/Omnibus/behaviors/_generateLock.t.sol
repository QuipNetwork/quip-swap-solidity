// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {OmnibusTest} from '../Omnibus.t.sol';
import {EfficientHashLib} from 'solady-0.1.26/utils/EfficientHashLib.sol';

/// @title Omnibus _generateLock Tests
/// @dev Tests for Omnibus._generateLock
contract Omnibus__generateLock is OmnibusTest {
  // ============ Success Cases ============

  function test_generateLock_returnsHash() public view {
    bytes32 secret = keccak256('secret');
    bytes32 lock = omnibus.exposed_generateLock(secret);

    assertNotEq(lock, bytes32(0));
    assertNotEq(lock, secret);
  }

  function test_generateLock_differentSecretsDifferentLocks() public view {
    bytes32 secret1 = keccak256('secret1');
    bytes32 secret2 = keccak256('secret2');

    bytes32 lock1 = omnibus.exposed_generateLock(secret1);
    bytes32 lock2 = omnibus.exposed_generateLock(secret2);

    assertNotEq(lock1, lock2);
  }

  function test_generateLock_sameSecretSameLock() public view {
    bytes32 secret = keccak256('secret');

    bytes32 lock1 = omnibus.exposed_generateLock(secret);
    bytes32 lock2 = omnibus.exposed_generateLock(secret);

    assertEq(lock1, lock2);
  }

  function test_generateLock_matchesEfficientHashLib() public view {
    bytes32 secret = keccak256('test');
    bytes32 lock = omnibus.exposed_generateLock(secret);
    bytes32 expected = EfficientHashLib.hash(secret);

    assertEq(lock, expected);
  }

  function test_generateLock_zeroSecret() public view {
    bytes32 secret = bytes32(0);
    bytes32 lock = omnibus.exposed_generateLock(secret);

    // Should still produce a valid hash
    assertNotEq(lock, bytes32(0));
  }

  function test_generateLock_maxSecret() public view {
    bytes32 secret = bytes32(type(uint256).max);
    bytes32 lock = omnibus.exposed_generateLock(secret);

    assertNotEq(lock, bytes32(0));
    assertNotEq(lock, secret);
  }

  // ============ Fuzz Tests ============

  function testFuzz_generateLock_deterministic(bytes32 secret) public view {
    bytes32 lock1 = omnibus.exposed_generateLock(secret);
    bytes32 lock2 = omnibus.exposed_generateLock(secret);

    assertEq(lock1, lock2);
  }

  function testFuzz_generateLock_unique(bytes32 secret1, bytes32 secret2) public view {
    vm.assume(secret1 != secret2);

    bytes32 lock1 = omnibus.exposed_generateLock(secret1);
    bytes32 lock2 = omnibus.exposed_generateLock(secret2);

    assertNotEq(lock1, lock2);
  }

  function testFuzz_generateLock_matchesExpected(bytes32 secret) public view {
    bytes32 lock = omnibus.exposed_generateLock(secret);
    bytes32 expected = EfficientHashLib.hash(secret);

    assertEq(lock, expected);
  }

  function testFuzz_generateLock_notEqualToInput(bytes32 secret) public view {
    bytes32 lock = omnibus.exposed_generateLock(secret);

    if (secret != bytes32(0)) {
      assertNotEq(lock, secret);
    }
  }
}
