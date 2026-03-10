// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Terms} from '../TermsLib.sol';

/// @notice the lock state for Omnibus swaps
enum LockState {
  /// @notice default - lock has never been used
  Unused,
  /// @notice same-chain only: one party has committed, waiting for counterparty
  Free,
  /// @notice ready for execute (same-chain: both committed; cross-chain: single commit)
  Committed,
  /// @notice terminal (executed or reclaimed)
  Spent
}

interface IOmnibus {
  /// @notice thrown when expected and actual terms hashes do not match
  error TermsMismatch();

  /// @notice thrown when the lock state is not as expected
  error InvalidLockState();

  /// @notice thrown when native amount received does not match expected
  error IncorrectNativeAmountReceived();

  /// @notice thrown when lock state transition is not allowed
  error InvalidLockAdvancement();

  /// @notice emitted when a party commits to a swap
  /// @param lock the hashlock identifier
  /// @param party the terms of the committing party
  /// @param committer the address that committed
  event Commitment(bytes32 indexed lock, Terms party, address indexed committer);

  /// @notice emitted when a swap is executed
  /// @param lock the hashlock identifier
  /// @param secret the preimage that unlocked the swap
  event Claim(bytes32 indexed lock, bytes32 secret);

  /// @notice emitted when a party reclaims their assets
  /// @param lock the hashlock identifier
  /// @param signatory the address that reclaimed
  event Reclaimed(bytes32 indexed lock, address indexed signatory);

  /// @notice returns the state of a lock
  /// @param lock the hashlock identifier
  /// @return the lock state
  function lockState(bytes32 lock) external view returns (LockState);

  /// @notice returns the terms hash for a lock
  /// @param lock the hashlock identifier
  /// @return the canonical terms hash
  function termsHash(bytes32 lock) external view returns (bytes32);

  /// @notice commits assets and collateral to a swap
  /// @param lock the hashlock identifier
  /// @param party the first party's terms
  /// @param counterparty the second party's terms
  function commit(bytes32 lock, Terms calldata party, Terms calldata counterparty) external payable;

  /// @notice executes the swap by revealing the secret
  /// @param secret the preimage of the lock
  /// @param party the first party's terms
  /// @param counterparty the second party's terms
  function execute(bytes32 secret, Terms calldata party, Terms calldata counterparty) external;

  /// @notice reclaims assets after deadline expires
  /// @param lock the hashlock identifier
  /// @param party the first party's terms
  /// @param counterparty the second party's terms
  function reclaim(bytes32 lock, Terms calldata party, Terms calldata counterparty) external;
}
