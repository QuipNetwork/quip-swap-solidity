// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {LockState, TermsV0} from '../TermsLib.sol';

interface IOmnibus {
  /// @notice thrown when the lock has already been spent
  error LockAlreadySpent();

  /// @notice thrown when the caller is not a valid signatory for the terms
  error InvalidSignatory();

  /// @notice thrown when the provided terms do not match the stored hash
  error InvalidTerms();

  /// @notice thrown when the terms deadline has passed
  error DeadlineExpired();

  /// @notice thrown when the terms deadline has not yet passed
  error DeadlineNotExpired();

  /// @notice thrown when the lock state is not as expected
  error InvalidLockState();

  /// @notice thrown when the caller is not authorized to slash
  error UnauthorizedSlasher();

  /// @notice thrown when the commitment value is insufficient
  error InsufficientCommitment();

  /// @notice emitted when a party commits to a swap
  /// @param lock the hashlock identifier
  /// @param signatory the address that committed
  event Commitment(bytes32 indexed lock, address indexed signatory);

  /// @notice emitted when a party claims their counterparty's assets
  /// @param lock the hashlock identifier
  /// @param signatory the address that claimed
  /// @param secret the preimage that unlocked the swap
  event Claim(bytes32 indexed lock, address indexed signatory, bytes32 secret);

  /// @notice emitted when a party is slashed for not executing
  /// @param lock the hashlock identifier
  /// @param target the address that was slashed
  /// @param slasher the address that received the collateral
  event Slashed(bytes32 indexed lock, address indexed target, address indexed slasher);

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
