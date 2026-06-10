// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {IOmnibus} from '../../../src/interfaces/IOmnibus.sol';
import {OmnibusHarness} from '../../harness/OmnibusHarness.sol';
import {OmnibusTest} from '../Omnibus.t.sol';

/// @title Omnibus constructor Tests
/// @dev Tests for the Omnibus constructor
contract Omnibus_constructor is OmnibusTest {
  function test_constructor_setsOwnerAndQuipFactory() public {
    OmnibusHarness fresh = new OmnibusHarness(ALICE, address(quipFactory));
    assertEq(fresh.owner(), ALICE);
    assertEq(address(fresh.QUIP_FACTORY()), address(quipFactory));
  }

  function test_constructor_revertsWhen_zeroQuipFactory() public {
    vm.expectRevert(IOmnibus.ZeroQuipFactory.selector);
    new OmnibusHarness(ALICE, address(0));
  }
}
