// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Vm} from 'forge-std-1.14.0/Vm.sol';
import {Initializable} from 'solady-0.1.26/utils/Initializable.sol';

import {IQuip} from '../../../src/interfaces/IQuip.sol';
import {QuipTerms, TermsLib} from '../../../src/TermsLib.sol';
import {Quip} from '../../../src/Quip.sol';
import {QuipTest} from '../Quip.t.sol';

/// @title Quip initializeCoupled Tests
/// @dev Tests for Quip.initializeCoupled
contract Quip_initializeCoupled is QuipTest {
  // ============ Success Cases ============

  function test_initializeCoupled_setsLock() public view {
    assertEq(deployedQuip.lock(), defaultLock);
  }

  function test_initializeCoupled_setsTermsDigest() public view {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    bytes32 expectedDigest = _digestQuipTerms(terms);
    assertEq(deployedQuip.termsDigest(), expectedDigest);
  }

  function test_initializeCoupled_setsInitUncoupledFalse() public view {
    assertFalse(deployedQuip.INIT_UNCOUPLED());
  }

  function test_initializeCoupled_emitsPartyCommitmentEvent() public {
    bytes memory key = abi.encodePacked('new_key_for_event');
    bytes32 lock = keccak256(key);
    QuipTerms memory terms = _makeDefaultQuipTerms();
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

    bytes32 expectedDigest = _digestQuipTerms(terms);

    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployCoupledQuip{value: nativeRequired}(lock, terms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    // Find PartyCommitment event
    bool found = false;
    for (uint256 i = 0; i < logs.length; i++) {
      if (logs[i].topics[0] == IQuip.PartyCommitment.selector) {
        // topics[1] contains the indexed lock parameter
        assertEq(logs[i].topics[1], lock);
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
    // Calling directly (not as portal) reverts with CallerNotPortal
    vm.expectRevert(IQuip.CallerNotPortal.selector);
    deployedQuip.initializeCoupled(bytes32(uint256(1)), bytes32(uint256(2)));
  }

  function test_initializeCoupled_revertsWhen_calledTwice() public {
    // Already initialized, so re-initialization fails with InvalidInitialization from Solady
    vm.prank(address(portal));
    vm.expectRevert(Initializable.InvalidInitialization.selector);
    deployedQuip.initializeCoupled(bytes32(uint256(1)), bytes32(uint256(2)));
  }

  // ============ Fuzz Tests ============

  function testFuzz_initializeCoupled_withVariousLocks(bytes32 lock) public {
    vm.assume(lock != bytes32(0));
    vm.assume(!portal.isLockSpent(lock));

    QuipTerms memory terms = _makeDefaultQuipTerms();
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployCoupledQuip{value: nativeRequired}(lock, terms);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    address quipAddr = _findQuipCreatedAddress(logs);
    Quip quip = Quip(payable(quipAddr));

    assertEq(quip.lock(), lock);
    assertFalse(quip.INIT_UNCOUPLED());
  }
}
