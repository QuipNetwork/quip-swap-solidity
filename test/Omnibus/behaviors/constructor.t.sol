// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {IOmnibus} from '../../../src/interfaces/IOmnibus.sol';
import {OmnibusHarness} from '../../harness/OmnibusHarness.sol';
import {OmnibusTest} from '../Omnibus.t.sol';

/// @title Omnibus constructor Tests
/// @dev Tests for the Omnibus constructor
contract Omnibus_constructor is OmnibusTest {
  function test_constructor_setsOwnerAndTrustsInitialVerifiers() public {
    address[] memory initialVerifiers = new address[](2);
    initialVerifiers[0] = address(verifierA);
    initialVerifiers[1] = address(verifierB);

    OmnibusHarness fresh = new OmnibusHarness(ALICE, initialVerifiers);

    assertEq(fresh.owner(), ALICE);
    assertTrue(fresh.trustedVerifiers(address(verifierA)));
    assertTrue(fresh.trustedVerifiers(address(verifierB)));
  }

  function test_constructor_emitsGenesisTrustEvents() public {
    address[] memory initialVerifiers = new address[](2);
    initialVerifiers[0] = address(verifierA);
    initialVerifiers[1] = address(verifierB);

    vm.expectEmit(true, false, false, true);
    emit IOmnibus.VerifierTrustUpdated(address(verifierA), true);
    vm.expectEmit(true, false, false, true);
    emit IOmnibus.VerifierTrustUpdated(address(verifierB), true);
    new OmnibusHarness(ALICE, initialVerifiers);
  }

  function test_constructor_acceptsEmptyVerifierArray() public {
    OmnibusHarness fresh = new OmnibusHarness(ALICE, new address[](0));
    assertEq(fresh.owner(), ALICE);
    assertFalse(fresh.trustedVerifiers(address(verifierA)));
  }

  function test_constructor_revertsWhen_zeroVerifierEntry() public {
    address[] memory initialVerifiers = new address[](2);
    initialVerifiers[0] = address(verifierA);
    initialVerifiers[1] = address(0);

    vm.expectRevert(IOmnibus.ZeroVerifier.selector);
    new OmnibusHarness(ALICE, initialVerifiers);
  }
}
