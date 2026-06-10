// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Terms} from '../TermsLib.sol';
import {IQuipFactory} from './IQuipFactory.sol';

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

  /// @notice thrown when a commit would re-post an already-posted side
  error TermsAlreadyPosted();

  /// @notice thrown when paying out a side that was never posted for the lock
  error TermsNotPosted();

  /// @notice thrown when fee exceeds MAX_FEE
  error FeeExceedsMax();

  /// @notice thrown when the caller is not a factory-deployed QuipWallet
  error CallerNotQuipWallet();

  /// @notice thrown when the quip factory address is zero
  error ZeroQuipFactory();

  /// @notice emitted when commitment fee is updated
  /// @param oldFee the previous fee
  /// @param newFee the new fee
  event FeeUpdated(uint256 oldFee, uint256 newFee);

  /// @notice emitted when accumulated fees are withdrawn
  /// @param to the recipient address
  /// @param amount the amount withdrawn
  event FeesWithdrawn(address indexed to, uint256 amount);

  /// @notice emitted when a party commits to a swap
  /// @param lock the hashlock identifier
  /// @param party the terms of the committing party
  /// @param committer the address that committed
  event Commitment(bytes32 indexed lock, Terms party, address indexed committer);

  /// @notice emitted when a swap is executed
  /// @param recipient address receiving assets of claim
  /// @param lock the hashlock identifier
  /// @param secret the preimage that unlocked the swap
  event Claim(address recipient, bytes32 indexed lock, bytes32 secret);

  /// @notice emitted when a party reclaims their assets
  /// @param caller address which initiated reclaim
  /// @param lock the hashlock identifier
  /// @param recipient the address that received the reclaim
  event Reclaimed(address caller, bytes32 indexed lock, address indexed recipient);

  /// @notice returns the state of a lock
  /// @param lock the hashlock identifier
  /// @return state the lock state
  function lockState(bytes32 lock) external view returns (LockState state);

  /// @notice returns the terms hash for a lock
  /// @param lock the hashlock identifier
  /// @return canonicalDigest the canonical terms hash
  function termsHash(bytes32 lock) external view returns (bytes32 canonicalDigest);

  /// @notice returns whether a side was posted for a lock
  /// @param lock the hashlock identifier
  /// @param termsDigest the side's terms digest
  /// @return isPosted whether that side has been posted
  function posted(bytes32 lock, bytes32 termsDigest) external view returns (bool isPosted);

  /// @notice commits assets and collateral to a swap
  /// @dev only callable by a factory-deployed QuipWallet (post-quantum secure);
  /// a wallet qualifies iff QUIP_FACTORY.vaultIdOf(wallet) != bytes32(0)
  /// @param lock the hashlock identifier
  /// @param party the first party's terms
  /// @param counterparty the second party's terms
  function commit(bytes32 lock, Terms calldata party, Terms calldata counterparty) external payable;

  /// @notice executes the swap by revealing the secret
  /// @dev a cross-chain claim is gated only on the local (party) leg's deadline; the
  /// counterparty leg's deadline is enforced only when it settles on this chain too.
  /// for a cross-chain swap the secret holder claims the counterparty's leg first, so
  /// the leg the secret holder claims must expire BEFORE the other leg: set the secret
  /// holder's own deposit with the later deadline and the counterparty's deposit (the
  /// one the secret holder takes) with the earlier deadline. the gap between the two is
  /// the buffer the second claimant has after the secret is revealed; mis-ordering it
  /// lets the secret holder take both legs
  /// @param secret the preimage of the lock
  /// @param party the first party's terms
  /// @param counterparty the second party's terms
  function claim(bytes32 secret, Terms calldata party, Terms calldata counterparty) external;

  /// @notice reclaims assets after deadline expires
  /// @param lock the hashlock identifier
  /// @param party the first party's terms
  /// @param counterparty the second party's terms
  function reclaim(bytes32 lock, Terms calldata party, Terms calldata counterparty) external;

  /// @notice the maximum allowed commitment fee
  /// @return the max fee in wei
  function MAX_FEE() external view returns (uint256);

  /// @notice the QuipFactory whose wallet registry gates commit
  /// @return the quip factory
  function QUIP_FACTORY() external view returns (IQuipFactory);

  /// @notice the current commitment fee
  /// @return the fee in wei
  function commitmentFee() external view returns (uint256);

  /// @notice the accumulated commitment fees available to withdraw
  /// @return fees the accrued fees in wei
  function accruedFees() external view returns (uint256 fees);

  /// @notice sets the commitment fee (owner only)
  /// @param newFee the new fee (must be <= MAX_FEE)
  function setCommitmentFee(uint256 newFee) external;

  /// @notice withdraws accumulated fees to recipient (owner only)
  /// @param to the recipient address
  function withdrawFees(address to) external;
}
