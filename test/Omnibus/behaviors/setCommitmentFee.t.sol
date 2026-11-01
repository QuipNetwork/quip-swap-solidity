// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {IOmnibus} from '../../../src/interfaces/IOmnibus.sol';
import {OmnibusTest} from '../Omnibus.t.sol';
import {Ownable} from '@openzeppelin-contracts-5.7.0/access/Ownable.sol';
import {Vm} from 'forge-std-1.14.0/Vm.sol';

/// @title Omnibus setCommitmentFee Tests
/// @dev Tests for Omnibus.setCommitmentFee
contract Omnibus_setCommitmentFee is OmnibusTest {
  // ============ Success Cases ============

  function test_setCommitmentFee_updatesFee() public {
    uint256 newFee = 0.005 ether;

    omnibus.setCommitmentFee(newFee);

    assertEq(omnibus.commitmentFee(), newFee);
  }

  function test_setCommitmentFee_updatesFromNonZero() public {
    uint256 firstFee = 0.003 ether;
    uint256 secondFee = 0.007 ether;

    omnibus.setCommitmentFee(firstFee);
    assertEq(omnibus.commitmentFee(), firstFee);

    omnibus.setCommitmentFee(secondFee);
    assertEq(omnibus.commitmentFee(), secondFee);
  }

  function test_setCommitmentFee_allowsZeroFee() public {
    omnibus.setCommitmentFee(0.005 ether);
    omnibus.setCommitmentFee(0);

    assertEq(omnibus.commitmentFee(), 0);
  }

  function test_setCommitmentFee_allowsMaxFee() public {
    uint256 maxFee = omnibus.MAX_FEE();

    omnibus.setCommitmentFee(maxFee);

    assertEq(omnibus.commitmentFee(), maxFee);
  }

  function test_setCommitmentFee_emitsFeeUpdated() public {
    uint256 oldFee = 0;
    uint256 newFee = 0.005 ether;

    vm.recordLogs();
    omnibus.setCommitmentFee(newFee);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    bool foundEvent = false;
    for (uint256 i = 0; i < logs.length; i++) {
      if (logs[i].topics[0] == IOmnibus.FeeUpdated.selector) {
        (uint256 loggedOldFee, uint256 loggedNewFee) = abi.decode(logs[i].data, (uint256, uint256));
        assertEq(loggedOldFee, oldFee);
        assertEq(loggedNewFee, newFee);
        foundEvent = true;
        break;
      }
    }
    assertTrue(foundEvent, 'FeeUpdated event not emitted');
  }

  function test_setCommitmentFee_emitsCorrectOldFee() public {
    uint256 firstFee = 0.003 ether;
    uint256 secondFee = 0.007 ether;

    omnibus.setCommitmentFee(firstFee);

    vm.recordLogs();
    omnibus.setCommitmentFee(secondFee);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    for (uint256 i = 0; i < logs.length; i++) {
      if (logs[i].topics[0] == IOmnibus.FeeUpdated.selector) {
        (uint256 loggedOldFee, uint256 loggedNewFee) = abi.decode(logs[i].data, (uint256, uint256));
        assertEq(loggedOldFee, firstFee);
        assertEq(loggedNewFee, secondFee);
        break;
      }
    }
  }

  // ============ Revert Cases ============

  function test_setCommitmentFee_revertsWhen_callerNotOwner() public {
    uint256 newFee = 0.005 ether;

    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ALICE));
    vm.prank(ALICE);
    omnibus.setCommitmentFee(newFee);
  }

  function test_setCommitmentFee_revertsWhen_feeExceedsMax() public {
    uint256 excessiveFee = omnibus.MAX_FEE() + 1;

    vm.expectRevert(IOmnibus.FeeExceedsMax.selector);
    omnibus.setCommitmentFee(excessiveFee);
  }

  // ============ Fuzz Tests ============

  function testFuzz_setCommitmentFee_acceptsValidFee(uint256 fee) public {
    fee = bound(fee, 0, omnibus.MAX_FEE());

    omnibus.setCommitmentFee(fee);

    assertEq(omnibus.commitmentFee(), fee);
  }

  function testFuzz_setCommitmentFee_revertsWhen_feeExceedsMax(uint256 fee) public {
    fee = bound(fee, omnibus.MAX_FEE() + 1, type(uint256).max);

    vm.expectRevert(IOmnibus.FeeExceedsMax.selector);
    omnibus.setCommitmentFee(fee);
  }
}
