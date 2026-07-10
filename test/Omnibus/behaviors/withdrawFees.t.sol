// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Terms} from '../../../src/TermsLib.sol';
import {IOmnibus} from '../../../src/interfaces/IOmnibus.sol';
import {AuthHelper} from '../../utils/AuthHelper.sol';
import {OmnibusTest} from '../Omnibus.t.sol';
import {Ownable} from '@openzeppelin-contracts-5.6.0-rc.1/access/Ownable.sol';
import {Vm} from 'forge-std-1.14.0/Vm.sol';
import {SafeTransferLib} from 'solady-0.1.26/utils/SafeTransferLib.sol';

/// @title Omnibus withdrawFees Tests
/// @dev Tests for Omnibus.withdrawFees. withdrawFees must move only accrued
/// commitment fees; escrowed native owed back to depositors must never be swept.
contract Omnibus_withdrawFees is OmnibusTest {
  address public TREASURY;

  function setUp() public override {
    super.setUp();
    TREASURY = makeAddr('treasury');
    // Set a commitment fee for testing
    omnibus.setCommitmentFee(0.005 ether);
  }

  // ============ Helpers ============

  /// @notice commits Alice's native side on a lock, accruing one commitment fee
  /// @return fee the fee accrued by this commit
  function _commitAliceOn(bytes32 _lock) internal returns (uint256 fee) {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();
    fee = omnibus.commitmentFee();
    uint256 nativeAmount = _totalNativeForCommit(alice) + fee;
    vm.prank(ALICE);
    omnibus.commit{value: nativeAmount}(_lock, alice, bob, AuthHelper.keyedAuth(address(verifierA), ALICE));
  }

  // ============ Fee Accrual ============

  function test_withdrawFees_commitAccruesFee() public {
    uint256 fee = _commitAliceOn(lock);
    assertEq(omnibus.accruedFees(), fee);
  }

  function test_withdrawFees_accumulatesAcrossCommits() public {
    uint256 fee = _commitAliceOn(lock);
    _commitAliceOn(omnibus.exposed_generateLock(keccak256('secret-2')));
    assertEq(omnibus.accruedFees(), 2 * fee);
  }

  // ============ Success Cases ============

  function test_withdrawFees_transfersOnlyAccruedFees() public {
    uint256 fee = _commitAliceOn(lock);

    uint256 treasuryBefore = TREASURY.balance;
    uint256 omnibusBefore = address(omnibus).balance;

    omnibus.withdrawFees(TREASURY);

    // exactly the accrued fee leaves the contract
    assertEq(TREASURY.balance - treasuryBefore, fee);
    assertEq(omnibusBefore - address(omnibus).balance, fee);
    assertEq(omnibus.accruedFees(), 0);
  }

  /// @notice the escrowed native of a live swap is not withdrawable and stays reclaimable
  function test_withdrawFees_doesNotSweepEscrowedNative() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();
    uint256 escrow = _totalNativeForCommit(alice); // 10 ether of native escrow
    uint256 fee = omnibus.commitmentFee();

    vm.prank(ALICE);
    omnibus.commit{value: escrow + fee}(lock, alice, bob, AuthHelper.keyedAuth(address(verifierA), ALICE));

    // owner withdraws fees: only the fee leaves, the escrow remains
    uint256 omnibusBefore = address(omnibus).balance;
    omnibus.withdrawFees(TREASURY);
    assertEq(omnibusBefore - address(omnibus).balance, fee);
    assertEq(TREASURY.balance, fee);

    // the untouched escrow is still owed to Alice and reclaimable after her reclaim release
    vm.warp(ALICE_RECLAIM_RELEASE);
    uint256 aliceBefore = ALICE.balance;
    vm.prank(ALICE);
    omnibus.reclaim(lock, alice, bob);
    assertEq(ALICE.balance - aliceBefore, escrow);
  }

  /// @notice native sent directly to the contract is not counted as fees
  function test_withdrawFees_doesNotSweepStrayNative() public {
    // setUp already seeds the omnibus with native; no commits => no fees accrued
    assertEq(omnibus.accruedFees(), 0);

    uint256 treasuryBefore = TREASURY.balance;
    uint256 omnibusBefore = address(omnibus).balance;

    omnibus.withdrawFees(TREASURY);

    assertEq(TREASURY.balance, treasuryBefore);
    assertEq(address(omnibus).balance, omnibusBefore);
  }

  function test_withdrawFees_resetsAccruedToZero() public {
    _commitAliceOn(lock);
    omnibus.withdrawFees(TREASURY);
    assertEq(omnibus.accruedFees(), 0);

    // a second withdrawal moves nothing
    uint256 treasuryBefore = TREASURY.balance;
    omnibus.withdrawFees(TREASURY);
    assertEq(TREASURY.balance, treasuryBefore);
  }

  function test_withdrawFees_emitsFeesWithdrawn() public {
    uint256 fee = _commitAliceOn(lock);

    vm.recordLogs();
    omnibus.withdrawFees(TREASURY);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    bool foundEvent = false;
    for (uint256 i = 0; i < logs.length; i++) {
      if (logs[i].topics[0] == IOmnibus.FeesWithdrawn.selector) {
        address loggedTo = address(uint160(uint256(logs[i].topics[1])));
        uint256 loggedAmount = abi.decode(logs[i].data, (uint256));
        assertEq(loggedTo, TREASURY);
        assertEq(loggedAmount, fee);
        foundEvent = true;
        break;
      }
    }
    assertTrue(foundEvent, 'FeesWithdrawn event not emitted');
  }

  function test_withdrawFees_canWithdrawToAnyAddress() public {
    uint256 fee = _commitAliceOn(lock);
    address recipient = makeAddr('random-recipient');
    uint256 recipientBefore = recipient.balance;

    omnibus.withdrawFees(recipient);

    assertEq(recipient.balance - recipientBefore, fee);
  }

  // ============ Revert Cases ============

  function test_withdrawFees_revertsWhen_callerNotOwner() public {
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ALICE));
    vm.prank(ALICE);
    omnibus.withdrawFees(TREASURY);
  }

  function test_withdrawFees_revertsWhen_transferFails() public {
    _commitAliceOn(lock);

    // Deploy a contract that rejects ETH
    RejectingReceiver rejecter = new RejectingReceiver();

    vm.expectRevert(SafeTransferLib.ETHTransferFailed.selector);
    omnibus.withdrawFees(address(rejecter));
  }

  // ============ Fuzz Tests ============

  /// @notice regardless of how much native sits in the contract, only accrued fees leave
  function testFuzz_withdrawFees_onlyAccruedRegardlessOfBalance(uint256 extraNative) public {
    extraNative = bound(extraNative, 0, 10 ether);

    uint256 fee = _commitAliceOn(lock);
    vm.deal(address(omnibus), address(omnibus).balance + extraNative);

    address recipient = makeAddr('fuzz-recipient');
    uint256 omnibusBefore = address(omnibus).balance;

    omnibus.withdrawFees(recipient);

    assertEq(recipient.balance, fee);
    assertEq(omnibusBefore - address(omnibus).balance, fee);
    assertEq(omnibus.accruedFees(), 0);
  }
}

/// @notice Helper contract that rejects ETH transfers
contract RejectingReceiver {
  receive() external payable {
    revert('rejected');
  }
}
