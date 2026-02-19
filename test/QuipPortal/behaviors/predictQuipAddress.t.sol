// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Vm} from 'forge-std-1.14.0/Vm.sol';

import {QuipTerms, TermsLib} from '../../../src/TermsLib.sol';
import {IQuipPortal} from '../../../src/interfaces/IQuipPortal.sol';
import {QuipPortalTest} from '../QuipPortal.t.sol';
import {WOTSPlus} from '@quip.network/hashsigs-solidity-0.1.0/contracts/WOTSPlus.sol';

/// @title QuipPortal predictQuipAddress Tests
/// @dev Tests for QuipPortal.predictQuipAddress
contract QuipPortal_predictQuipAddress is QuipPortalTest {
  // ============ Success Cases ============

  function test_predictQuipAddress_matchesDeployedAddress() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

    // Predict address before deployment
    address predicted = portal.predictQuipAddress(defaultPqOwner.publicSeed, ALICE);

    // Deploy the quip
    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployCoupledQuip{value: nativeRequired}(defaultPqOwner, terms);

    // Get actual deployed address from event
    Vm.Log[] memory logs = vm.getRecordedLogs();
    address actual = _findQuipCreatedAddress(logs);

    // Verify prediction matches actual
    assertEq(predicted, actual);
  }

  function test_predictQuipAddress_differentDeployersGetDifferentAddresses() public {
    address predictedAlice = portal.predictQuipAddress(defaultPqOwner.publicSeed, ALICE);
    address predictedBob = portal.predictQuipAddress(defaultPqOwner.publicSeed, BOB);

    assertNotEq(predictedAlice, predictedBob);
  }

  function test_predictQuipAddress_differentPqOwnersGetDifferentAddresses() public {
    (WOTSPlus.WinternitzAddress memory pqOwner2,) = _uniqueKeyPair(2);

    address predicted1 = portal.predictQuipAddress(defaultPqOwner.publicSeed, ALICE);
    address predicted2 = portal.predictQuipAddress(pqOwner2.publicSeed, ALICE);

    assertNotEq(predicted1, predicted2);
  }

  function test_predictQuipAddress_consistentAcrossMultipleCalls() public {
    address predicted1 = portal.predictQuipAddress(defaultPqOwner.publicSeed, ALICE);
    address predicted2 = portal.predictQuipAddress(defaultPqOwner.publicSeed, ALICE);

    assertEq(predicted1, predicted2);
  }

  function test_predictQuipAddress_worksBeforeAnyDeployment() public {
    // No deployments yet, but prediction should still work
    address predicted = portal.predictQuipAddress(defaultPqOwner.publicSeed, ALICE);

    // Should be a valid non-zero address
    assertNotEq(predicted, address(0));
  }

  function test_predictQuipAddress_matchesDeployAndClaimCoupledQuip() public {
    QuipTerms memory terms = _makeDefaultQuipTerms();
    uint256 partyNativeAmount = TermsLib.totalNativeAmount(terms.partyAssets);
    uint256 nativeRequired = CREATION_FEE + partyNativeAmount;
    WOTSPlus.WinternitzElements memory signature = _signTerms(defaultPrivateKey, terms);

    // Predict address before deployment
    address predicted = portal.predictQuipAddress(defaultPqOwner.publicSeed, ALICE);

    // Pre-fund the predicted quip address with party assets
    vm.deal(predicted, partyNativeAmount);

    // Deploy and claim the quip
    // Note: Contract still expects fee + partyNative in msg.value for validation
    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployAndClaimCoupledQuip{value: nativeRequired}(defaultPqOwner, signature, terms);

    // Get actual deployed address from event
    Vm.Log[] memory logs = vm.getRecordedLogs();
    address actual = _findQuipCreatedAndClaimedAddress(logs);

    // Verify prediction matches actual
    assertEq(predicted, actual);
  }

  function test_predictQuipAddress_matchesDeployUncoupledQuip() public {
    // Predict address before deployment
    address predicted = portal.predictQuipAddress(defaultPqOwner.publicSeed, ALICE);

    // Deploy uncoupled quip
    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployUncoupledQuip{value: CREATION_FEE}(defaultPqOwner, _makeDefaultPartyTerms());

    // Get actual deployed address from event
    Vm.Log[] memory logs = vm.getRecordedLogs();
    address actual = _findQuipProposedAddress(logs);

    // Verify prediction matches actual
    assertEq(predicted, actual);
  }

  // ============ Fuzz Tests ============

  function testFuzz_predictQuipAddress_matchesDeployedAddress(bytes32 seed) public {
    (WOTSPlus.WinternitzAddress memory pqOwner,) = _generateKeyPair(seed);

    QuipTerms memory terms = _makeDefaultQuipTerms();
    uint256 nativeRequired = CREATION_FEE + TermsLib.totalNativeAmount(terms.partyAssets);

    // Predict address
    address predicted = portal.predictQuipAddress(pqOwner.publicSeed, ALICE);

    // Deploy
    vm.prank(ALICE);
    vm.recordLogs();
    portal.deployCoupledQuip{value: nativeRequired}(pqOwner, terms);

    // Verify
    Vm.Log[] memory logs = vm.getRecordedLogs();
    address actual = _findQuipCreatedAddress(logs);

    assertEq(predicted, actual);
  }

  function testFuzz_predictQuipAddress_differentDeployers(address deployer1, address deployer2) public {
    vm.assume(deployer1 != deployer2);
    vm.assume(deployer1 != address(0));
    vm.assume(deployer2 != address(0));

    address predicted1 = portal.predictQuipAddress(defaultPqOwner.publicSeed, deployer1);
    address predicted2 = portal.predictQuipAddress(defaultPqOwner.publicSeed, deployer2);

    assertNotEq(predicted1, predicted2);
  }

  // ============ Internal Helpers ============

  function _findQuipCreatedAndClaimedAddress(Vm.Log[] memory logs) internal pure returns (address) {
    for (uint256 i = 0; i < logs.length; i++) {
      if (logs[i].topics[0] == IQuipPortal.QuipCreatedAndClaimed.selector) {
        return address(uint160(uint256(logs[i].topics[2])));
      }
    }
    revert('QuipCreatedAndClaimed event not found');
  }
}
