// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {ICommitmentFees} from '../interfaces/ICommitmentFees.sol';

/// @title CommitmentFees
/// @notice Shared storage surface for the v1 commitment-fee policy.
/// @dev The live fee defaults to zero and is paid once per accepted local
///      commit. A completed same-chain trade therefore pays two fees, while a
///      cross-chain trade pays each local wrapper's independently configured
///      fee. Fees are protocol revenue and are not escrow, gas, or refundable
///      settlement value. Configuration, collection, and withdrawal are added
///      by the subsequent fee-flow implementation tasks.
abstract contract CommitmentFees is ICommitmentFees {
  /// @inheritdoc ICommitmentFees
  uint256 public constant override MAX_FEE = 0.01 ether;

  /// @inheritdoc ICommitmentFees
  uint256 public override commitmentFee;

  /// @inheritdoc ICommitmentFees
  uint256 public override accruedFees;
}
