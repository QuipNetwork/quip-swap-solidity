// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {PartyTerms, QuipTerms} from '../TermsLib.sol';

/// @notice Represents the lifecycle state of a lock within a portal
/// @dev State transitions:
///      - Unused → Free: First quip deployment with this lock
///      - Free → Spent: Second quip deployment (same-chain swap) OR claim/reclaim
///      - Spent: Terminal state, no further deployments allowed
enum LockState {
  /// @notice Default state - lock has never been used on this portal
  Unused,
  /// @notice Lock has one active quip - available for one more use (counterparty deploy or claim/reclaim)
  Free,
  /// @notice Terminal state - lock fully consumed (two quips deployed OR claim/reclaim executed)
  Spent
}

interface IQuipPortal {
  /// @notice thrown when a required address is the zero address
  error EmptyAddress();

  /// @notice thrown when a lock is empty
  error EmptyLock();

  /// @notice thrown when the lock has already been fully consumed
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

  /// @notice thrown when spendLock is called by a non-quip contract
  error CallerNotQuip();

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

  /// @notice emitted when a lock transitions to spent state
  /// @param lock the lock that was spent
  /// @param quip the quip that triggered the spend
  event SpentLock(bytes32 indexed lock, address indexed quip);

  /// @notice emitted when fees are withdrawn
  event FeesWithdrawn(address indexed receiver, uint256 amount);

  /// @notice emitted when the creation fee is updated
  event CreationFeeUpdated(uint256 newFee);

  /// @notice returns the current state of a lock
  /// @param lock the lock to check
  /// @return state the current LockState
  function lockState(bytes32 lock) external view returns (LockState state);

  /// @notice returns the expected codehash of valid quip clones
  /// @dev Set on first deployment; used to verify callers in spendLock
  /// @return the keccak256 hash of the quip clone runtime bytecode
  function QUIP_CODEHASH() external view returns (bytes32);

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

  /// @notice marks a lock as spent, callable only by quip contracts deployed by this portal
  /// @dev Called by Quip.claim() and Quip.reclaim() to transition lock state
  ///      - If Free → Spent (first terminal action on this lock)
  ///      - If Spent → no-op (idempotent for same-chain swaps where both quips may call)
  /// @param lock the lock to mark as spent
  function spendLock(bytes32 lock) external;
}
