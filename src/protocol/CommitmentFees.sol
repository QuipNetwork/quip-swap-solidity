// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {ICommitmentFees} from '../interfaces/ICommitmentFees.sol';
import {Ownable, Ownable2Step} from '@openzeppelin-contracts-5.6.0-rc.1/access/Ownable2Step.sol';

/// @title CommitmentFees
/// @notice Shared storage surface for the v1 commitment-fee policy.
/// @dev The live fee defaults to zero and is paid once per accepted local
///      commit. A completed same-chain trade therefore pays two fees, while a
///      cross-chain trade pays each local wrapper's independently configured
///      fee. Fees are protocol revenue and are not escrow, gas, or refundable
///      settlement value. Configuration, collection, and withdrawal are added
///      by the subsequent fee-flow implementation tasks.
abstract contract CommitmentFees is ICommitmentFees, Ownable2Step {
  /// @inheritdoc ICommitmentFees
  uint256 public constant override MAX_FEE = 0.01 ether;

  /// @inheritdoc ICommitmentFees
  uint256 public override commitmentFee;

  /// @inheritdoc ICommitmentFees
  uint256 public override accruedFees;

  constructor(address initialOwner) Ownable(initialOwner) {}

  /// @inheritdoc ICommitmentFees
  function setCommitmentFee(uint256 newFee) external onlyOwner {
    if (newFee > MAX_FEE) revert FeeExceedsMax();
    uint256 oldFee = commitmentFee;
    commitmentFee = newFee;
    emit FeeUpdated(oldFee, newFee);
  }

  /// @notice Requires exact native escrow plus the current live fee.
  function _requireCommitValue(uint256 nativeEscrow) internal view {
    if (msg.value != nativeEscrow + commitmentFee) revert IncorrectNativeAmount();
  }

  /// @notice Records exactly the fee snapshot validated for one accepted commit.
  function _accrueCommitmentFee(uint256 feeSnapshot) internal {
    accruedFees += feeSnapshot;
  }
}
