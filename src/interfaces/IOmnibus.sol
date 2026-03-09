// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {LockState, TermsV0} from '../TermsLib.sol';

interface IOmnibus {
  /// @notice thrown when the lock has already been spent
  error LockAlreadySpent();

  /// @notice thrown when the provided terms do not match the stored hash
  error InvalidTerms();

  /// @notice thrown when expected and actual terms hashes do not match
  error TermsMismatch();

  /// @notice thrown when the lock state is not as expected
  error InvalidLockState();

  /// @notice thrown when native amount received does not match expected
  error IncorrectNativeAmountReceived();

  /// @notice thrown when no party is eligible for slash
  error InvalidSlash();

  /// @notice thrown when no party is eligible for reclaim
  error InvalidReclaim();

  /// @notice thrown when lock state transition is not allowed
  error InvalidLockAdvancement();

  /// @notice thrown when party chainId does not match current chain
  error ChainMismatch();

  /// @notice emitted when a party commits to a swap
  /// @param lock the hashlock identifier
  /// @param party the terms of the committing party
  /// @param committer the address that committed
  event Commitment(bytes32 indexed lock, TermsV0 party, address indexed committer);

  /// @notice emitted when a swap is executed
  /// @param lock the hashlock identifier
  /// @param secret the preimage that unlocked the swap
  event Claim(bytes32 indexed lock, bytes32 secret);

  /// @notice emitted when a party is slashed for not executing
  /// @param lock the hashlock identifier
  /// @param target the signatory that was slashed
  /// @param collateralRecipient the address that received the collateral
  event Slashed(bytes32 indexed lock, address indexed target, address indexed collateralRecipient);

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
  function commit(bytes32 lock, TermsV0 calldata party, TermsV0 calldata counterparty) external payable;

  /// @notice executes the swap by revealing the secret
  /// @param secret the preimage of the lock
  /// @param party the first party's terms
  /// @param counterparty the second party's terms
  function execute(bytes32 secret, TermsV0 calldata party, TermsV0 calldata counterparty) external;

  /// @notice slashes a party after their deadline expires
  /// @param lock the hashlock identifier
  /// @param party the first party's terms
  /// @param counterparty the second party's terms
  function slash(bytes32 lock, TermsV0 calldata party, TermsV0 calldata counterparty) external;

  /// @notice reclaims assets when only one party has committed
  /// @param lock the hashlock identifier
  /// @param party the first party's terms
  /// @param counterparty the second party's terms
  function reclaim(bytes32 lock, TermsV0 calldata party, TermsV0 calldata counterparty) external;
}
