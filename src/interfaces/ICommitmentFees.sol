// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

/// @title ICommitmentFees
/// @notice Shared native commitment-fee surface for the v1.1 protocol wrappers.
/// @dev The fee policy follows v1: the live fee is charged once per accepted
///      local commit, in addition to native escrow, and is not transaction gas.
interface ICommitmentFees {
  /// @notice Thrown when a commit does not provide exact escrow plus fee.
  error IncorrectNativeAmount();

  /// @notice Thrown when a configured commitment fee exceeds `MAX_FEE`.
  error FeeExceedsMax();

  /// @notice Thrown when accrued fees would be withdrawn to the zero address.
  error ZeroFeeRecipient();

  /// @notice Emitted when the live per-commit fee changes.
  event FeeUpdated(uint256 oldFee, uint256 newFee);

  /// @notice Emitted when explicitly accrued fees are withdrawn.
  event FeesWithdrawn(address indexed to, uint256 amount);

  /// @notice Maximum live commitment fee, denominated in native currency.
  function MAX_FEE() external view returns (uint256);

  /// @notice Current native fee charged for each accepted local commit.
  function commitmentFee() external view returns (uint256);

  /// @notice Native commitment fees accrued and available for withdrawal.
  function accruedFees() external view returns (uint256);

  /// @notice Sets the live per-commit fee; callable only by the wrapper owner.
  /// @param newFee New native fee, which must not exceed `MAX_FEE`.
  function setCommitmentFee(uint256 newFee) external;

  /// @notice Withdraws exactly the explicitly accrued fees.
  /// @param to Recipient of the accrued native fees; cannot be zero.
  function withdrawFees(address to) external;
}
