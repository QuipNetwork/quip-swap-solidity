// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {IQuipPortal, PqOwnerState} from '../../../src/interfaces/IQuipPortal.sol';
import {QuipPortalTest} from '../QuipPortal.t.sol';
import {WOTSPlus} from '@quip.network/hashsigs-solidity-0.1.0/contracts/WOTSPlus.sol';

/// @title QuipPortal _enforceValidPqOwner Tests
/// @dev Tests for QuipPortal._enforceValidPqOwner
contract QuipPortal__enforceValidPqOwner is QuipPortalTest {
  // ============ Success Cases ============

  function test_exposed_enforceValidPqOwner_succeedsForUnusedPqOwner() public view {
    // should not revert for unused pqOwner
    portalHarness.exposed_enforceValidPqOwner(defaultPqOwner, defaultPqOwnerHash);
  }

  function test_exposed_enforceValidPqOwner_succeedsForFreePqOwner() public {
    // advance to Free state
    portalHarness.exposed_advancePqOwner(defaultPqOwnerHash);
    assertEq(uint256(portalHarness.pqOwnerState(defaultPqOwnerHash)), uint256(PqOwnerState.Free));

    // should not revert for Free pqOwner
    portalHarness.exposed_enforceValidPqOwner(defaultPqOwner, defaultPqOwnerHash);
  }

  function test_exposed_enforceValidPqOwner_doesNotMutateState() public {
    assertEq(uint256(portalHarness.pqOwnerState(defaultPqOwnerHash)), uint256(PqOwnerState.Unused));
    portalHarness.exposed_enforceValidPqOwner(defaultPqOwner, defaultPqOwnerHash);
    // state should remain Unused (enforce is view-only)
    assertEq(uint256(portalHarness.pqOwnerState(defaultPqOwnerHash)), uint256(PqOwnerState.Unused));
  }

  // ============ Revert Cases ============

  function test_exposed_enforceValidPqOwner_revertsWhen_publicSeedIsZero() public {
    WOTSPlus.WinternitzAddress memory badPqOwner = WOTSPlus.WinternitzAddress({
      publicSeed: bytes32(0),
      publicKeyHash: bytes32(uint256(1))
    });
    bytes32 badHash = _computePqOwnerHash(badPqOwner);

    vm.expectRevert(IQuipPortal.EmptyPqOwner.selector);
    portalHarness.exposed_enforceValidPqOwner(badPqOwner, badHash);
  }

  function test_exposed_enforceValidPqOwner_revertsWhen_publicKeyHashIsZero() public {
    WOTSPlus.WinternitzAddress memory badPqOwner = WOTSPlus.WinternitzAddress({
      publicSeed: bytes32(uint256(1)),
      publicKeyHash: bytes32(0)
    });
    bytes32 badHash = _computePqOwnerHash(badPqOwner);

    vm.expectRevert(IQuipPortal.EmptyPqOwner.selector);
    portalHarness.exposed_enforceValidPqOwner(badPqOwner, badHash);
  }

  function test_exposed_enforceValidPqOwner_revertsWhen_bothFieldsAreZero() public {
    WOTSPlus.WinternitzAddress memory badPqOwner = WOTSPlus.WinternitzAddress({
      publicSeed: bytes32(0),
      publicKeyHash: bytes32(0)
    });
    bytes32 badHash = _computePqOwnerHash(badPqOwner);

    vm.expectRevert(IQuipPortal.EmptyPqOwner.selector);
    portalHarness.exposed_enforceValidPqOwner(badPqOwner, badHash);
  }

  function test_exposed_enforceValidPqOwner_revertsWhen_pqOwnerIsSpent() public {
    // advance to Spent state
    portalHarness.exposed_advancePqOwner(defaultPqOwnerHash); // Unused → Free
    portalHarness.exposed_advancePqOwner(defaultPqOwnerHash); // Free → Spent

    vm.expectRevert(IQuipPortal.PqOwnerSpent.selector);
    portalHarness.exposed_enforceValidPqOwner(defaultPqOwner, defaultPqOwnerHash);
  }

  // ============ Fuzz Tests ============

  function testFuzz_exposed_enforceValidPqOwner_succeedsForAnyValidUnusedPqOwner(bytes32 seed) public view {
    (WOTSPlus.WinternitzAddress memory pqOwner,) = _generateKeyPair(seed);
    bytes32 pqOwnerHash = _computePqOwnerHash(pqOwner);
    // should not revert
    portalHarness.exposed_enforceValidPqOwner(pqOwner, pqOwnerHash);
  }
}
