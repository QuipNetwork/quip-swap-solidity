// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Omnibus} from '../../../src/Omnibus.sol';
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

  // ============ VERSION ============
  //
  // The harness fixes its own label, so these exercise Omnibus directly — the
  // constructor path a real deployment takes.

  function test_constructor_bakesVersion() public {
    Omnibus fresh = new Omnibus(ALICE, address(walletFactory), 'QUIP:Omnibus:some-label');
    assertEq(fresh.VERSION(), bytes32('QUIP:Omnibus:some-label'));
  }

  /// @dev VERSION is immutable, so it cannot be repaired after deploy. A zero
  ///      label would leave the deployment unable to say what it is — exactly
  ///      the state that made the wrong-factory testnets hard to diagnose.
  function test_constructor_revertsWhen_versionIsZero() public {
    vm.expectRevert(IOmnibus.ZeroVersion.selector);
    new Omnibus(ALICE, address(walletFactory), bytes32(0));
  }

  /// @dev Two deployments differing ONLY in version must be distinguishable
  ///      on-chain. This is what lets a redeploy prove which family it belongs
  ///      to without consulting a broadcast log.
  function test_constructor_versionDistinguishesOtherwiseIdenticalDeployments() public {
    Omnibus a = new Omnibus(ALICE, address(walletFactory), 'QUIP:Omnibus:mainnet');
    Omnibus b = new Omnibus(ALICE, address(walletFactory), 'QUIP:Omnibus:testnet');

    assertTrue(a.VERSION() != b.VERSION(), 'versions collide');
    assertEq(address(a.WALLET_FACTORY()), address(b.WALLET_FACTORY()), 'factories should be identical');
  }
}
