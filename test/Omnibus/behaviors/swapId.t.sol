// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Terms} from '../../../src/TermsLib.sol';
import {OmnibusTest} from '../Omnibus.t.sol';

/// @title Omnibus swapId Tests
/// @dev Tests for the public swapId view: the key all swap state is stored under
contract Omnibus_swapId is OmnibusTest {
  function test_swapId_matchesKeccakOfLockAndCanonicalDigest() public view {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    bytes32 expected = keccak256(abi.encodePacked(lock, omnibus.computeTermsHash(alice, bob)));
    assertEq(omnibus.swapId(lock, alice, bob), expected);
  }

  function test_swapId_matchesInternalDerivation() public view {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    assertEq(omnibus.swapId(lock, alice, bob), omnibus.exposed_swapId(lock, omnibus.computeTermsHash(alice, bob)));
  }

  function test_swapId_argumentOrderIndependent() public view {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    assertEq(omnibus.swapId(lock, alice, bob), omnibus.swapId(lock, bob, alice));
  }

  function test_swapId_differsByTerms() public view {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();
    Terms memory bobCross = _bobCrossChainTerms();

    assertTrue(omnibus.swapId(lock, alice, bob) != omnibus.swapId(lock, alice, bobCross));
  }

  function testFuzz_swapId_differsByLock(bytes32 otherLock) public view {
    vm.assume(otherLock != lock);
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();

    assertTrue(omnibus.swapId(lock, alice, bob) != omnibus.swapId(otherLock, alice, bob));
  }
}
