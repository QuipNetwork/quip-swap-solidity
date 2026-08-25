// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {IOmnibus} from '../../../src/interfaces/IOmnibus.sol';
import {OmnibusTest} from '../Omnibus.t.sol';

/// @title Omnibus renounceOwnership Tests
/// @dev Omnibus overrides Ownable.renounceOwnership to always revert: an ownerless
/// Omnibus would permanently brick setCommitmentFee / setVerifierActivity /
/// withdrawFees and strand any accrued fees. The override is disabled for every
/// caller (owner and non-owner alike). Ordinary two-step ownership TRANSFER
/// (Ownable2Step) must remain unaffected. The harness owner is address(this),
/// set in OmnibusTest.setUp.
contract Omnibus_renounceOwnership is OmnibusTest {
  /// @notice the owner cannot renounce; the call reverts and ownership is untouched
  function test_renounceOwnership_revertsWhen_calledByOwner() public {
    address ownerBefore = omnibus.owner();

    vm.expectRevert(IOmnibus.RenounceDisabled.selector);
    omnibus.renounceOwnership();

    assertEq(omnibus.owner(), ownerBefore, 'owner must be unchanged after a reverted renounce');
  }

  /// @notice the function is disabled for everyone: a non-owner gets RenounceDisabled,
  /// not the OwnableUnauthorizedAccount it would hit if the onlyOwner gate ran first
  function test_renounceOwnership_revertsWhen_calledByNonOwner() public {
    vm.expectRevert(IOmnibus.RenounceDisabled.selector);
    vm.prank(ALICE);
    omnibus.renounceOwnership();
  }

  /// @notice only renounce is blocked; the two-step transfer flow still works end to end
  function test_renounceOwnership_transferOwnershipStillWorks() public {
    address newOwner = makeAddr('new-owner');

    omnibus.transferOwnership(newOwner);
    assertEq(omnibus.pendingOwner(), newOwner, 'pending owner set by transferOwnership');
    assertEq(omnibus.owner(), address(this), 'owner unchanged until acceptOwnership');

    vm.prank(newOwner);
    omnibus.acceptOwnership();
    assertEq(omnibus.owner(), newOwner, 'ownership transferred on accept');
    assertEq(omnibus.pendingOwner(), address(0), 'pending owner cleared on accept');
  }

  /// @notice the disable survives a transfer: the new owner cannot renounce either
  function test_renounceOwnership_stillDisabledAfterTransfer() public {
    address newOwner = makeAddr('new-owner');
    omnibus.transferOwnership(newOwner);
    vm.prank(newOwner);
    omnibus.acceptOwnership();

    vm.expectRevert(IOmnibus.RenounceDisabled.selector);
    vm.prank(newOwner);
    omnibus.renounceOwnership();
  }
}
