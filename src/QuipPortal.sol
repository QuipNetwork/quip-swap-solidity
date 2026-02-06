// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {AssetLib} from './AssetLib.sol';
import {IQuip, QuipTerms} from './interfaces/IQuip.sol';
import {IQuipPortal} from './interfaces/IQuipPortal.sol';
import {Context} from '@openzeppelin-contracts-5.6.0-rc.1/utils/Context.sol';
import {LibClone} from 'solady-0.1.26/utils/LibClone.sol';
import {SafeTransferLib} from 'solady-0.1.26/utils/SafeTransferLib.sol';

contract QuipPortal is Context, IQuipPortal {
  uint256 public constant VERSION = 1;
  uint256 public immutable MAX_FEE;
  uint256 public creationFee;
  uint256 public accumulatedFees;
  address public admin;
  address immutable QUIP_IMPLEMENTATION;
  mapping(bytes32 lock => bool ispent) public isLockSpent;

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
    if (_creationFee > maxFee) revert FeeExceedsMax();
    QUIP_IMPLEMENTATION = quipImpl;
    MAX_FEE = maxFee;
    admin = firstAdmin;
    creationFee = _creationFee;
  }

  /// @notice creates a new quip with the given secret digest and terms
  /// @param lock the hash of the secret used for deterministic deployment
  /// @param terms the terms of the quip agreement
  function createQuip(bytes32 lock, QuipTerms calldata terms) external payable {
    _enforceValidLock(lock);
    _validateQuipCreation(terms);
    _ensureCorrectNative(creationFee + AssetLib.totalNativeAmount(terms.partyAssets));

    address quip = _deployQuip(lock);
    IQuip(quip).initialize(lock, _digestTerms(terms));

    accumulatedFees += creationFee;
    AssetLib.transferAssets(terms.partyAssets, _msgSender(), quip);

    emit QuipCreated(quip, terms);
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

  /// @notice deploys a new quip clone using the secret digest as the salt
  /// @param lock the salt for deterministic deployment
  /// @return quip the address of the deployed quip
  function _deployQuip(bytes32 lock) internal returns (address quip) {
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

  /// @notice validates the quip terms provided during creation
  /// @param quip the terms to validate
  function _validateQuipCreation(QuipTerms calldata quip) internal view {
    if (quip.party == address(0) || quip.counterparty == address(0)) revert EmptyParty();
    if (quip.partyRecipient == address(0) || quip.counterpartyRecipient == address(0)) revert EmptyRecipient();
    if (quip.partyExpiry <= block.timestamp || quip.counterpartyExpiry <= block.timestamp) revert InvalidExpiry();
    if (quip.partyAssets.length == 0 || quip.counterpartyAssets.length == 0) revert EmptyAssets();

    for (uint256 i; i < quip.partyAssets.length; ++i) {
      AssetLib.validateAsset(quip.partyAssets[i]);
    }

    for (uint256 i; i < quip.counterpartyAssets.length; ++i) {
      AssetLib.validateAsset(quip.counterpartyAssets[i]);
    }
  }

  function _onlyAdmin() internal view {
    if (_msgSender() != admin) {
      revert NotAdmin();
    }
  }

  /// @notice computes the keccak256 digest of quip terms
  /// @param _terms the terms to hash
  /// @return digest the keccak256 hash of the encoded terms
  function _digestTerms(QuipTerms calldata _terms) internal pure returns (bytes32 digest) {
    digest = keccak256(
      abi.encode(
        _terms.party,
        _terms.partyRecipient,
        _terms.counterparty,
        _terms.counterpartyRecipient,
        _terms.partyExpiry,
        _terms.counterpartyExpiry,
        _terms.partyAssets,
        _terms.counterpartyAssets
      )
    );
  }
}
