// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {IOmnibus} from '../../../src/interfaces/IOmnibus.sol';
import {OmnibusTest} from '../Omnibus.t.sol';

/// @title Omnibus _enforceSameTerms Tests
/// @dev Tests for Omnibus._enforceSameTerms (via harness)
contract Omnibus__enforceSameTerms is OmnibusTest {
  // ============ Success Cases ============

  function test_enforceSameTerms_succeedsWhenEqual() public view {
    bytes32 termsDigest = keccak256('test');
    omnibus.exposed_enforceSameTerms(termsDigest, termsDigest);
  }

  function test_enforceSameTerms_succeedsWithZeroHashes() public view {
    omnibus.exposed_enforceSameTerms(bytes32(0), bytes32(0));
  }

  function test_enforceSameTerms_succeedsWithMaxHashes() public view {
    bytes32 maxHash = bytes32(type(uint256).max);
    omnibus.exposed_enforceSameTerms(maxHash, maxHash);
  }

  // ============ Revert Cases ============

  function test_enforceSameTerms_revertsWhen_mismatch() public {
    bytes32 expected = keccak256('expected');
    bytes32 actual = keccak256('actual');

    vm.expectRevert(IOmnibus.TermsMismatch.selector);
    omnibus.exposed_enforceSameTerms(expected, actual);
  }

  function test_enforceSameTerms_revertsWhen_expectedZeroActualNonZero() public {
    bytes32 expected = bytes32(0);
    bytes32 actual = keccak256('actual');

    vm.expectRevert(IOmnibus.TermsMismatch.selector);
    omnibus.exposed_enforceSameTerms(expected, actual);
  }

  function test_enforceSameTerms_revertsWhen_expectedNonZeroActualZero() public {
    bytes32 expected = keccak256('expected');
    bytes32 actual = bytes32(0);

    vm.expectRevert(IOmnibus.TermsMismatch.selector);
    omnibus.exposed_enforceSameTerms(expected, actual);
  }

  // ============ Fuzz Tests ============

  function testFuzz_enforceSameTerms_succeedsWhenEqual(bytes32 termsDigest) public view {
    omnibus.exposed_enforceSameTerms(termsDigest, termsDigest);
  }

  function testFuzz_enforceSameTerms_revertsWhenDifferent(bytes32 expected, bytes32 actual) public {
    vm.assume(expected != actual);

    vm.expectRevert(IOmnibus.TermsMismatch.selector);
    omnibus.exposed_enforceSameTerms(expected, actual);
  }
}
