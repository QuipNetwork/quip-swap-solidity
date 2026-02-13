// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Vm} from 'forge-std-1.14.0/Vm.sol';
import {Initializable} from 'solady-0.1.26/utils/Initializable.sol';

import {Quip} from '../../../src/Quip.sol';
import {QuipTerms, TermsLib} from '../../../src/TermsLib.sol';
import {IQuip} from '../../../src/interfaces/IQuip.sol';
import {PqOwnerState} from '../../../src/interfaces/IQuipPortal.sol';
import {QuipTest} from '../Quip.t.sol';
import {WOTSPlus} from '@quip.network/hashsigs-solidity-0.1.0/contracts/WOTSPlus.sol';

/// @title Quip initializeCoupled Tests
/// @dev Tests for Quip.initializeCoupled
contract Quip_initializeCoupled is QuipTest {
  // ============ Success Cases ============

  function test_initializeCoupled_setsPqOwner() public view {
    (bytes32 publicSeed, bytes32 publicKeyHash) = deployedQuip.pqOwner();
    assertEq(publicSeed, defaultPqOwner.publicSeed);
    assertEq(publicKeyHash, defaultPqOwner.publicKeyHash);
  }

  function test_initializeCoupled_setsTermsDigest() public view {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    bytes32 expectedDigest = _digestTermsCanonically(terms);
    assertEq(deployedQuip.termsDigest(), expectedDigest);
  }

  function test_initializeCoupled_setsInitUncoupledFalse() public view {
    assertFalse(deployedQuip.INIT_UNCOUPLED());
  }

  function test_initializeCoupled_emitsPartyCommitmentEvent() public {
    (WOTSPlus.WinternitzAddress memory pqOwner,) = _uniqueKeyPair(123);
    bytes32 pqOwnerHash = _computePqOwnerHash(pqOwner);
    QuipTerms memory terms = _makeDefaultQuipTerms();
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

    bytes32 expectedDigest = _digestTermsCanonically(terms);

    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployCoupledQuip{value: nativeRequired}(pqOwner, terms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    // find PartyCommitment event
    bool found = false;
    for (uint256 i = 0; i < logs.length; i++) {
      if (logs[i].topics[0] == IQuip.PartyCommitment.selector) {
        // topics[1] contains the indexed pqOwnerHash parameter
        assertEq(logs[i].topics[1], pqOwnerHash);
        // data contains the termsDigest
        bytes32 emittedDigest = abi.decode(logs[i].data, (bytes32));
        assertEq(emittedDigest, expectedDigest);
        found = true;
        break;
      }
    }
    assertTrue(found, 'PartyCommitment event not found');
  }

  // ============ Revert Cases ============

  function test_initializeCoupled_revertsWhen_calledDirectly() public {
    WOTSPlus.WinternitzAddress memory pqOwner = WOTSPlus.WinternitzAddress({
      publicSeed: bytes32(uint256(1)),
      publicKeyHash: bytes32(uint256(2))
    });
    // calling directly (not as portal) reverts with CallerNotPortal
    vm.expectRevert(IQuip.CallerNotPortal.selector);
    deployedQuip.initializeCoupled(pqOwner, bytes32(uint256(3)));
  }

  function test_initializeCoupled_revertsWhen_calledTwice() public {
    WOTSPlus.WinternitzAddress memory pqOwner = WOTSPlus.WinternitzAddress({
      publicSeed: bytes32(uint256(1)),
      publicKeyHash: bytes32(uint256(2))
    });
    // already initialized, so re-initialization fails with InvalidInitialization from Solady
    vm.prank(address(portal));
    vm.expectRevert(Initializable.InvalidInitialization.selector);
    deployedQuip.initializeCoupled(pqOwner, bytes32(uint256(3)));
  }

  // ============ Fuzz Tests ============

  function testFuzz_initializeCoupled_withVariousPqOwners(bytes32 seed) public {
    (WOTSPlus.WinternitzAddress memory pqOwner,) = _generateKeyPair(seed);
    bytes32 pqOwnerHash = _computePqOwnerHash(pqOwner);
    vm.assume(portal.pqOwnerState(pqOwnerHash) == PqOwnerState.Unused);

    QuipTerms memory terms = _makeDefaultQuipTerms();
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployCoupledQuip{value: nativeRequired}(pqOwner, terms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    address quipAddr = _findQuipCreatedAddress(logs);
    Quip quip = Quip(payable(quipAddr));

    (bytes32 publicSeed, bytes32 publicKeyHash) = quip.pqOwner();
    assertEq(publicSeed, pqOwner.publicSeed);
    assertEq(publicKeyHash, pqOwner.publicKeyHash);
    assertFalse(quip.INIT_UNCOUPLED());
  }
}
