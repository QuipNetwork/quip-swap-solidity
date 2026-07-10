// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {OmnibusHarness} from '../../harness/OmnibusHarness.sol';
import {OmnibusTest} from '../Omnibus.t.sol';

/// @title Omnibus constructor Tests
/// @dev Tests for the Omnibus constructor
contract Omnibus_constructor is OmnibusTest {
  function test_constructor_setsOwner() public {
    OmnibusHarness fresh = new OmnibusHarness(ALICE);
    assertEq(fresh.owner(), ALICE);
  }

  function test_constructor_activatesNoVerifiers() public {
    // verifiers are activated post-deploy via setVerifierActivity, never at genesis
    OmnibusHarness fresh = new OmnibusHarness(ALICE);
    assertFalse(fresh.verifierActive(address(verifierA)));
    assertFalse(fresh.verifierActive(address(verifierB)));
  }
}
