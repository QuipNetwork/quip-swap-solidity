// SPDX-License-Identifier: UNLICENSE
// Pin the compiler version used for these encodings and contract semantics.
pragma solidity 0.8.33;

// Import shared fee getters, errors, events, and administration interface.
import {ICommitmentFees} from '../interfaces/ICommitmentFees.sol';
// Import owner initialization and ownership transfer with explicit acceptance.
import {Ownable, Ownable2Step} from '@openzeppelin-contracts-5.6.0-rc.1/access/Ownable2Step.sol';
// Import checked native-currency transfers for fee withdrawal.
import {SafeTransferLib} from 'solady-0.1.26/utils/SafeTransferLib.sol';

/// @title CommitmentFees
/// @notice Shared storage surface for the v1 commitment-fee policy.
/// @dev The live fee defaults to zero and is paid once per accepted local
///      commit. A completed same-chain trade therefore pays two fees, while a
///      cross-chain trade pays each local wrapper's independently configured
///      fee. Fees are protocol revenue and are not escrow, gas, or refundable
///      settlement value. Withdrawal transfers only explicitly accrued fees,
///      never the wrapper's raw native balance.
abstract contract CommitmentFees is ICommitmentFees, Ownable2Step {
  /// @inheritdoc ICommitmentFees
  uint256 public constant override MAX_FEE = 0.01 ether; // Hard cap on the fee for one local commitment.

  /// @inheritdoc ICommitmentFees
  uint256 public override commitmentFee; // Live admission fee; defaults to zero.

  /// @inheritdoc ICommitmentFees
  uint256 public override accruedFees; // Accepted fee revenue available for owner withdrawal.

  // Initialize two-step fee ownership through the base owner constructor.
  constructor(address initialOwner) Ownable(initialOwner) {}

  /// @inheritdoc ICommitmentFees
  function setCommitmentFee(uint256 newFee) external onlyOwner {
    // The requested live fee exceeds the protocol cap.
    if (newFee > MAX_FEE) revert FeeExceedsMax();

    // Snapshot the old live fee for the update event.
    uint256 oldFee = commitmentFee;
    // Apply the new live fee to subsequent admitted commitments.
    commitmentFee = newFee;

    // Report the previous and new live commitment fees.
    emit FeeUpdated(oldFee, newFee);
  }

  /// @inheritdoc ICommitmentFees
  function withdrawFees(address to) external onlyOwner {
    // Protocol revenue cannot be sent to the zero address.
    if (to == address(0)) revert ZeroFeeRecipient();

    // Snapshot protocol revenue rather than withdrawing the raw native balance.
    uint256 amount = accruedFees;
    // Clear revenue before the external call; a failed transfer reverts this debit.
    delete accruedFees;

    // Transfer the recorded revenue and revert if the recipient cannot receive it.
    SafeTransferLib.safeTransferETH(to, amount);

    // Report the recipient and amount of withdrawn protocol revenue.
    emit FeesWithdrawn(to, amount);
  }

  /// @notice Ownership renunciation is disabled so fee administration cannot be stranded.
  function renounceOwnership() public pure override {
    // Fee ownership cannot be permanently renounced.
    revert RenounceDisabled();
  }

  /// @notice Requires exact native escrow plus the current live fee.
  function _requireCommitValue(uint256 nativeEscrow) internal view {
    // The attached native value differs from the amount required by this operation.
    if (msg.value != nativeEscrow + commitmentFee) revert IncorrectNativeAmount();
  }

  /// @notice Records exactly the fee snapshot validated for one accepted commit.
  function _accrueCommitmentFee(uint256 feeSnapshot) internal {
    // Add the fee accepted with this commit to withdrawable protocol revenue.
    accruedFees += feeSnapshot;
  }
}
