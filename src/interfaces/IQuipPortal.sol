// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {PartyTerms, QuipTerms} from '../TermsLib.sol';

interface IQuipPortal {
  /// @notice thrown when a required address is the zero address
  error EmptyAddress();

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
  /// @param lock the lock hash used for deployment
  /// @param quip the address of the deployed quip
  /// @param terms the terms of the quip agreement
  event QuipCreated(bytes32 indexed lock, address indexed quip, QuipTerms terms);

  /// @notice emitted when a quip proposal is created
  /// @param lock the lock hash used for deployment
  /// @param quip the address of the deployed quip
  /// @param terms the party terms of the proposal
  event QuipProposed(bytes32 indexed lock, address indexed quip, PartyTerms terms);

  /// @notice emitted when fees are withdrawn
  event FeesWithdrawn(address indexed receiver, uint256 amount);

  /// @notice emitted when the creation fee is updated
  event CreationFeeUpdated(uint256 newFee);

  /// @notice returns whether a lock has already been used
  /// @param lock the lock to check
  /// @return isSpent true if the lock has been used
  function isLockSpent(bytes32 lock) external view returns (bool isSpent);

  /// @notice creates a new quip with the given lock and terms
  /// @param lock the hash of the secret used for deterministic deployment
  /// @param terms the terms of the quip agreement
  function deployCoupledQuip(bytes32 lock, QuipTerms calldata terms) external payable;

  /// @notice creates a new uncoupled quip proposal with party terms only
  /// @param lock the hash of the secret used for deterministic deployment
  /// @param terms the party terms of the quip proposal
  function deployUncoupledQuip(bytes32 lock, PartyTerms calldata terms) external payable;

  /// @notice withdraws accumulated fees to the given receiver
  /// @param receiver the address to receive the fees
  /// @param amount the amount of fees to withdraw
  function withdrawFees(address receiver, uint256 amount) external;

  /// @notice updates the creation fee
  /// @param newFee the new creation fee
  function setCreationFee(uint256 newFee) external;
}
