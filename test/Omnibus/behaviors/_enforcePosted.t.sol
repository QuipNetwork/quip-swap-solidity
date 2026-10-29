// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {IOmnibus} from '../../../src/interfaces/IOmnibus.sol';
import {OmnibusTest} from '../Omnibus.t.sol';

/// @title Omnibus _enforcePosted Tests
/// @dev Tests for Omnibus._enforcePosted (via harness)
contract Omnibus__enforcePosted is OmnibusTest {
  bytes32 internal constant TERMS_DIGEST = keccak256('terms-digest');

  // ============ Success Cases ============

  function test_enforcePosted_succeedsWhenPosted() public {
    omnibus.setPosted(lock, TERMS_DIGEST, true);
    omnibus.exposed_enforcePosted(lock, TERMS_DIGEST);
  }

  // ============ Revert Cases ============

  function test_enforcePosted_revertsWhen_notPosted() public {
    vm.expectRevert(IOmnibus.TermsNotPosted.selector);
    omnibus.exposed_enforcePosted(lock, TERMS_DIGEST);
  }

  function test_enforcePosted_revertsWhen_postedForDifferentDigest() public {
    omnibus.setPosted(lock, TERMS_DIGEST, true);
    vm.expectRevert(IOmnibus.TermsNotPosted.selector);
    omnibus.exposed_enforcePosted(lock, keccak256('other-digest'));
  }

  function test_enforcePosted_revertsWhen_postedForDifferentLock() public {
    omnibus.setPosted(lock, TERMS_DIGEST, true);
    vm.expectRevert(IOmnibus.TermsNotPosted.selector);
    omnibus.exposed_enforcePosted(keccak256('other-lock'), TERMS_DIGEST);
  }
}
