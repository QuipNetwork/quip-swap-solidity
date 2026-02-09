// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {PartyTerms, QuipTerms, TermsLib} from './TermsLib.sol';
import {IQuip} from './interfaces/IQuip.sol';
import {IQuipPortal} from './interfaces/IQuipPortal.sol';
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

  /// @notice tracks whether a lock hash has been used
  mapping(bytes32 lock => bool isSpent) public isLockSpent;

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

  /// TODO: forward ETH via deterministic deployment
  /// @notice creates a new quip with the given lock and terms
  /// @param lock the hash of the secret used for deterministic deployment
  /// @param terms the terms of the quip agreement
  function deployCoupledQuip(bytes32 lock, QuipTerms calldata terms) external payable {
    _enforceValidLock(lock);
    _validateQuipTerms(terms);
    _ensureCorrectNative(creationFee + TermsLib.totalNativeAmount(terms.partyAssets));

    address quip = _deployQuip(lock);
    IQuip(quip).initializeCoupled(lock, TermsLib.digestTerms(terms));

    accumulatedFees += creationFee;
    isLockSpent[lock] = true;
    TermsLib.transferAssets(terms.partyAssets, _msgSender(), quip);

    emit QuipCreated(quip, terms);
  }

  /// @notice creates a new uncoupled quip proposal with party terms only
  /// @param lock the hash of the secret used for deterministic deployment
  /// @param terms the party terms of the quip proposal
  function deployUncoupledQuip(bytes32 lock, PartyTerms calldata terms) external payable {
    _enforceValidLock(lock);
    _validatePartyTerms(terms);
    // right now only fee needs to be paid; no forwarding here
    _ensureCorrectNative(creationFee);

    address quip = _deployQuip(lock);
    IQuip(quip).initializeUncoupled(lock, TermsLib.digestPartyTerms(terms));

    isLockSpent[lock] = true;
    accumulatedFees += creationFee;

    emit QuipProposed(quip, terms);
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

  /// @notice deploys a new quip clone using the lock as the salt
  /// @param lock the salt for deterministic deployment
  /// @return quip the address of the deployed quip
  function _deployQuip(bytes32 lock) internal returns (address quip) {
    // TODO: verify this is actually unique
    // encoded args are not unique, but are constant across QUIPs so can be written to bytecode
    // lock uniquifies address
    quip = LibClone.cloneDeterministic(QUIP_IMPLEMENTATION, abi.encode(VERSION), lock);
  }

  /// @notice reverts if msg.value does not match the expected amount
  /// @param amount the expected native amount
  function _ensureCorrectNative(uint256 amount) internal view {
    if (msg.value != amount) {
      revert IncorrectNativeAmount();
    }
  }

  /// @notice reverts if the lock is empty or has already been used
  /// @param lock the lock to validate
  function _enforceValidLock(bytes32 lock) internal view {
    if (lock == bytes32(0)) revert EmptyLock();
    if (isLockSpent[lock]) revert LockSpent();
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

  /// @notice validates the party terms provided during uncoupled quip creation
  /// @param terms the party terms to validate
  function _validatePartyTerms(PartyTerms calldata terms) internal view {
    if (terms.party == address(0)) revert EmptyParty();
    if (terms.partyRecipient == address(0)) revert EmptyRecipient();
    if (terms.partyExpiry <= block.timestamp) revert InvalidExpiry();
    if (terms.partyAssets.length == 0) revert EmptyAssets();

    uint256 partyAssetsLength = terms.partyAssets.length;
    for (uint256 i; i < partyAssetsLength; ++i) {
      TermsLib.validateAsset(terms.partyAssets[i]);
    }
  }
}
