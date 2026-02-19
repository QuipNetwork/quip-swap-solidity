// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {PartyTerms, QuipTerms} from '../TermsLib.sol';
import {WOTSPlus} from '@quip.network/hashsigs-solidity-0.1.0/contracts/WOTSPlus.sol';

/// @notice Represents the lifecycle state of a pqOwner (WOTS+ public key) within a portal
/// @dev State transitions:
///      - Unused → Free: First quip deployment with this pqOwner
///      - Free → Spent: Second quip deployment (same-chain swap) OR claim/reclaim
///      - Spent: Terminal state, no further deployments allowed
enum PqOwnerState {
  /// @notice Default state - pqOwner has never been used on this portal
  Unused,
  /// @notice PqOwner has one active quip - available for one more use (counterparty deploy or claim/reclaim)
  Free,
  /// @notice Terminal state - pqOwner fully consumed (two quips deployed OR claim/reclaim executed)
  Spent
}

interface IQuipPortal {
  /// @notice thrown when a required address is the zero address
  error EmptyAddress();

  /// @notice thrown when a pqOwner is empty (zero publicSeed and publicKeyHash)
  error EmptyPqOwner();

  /// @notice thrown when the pqOwner has already been fully consumed
  error PqOwnerSpent();

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
  /// @param pqOwnerHash the hash of the WOTS+ public key used for deployment
  /// @param quip the address of the deployed quip
  /// @param terms the terms of the quip agreement
  event QuipCreated(bytes32 indexed pqOwnerHash, address indexed quip, QuipTerms terms);

  /// @notice emitted when a quip is created and immediately claimed in a single transaction
  /// @param pqOwnerHash the hash of the WOTS+ public key used for deployment
  /// @param quip the address of the deployed quip
  /// @param terms the terms of the quip agreement
  event QuipCreatedAndClaimed(bytes32 indexed pqOwnerHash, address indexed quip, QuipTerms terms);

  /// @notice emitted when a quip proposal is created
  /// @param pqOwnerHash the hash of the WOTS+ public key used for deployment
  /// @param quip the address of the deployed quip
  /// @param terms the party terms of the proposal
  event QuipProposed(bytes32 indexed pqOwnerHash, address indexed quip, PartyTerms terms);

  /// @notice emitted when a pqOwner transitions to spent state
  /// @param pqOwnerHash the pqOwnerHash that was spent
  /// @param quip the quip that triggered the spend
  event SpentPqOwner(bytes32 indexed pqOwnerHash, address indexed quip);

  /// @notice emitted when fees are withdrawn
  event FeesWithdrawn(address indexed receiver, uint256 amount);

  /// @notice emitted when the creation fee is updated
  event CreationFeeUpdated(uint256 newFee);

  /// @notice returns the current state of a pqOwner
  /// @param pqOwnerHash the pqOwnerHash to check
  /// @return state the current PqOwnerState
  function pqOwnerState(bytes32 pqOwnerHash) external view returns (PqOwnerState state);

  /// @notice returns the expected codehash of valid quip clones
  /// @dev Set on first deployment; used to verify callers in spendLock
  /// @return the keccak256 hash of the quip clone runtime bytecode
  function QUIP_CODEHASH() external view returns (bytes32);

  /// @notice creates a new quip with the given WOTS+ public key and terms
  /// @param pqOwner the WOTS+ public key used for deterministic deployment
  /// @param terms the terms of the quip agreement
  function deployCoupledQuip(WOTSPlus.WinternitzAddress calldata pqOwner, QuipTerms calldata terms) external payable;

  /// @notice creates a new quip and immediately claims it in a single transaction
  /// @dev Combines deployCoupledQuip and claim into one atomic operation
  /// @param pqOwner the WOTS+ public key used for deterministic deployment
  /// @param signature the WOTS+ signature authorizing the claim
  /// @param terms the terms of the quip agreement
  function deployAndClaimCoupledQuip(
    WOTSPlus.WinternitzAddress calldata pqOwner,
    WOTSPlus.WinternitzElements calldata signature,
    QuipTerms calldata terms
  ) external payable;

  /// @notice creates a new uncoupled quip proposal with party terms only
  /// @param pqOwner the WOTS+ public key used for deterministic deployment
  /// @param terms the party terms of the quip proposal
  function deployUncoupledQuip(WOTSPlus.WinternitzAddress calldata pqOwner, PartyTerms calldata terms) external payable;

  /// @notice withdraws accumulated fees to the given receiver
  /// @param receiver the address to receive the fees
  /// @param amount the amount of fees to withdraw
  function withdrawFees(address receiver, uint256 amount) external;

  /// @notice updates the creation fee
  /// @param newFee the new creation fee
  function setCreationFee(uint256 newFee) external;

  /// @notice marks a pqOwner as spent, callable only by quip contracts deployed by this portal
  /// @dev Called by Quip.claim() and Quip.reclaim() to transition pqOwner state
  ///      - If Free → Spent (first terminal action on this pqOwner)
  ///      - If Spent → no-op (idempotent for same-chain swaps where both quips may call)
  /// @param pqOwnerHash the pqOwnerHash to mark as spent
  function spendPqOwner(bytes32 pqOwnerHash) external;

  /// @notice predicts the address of a quip that would be deployed with the given parameters
  /// @dev Uses the same salt derivation as internal _deployQuip for deterministic address prediction
  /// @param publicSeed the publicSeed from the pqOwner
  /// @param deployer the address that will deploy the quip
  /// @return predicted the predicted address of the quip
  function predictQuipAddress(bytes32 publicSeed, address deployer) external view returns (address predicted);
}
