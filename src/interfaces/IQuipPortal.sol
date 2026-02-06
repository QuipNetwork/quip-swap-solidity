// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import { QuipTerms } from "./IQuip.sol";
interface IQuipPortal {
  /// @notice thrown when a lock is empty
  error EmptyLock();

  /// @notice thrown when the lock has already been used
  error LockSpent();

  /// @notice thrown when party or counterparty is the zero address
  error EmptyParty();

  /// @notice thrown when party recipient or counterparty recipient is the zero address
  error EmptyRecipient();

  /// @notice thrown when party expiry or counterparty expiry is in the past
  error InvalidExpiry();

  /// @notice thrown when party assets or counterparty assets array is empty
  error EmptyAssets();

  /// @notice thrown when msg.value does not match expected native amount
  error IncorrectNativeAmount();

  /// @notice thrown when fee exceeds MAX_FEE
  error FeeExceedsMax();

  /// @notice thrown when withdrawal amount exceeds accumulated fees
  error InsufficientFees();

  /// @notice thrown when caller is not admin
  error NotAdmin();

  /// @notice emitted when a new quip is created
  event QuipCreated(address indexed quip, QuipTerms terms);

  /// @notice emitted when fees are withdrawn
  event FeesWithdrawn(address indexed receiver, uint256 amount);

  /// @notice emitted when the creation fee is updated
  event CreationFeeUpdated(uint256 newFee);

  /// @notice returns whether a lock has already been used
  /// @param lock the lock to check
  /// @return isSpent true if the lock has been used
  function isLockSpent(bytes32 lock) external view returns (bool isSpent);
}
