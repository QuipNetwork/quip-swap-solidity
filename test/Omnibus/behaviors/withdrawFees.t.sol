// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {IOmnibus} from '../../../src/interfaces/IOmnibus.sol';
import {Terms} from '../../../src/TermsLib.sol';
import {OmnibusTest} from '../Omnibus.t.sol';
import {Ownable} from '@openzeppelin-contracts-5.6.0-rc.1/access/Ownable.sol';
import {SafeTransferLib} from 'solady-0.1.26/utils/SafeTransferLib.sol';
import {Vm} from 'forge-std-1.14.0/Vm.sol';

/// @title Omnibus withdrawFees Tests
/// @dev Tests for Omnibus.withdrawFees
contract Omnibus_withdrawFees is OmnibusTest {
  address public TREASURY;

  function setUp() public override {
    super.setUp();
    TREASURY = makeAddr('treasury');
    // Set a commitment fee for testing
    omnibus.setCommitmentFee(0.005 ether);
  }

  // ============ Success Cases ============

  function test_withdrawFees_transfersBalance() public {
    // Commit with fee to accumulate fees
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();
    uint256 fee = omnibus.commitmentFee();
    uint256 nativeAmount = _totalNativeForCommit(alice) + fee;

    vm.prank(ALICE);
    omnibus.commit{value: nativeAmount}(lock, alice, bob);

    uint256 treasuryBefore = TREASURY.balance;
    uint256 omnibusBalance = address(omnibus).balance;

    omnibus.withdrawFees(TREASURY);

    assertEq(TREASURY.balance - treasuryBefore, omnibusBalance);
    assertEq(address(omnibus).balance, 0);
  }

  function test_withdrawFees_transfersZeroBalance() public {
    // Drain omnibus balance first
    omnibus.withdrawFees(TREASURY);

    uint256 treasuryBefore = TREASURY.balance;

    // Withdraw again with zero balance
    omnibus.withdrawFees(TREASURY);

    assertEq(TREASURY.balance, treasuryBefore);
    assertEq(address(omnibus).balance, 0);
  }

  function test_withdrawFees_emitsFeesWithdrawn() public {
    Terms memory alice = _aliceTerms();
    Terms memory bob = _bobTerms();
    uint256 fee = omnibus.commitmentFee();
    uint256 nativeAmount = _totalNativeForCommit(alice) + fee;

    vm.prank(ALICE);
    omnibus.commit{value: nativeAmount}(lock, alice, bob);

    uint256 omnibusBalance = address(omnibus).balance;

    vm.recordLogs();
    omnibus.withdrawFees(TREASURY);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    bool foundEvent = false;
    for (uint256 i = 0; i < logs.length; i++) {
      if (logs[i].topics[0] == IOmnibus.FeesWithdrawn.selector) {
        address loggedTo = address(uint160(uint256(logs[i].topics[1])));
        uint256 loggedAmount = abi.decode(logs[i].data, (uint256));
        assertEq(loggedTo, TREASURY);
        assertEq(loggedAmount, omnibusBalance);
        foundEvent = true;
        break;
      }
    }
    assertTrue(foundEvent, 'FeesWithdrawn event not emitted');
  }

  function test_withdrawFees_canWithdrawToAnyAddress() public {
    address recipient = makeAddr('random-recipient');
    uint256 recipientBefore = recipient.balance;
    uint256 omnibusBalance = address(omnibus).balance;

    omnibus.withdrawFees(recipient);

    assertEq(recipient.balance - recipientBefore, omnibusBalance);
  }

  // ============ Revert Cases ============

  function test_withdrawFees_revertsWhen_callerNotOwner() public {
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ALICE));
    vm.prank(ALICE);
    omnibus.withdrawFees(TREASURY);
  }

  function test_withdrawFees_revertsWhen_transferFails() public {
    // Deploy a contract that rejects ETH
    RejectingReceiver rejecter = new RejectingReceiver();

    vm.expectRevert(SafeTransferLib.ETHTransferFailed.selector);
    omnibus.withdrawFees(address(rejecter));
  }

  // ============ Fuzz Tests ============

  function testFuzz_withdrawFees_transfersFullBalance(uint256 extraNative) public {
    extraNative = bound(extraNative, 0, 10 ether);

    // Add extra native to omnibus
    vm.deal(address(omnibus), address(omnibus).balance + extraNative);

    address recipient = makeAddr('fuzz-recipient');
    uint256 omnibusBalance = address(omnibus).balance;

    omnibus.withdrawFees(recipient);

    assertEq(recipient.balance, omnibusBalance);
    assertEq(address(omnibus).balance, 0);
  }
}

/// @notice Helper contract that rejects ETH transfers
contract RejectingReceiver {
  receive() external payable {
    revert('rejected');
  }
}
