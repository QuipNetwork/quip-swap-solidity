// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {IOmnibus} from '../../../src/interfaces/IOmnibus.sol';
import {OmnibusHarness} from '../../harness/OmnibusHarness.sol';
import {OmnibusTest} from '../Omnibus.t.sol';

/// @title Omnibus constructor Tests
/// @dev Tests for the Omnibus constructor
contract Omnibus_constructor is OmnibusTest {
  function test_constructor_setsOwner() public {
    OmnibusHarness fresh = new OmnibusHarness(ALICE, address(walletFactory));
    assertEq(fresh.owner(), ALICE);
  }

  function test_constructor_bakesDomainSeparator() public {
    OmnibusHarness fresh = new OmnibusHarness(ALICE, address(walletFactory));
    assertEq(fresh.DOMAIN_SEPARATOR(), keccak256(abi.encode(fresh.COMMIT_DIGEST_TAG(), block.chainid, address(fresh))));
  }

  function test_constructor_bakesWalletFactory() public {
    OmnibusHarness fresh = new OmnibusHarness(ALICE, address(walletFactory));
    assertEq(address(fresh.WALLET_FACTORY()), address(walletFactory));
  }

  function test_constructor_revertsWhen_factoryIsZero() public {
    vm.expectRevert(IOmnibus.ZeroFactory.selector);
    new OmnibusHarness(ALICE, address(0));
  }
}
