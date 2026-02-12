// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {PartyTerms, QuipTerms, TermsLib} from './TermsLib.sol';
import {IQuip} from './interfaces/IQuip.sol';
import {IQuipPortal, LockState} from './interfaces/IQuipPortal.sol';
import {Context} from '@openzeppelin-contracts-5.6.0-rc.1/utils/Context.sol';
import {LibClone} from 'solady-0.1.26/utils/LibClone.sol';
import {SafeTransferLib} from 'solady-0.1.26/utils/SafeTransferLib.sol';

contract QuipPortal is Context, IQuipPortal {
  /// @notice the factory version
  uint256 public constant VERSION = 1;

  /// @notice maximum fee that can ever be set
  uint256 public immutable MAX_FEE;

  /// @notice current fee charged for quip creation
  uint256 public creationFee;

  /// @notice total fees available for withdrawal
  uint256 public accumulatedFees;

  /// @notice address with admin privileges
  address public admin;

  /// @notice the quip implementation used for cloning
  address immutable QUIP_IMPLEMENTATION;

  /// @notice tracks the lifecycle state of each lock
  /// @dev See LockState enum for state transitions
  mapping(bytes32 lock => LockState state) public lockState;

  /// @notice the expected codehash of valid quip clones deployed by this portal
  /// @dev Set on first deployment; all clones share the same runtime bytecode
  bytes32 public QUIP_CODEHASH;

  modifier onlyAdmin() {
    _onlyAdmin();
    _;
  }

  /// @notice deploys a new quip portal
  /// @param firstAdmin the initial admin address
  /// @param quipImpl the quip implementation address used for cloning
  /// @param maxFee the maximum creation fee that can ever be set
  /// @param _creationFee the initial creation fee
  constructor(address firstAdmin, address quipImpl, uint256 maxFee, uint256 _creationFee) {
    _enforceNonEmptyAddress(firstAdmin);
    _enforceNonEmptyAddress(quipImpl);
    if (_creationFee > maxFee) revert FeeExceedsMax();
    QUIP_IMPLEMENTATION = quipImpl;
    MAX_FEE = maxFee;
    admin = firstAdmin;
    creationFee = _creationFee;
  }

  /// @notice creates a new quip with the given lock and terms
  /// @dev Salt for deterministic deployment is keccak256(lock, msg.sender) to allow
  ///      same-chain swaps where both parties deploy with the same lock
  /// @param lock the hash of the secret used for deterministic deployment
  /// @param terms the terms of the quip agreement
  function deployCoupledQuip(bytes32 lock, QuipTerms calldata terms) external payable {
    _enforceValidLock(lock);
    _validateQuipTerms(terms);
    _ensureCorrectNative(creationFee + TermsLib.totalNativeAmount(terms.partyAssets));

    address quip = _deployQuip(lock, _msgSender());
    IQuip(quip).initializeCoupled(lock, TermsLib.digestTerms(terms));

    accumulatedFees += creationFee;
    TermsLib.transferAssets(terms.partyAssets, _msgSender(), quip);

    emit QuipCreated(lock, quip, terms);
  }

  /// @notice creates a new uncoupled quip proposal with party terms only
  /// @dev Salt for deterministic deployment is keccak256(lock, msg.sender) to allow
  ///      same-chain swaps where both parties deploy with the same lock
  /// @param lock the hash of the secret used for deterministic deployment
  /// @param terms the party terms of the quip proposal
  function deployUncoupledQuip(bytes32 lock, PartyTerms calldata terms) external payable {
    _enforceValidLock(lock);
    _validatePartyTerms(terms);
    // right now only fee needs to be paid; no forwarding here
    _ensureCorrectNative(creationFee);

    address quip = _deployQuip(lock, _msgSender());
    IQuip(quip).initializeUncoupled(lock, TermsLib.digestPartyTerms(terms));

    accumulatedFees += creationFee;

    emit QuipProposed(lock, quip, terms);
  }

  /// @notice withdraws accumulated fees to the given receiver
  /// @param receiver the address to receive the fees
  /// @param amount the amount of fees to withdraw
  function withdrawFees(address receiver, uint256 amount) external onlyAdmin {
    if (amount > accumulatedFees) {
      revert InsufficientFees();
    }
    accumulatedFees -= amount;
    SafeTransferLib.safeTransferETH(receiver, amount);

    emit FeesWithdrawn(receiver, amount);
  }

  /// @notice updates the creation fee
  /// @param newFee the new creation fee
  function setCreationFee(uint256 newFee) external onlyAdmin {
    if (newFee > MAX_FEE) revert FeeExceedsMax();
    creationFee = newFee;

    emit CreationFeeUpdated(newFee);
  }

  /// @notice marks a lock as spent, callable only by quip contracts deployed by this portal
  /// @dev Called by Quip.claim() and Quip.reclaim() to transition lock state.
  ///      Idempotent: if already Spent, this is a no-op (supports same-chain swaps
  ///      where both quips may claim/reclaim).
  /// @param lock the lock to mark as spent
  function spendLock(bytes32 lock) external {
    // Verify caller is a quip clone deployed by this portal
    // The clone stores this portal's address as immutable args in bytecode
    _enforceQuipCaller();

    LockState currentState = lockState[lock];

    // Only transition if Free; Spent is terminal and idempotent
    if (currentState == LockState.Free) {
      lockState[lock] = LockState.Spent;
      emit SpentLock(lock, _msgSender());
    }
    // If already Spent, no-op (idempotent for same-chain swaps)
    // If Unused, this shouldn't happen (quip shouldn't exist), but we don't revert
  }

  /// @notice deploys a new quip clone using keccak256(lock, deployer) as the salt
  /// @dev Using (lock, deployer) as salt enables same-chain swaps where both parties
  ///      deploy with the same lock but get unique quip addresses.
  ///      On first deployment, captures the clone's codehash for future verification.
  /// @param lock the lock hash
  /// @param deployer the address deploying the quip
  /// @return quip the address of the deployed quip
  function _deployQuip(bytes32 lock, address deployer) internal returns (address quip) {
    bytes32 salt = keccak256(abi.encodePacked(lock, deployer));
    // Factory address is encoded in bytecode, salt uniquifies the deployment address
    quip = LibClone.cloneDeterministic(QUIP_IMPLEMENTATION, abi.encode(address(this)), salt);

    // Capture codehash on first deployment for future caller verification
    // All clones have identical runtime bytecode, so one codehash validates all
    if (QUIP_CODEHASH == bytes32(0)) {
      QUIP_CODEHASH = quip.codehash;
    }
  }

  /// @notice reverts if msg.value does not match the expected amount
  /// @param amount the expected native amount
  function _ensureCorrectNative(uint256 amount) internal view {
    if (msg.value != amount) {
      revert IncorrectNativeAmount();
    }
  }

  /// @notice validates the lock and transitions its state
  /// @dev State transitions: Unused → Free → Spent
  ///      Reverts if lock is empty or already Spent
  /// @param lock the lock to validate and transition
  function _enforceValidLock(bytes32 lock) internal {
    if (lock == bytes32(0)) revert EmptyLock();

    LockState currentState = lockState[lock];
    if (currentState == LockState.Spent) revert LockSpent();

    // Transition: Unused → Free, Free → Spent
    lockState[lock] = currentState == LockState.Unused ? LockState.Free : LockState.Spent;
  }

  /// @notice reverts if the address is the zero address
  /// @param addr the address to validate
  function _enforceNonEmptyAddress(address addr) internal pure {
    if (addr == address(0)) revert EmptyAddress();
  }

  /// @notice validates the quip terms provided during creation
  /// @param terms the terms to validate
  function _validateQuipTerms(QuipTerms calldata terms) internal view {
    if (terms.party == address(0) || terms.counterparty == address(0)) revert EmptyParty();
    if (terms.partyRecipient == address(0) || terms.counterpartyRecipient == address(0)) revert EmptyRecipient();
    if (terms.partyExpiry <= block.timestamp || terms.counterpartyExpiry <= block.timestamp) revert InvalidExpiry();
    if (terms.partyAssets.length == 0 || terms.counterpartyAssets.length == 0) revert EmptyAssets();

    uint256 partyAssetsLength = terms.partyAssets.length;
    for (uint256 i; i < partyAssetsLength; ++i) {
      TermsLib.validateAsset(terms.partyAssets[i]);
    }

    uint256 counterpartyAssetsLength = terms.counterpartyAssets.length;
    for (uint256 i; i < counterpartyAssetsLength; ++i) {
      TermsLib.validateAsset(terms.counterpartyAssets[i]);
    }
  }

  /// @notice reverts if the caller is not the admin
  function _onlyAdmin() internal view {
    if (_msgSender() != admin) {
      revert NotAdmin();
    }
  }

  /// @notice reverts if the caller is not a quip clone deployed by this portal
  /// @dev Verifies caller's codehash matches the expected codehash of valid quip clones.
  ///      All clones from this portal have identical runtime bytecode (same implementation
  ///      + same immutable args), so they share the same codehash.
  function _enforceQuipCaller() internal view {
    if (_msgSender().codehash != QUIP_CODEHASH) revert CallerNotQuip();
  }

  /// @notice validates the party terms provided during uncoupled quip creation
  /// @param terms the party terms to validate
  function _validatePartyTerms(PartyTerms calldata terms) internal view {
    if (terms.signatory == address(0)) revert EmptyParty();
    if (terms.recipient == address(0)) revert EmptyRecipient();
    if (terms.expiry <= block.timestamp) revert InvalidExpiry();
    if (terms.assets.length == 0) revert EmptyAssets();

    uint256 assetsLength = terms.assets.length;
    for (uint256 i; i < assetsLength; ++i) {
      TermsLib.validateAsset(terms.assets[i]);
    }
  }
}
