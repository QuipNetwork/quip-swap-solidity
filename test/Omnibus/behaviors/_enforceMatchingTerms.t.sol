// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {IOmnibus} from '../../../src/interfaces/IOmnibus.sol';
import {OmnibusTest} from '../Omnibus.t.sol';

/// @title Omnibus _enforceMatchingTerms Tests
/// @dev Tests for Omnibus._enforceMatchingTerms (via harness)
contract Omnibus__enforceMatchingTerms is OmnibusTest {
  // ============ Success Cases ============

  function test_enforceMatchingTerms_succeedsWhenEqual() public view {
    bytes32 hash = keccak256('test');
    omnibus.exposed_enforceMatchingTerms(hash, hash);
  }

  function test_enforceMatchingTerms_succeedsWithZeroHashes() public view {
    omnibus.exposed_enforceMatchingTerms(bytes32(0), bytes32(0));
  }

  function test_enforceMatchingTerms_succeedsWithMaxHashes() public view {
    bytes32 maxHash = bytes32(type(uint256).max);
    omnibus.exposed_enforceMatchingTerms(maxHash, maxHash);
  }

  // ============ Revert Cases ============

  function test_enforceMatchingTerms_revertsWhen_mismatch() public {
    bytes32 expected = keccak256('expected');
    bytes32 actual = keccak256('actual');

    vm.expectRevert(IOmnibus.TermsMismatch.selector);
    omnibus.exposed_enforceMatchingTerms(expected, actual);
  }

  function test_enforceMatchingTerms_revertsWhen_expectedZeroActualNonZero() public {
    bytes32 expected = bytes32(0);
    bytes32 actual = keccak256('actual');

    vm.expectRevert(IOmnibus.TermsMismatch.selector);
    omnibus.exposed_enforceMatchingTerms(expected, actual);
  }

  function test_enforceMatchingTerms_revertsWhen_expectedNonZeroActualZero() public {
    bytes32 expected = keccak256('expected');
    bytes32 actual = bytes32(0);

    vm.expectRevert(IOmnibus.TermsMismatch.selector);
    omnibus.exposed_enforceMatchingTerms(expected, actual);
  }

  // ============ Fuzz Tests ============

  function testFuzz_enforceMatchingTerms_succeedsWhenEqual(bytes32 hash) public view {
    omnibus.exposed_enforceMatchingTerms(hash, hash);
  }

  function testFuzz_enforceMatchingTerms_revertsWhenDifferent(bytes32 expected, bytes32 actual) public {
    vm.assume(expected != actual);

    vm.expectRevert(IOmnibus.TermsMismatch.selector);
    omnibus.exposed_enforceMatchingTerms(expected, actual);
  }
}
