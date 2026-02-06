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
  mapping(bytes32 digest => bool ispent) public isDigestSpent;

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
  /// @param secretDigest the hash of the secret used for deterministic deployment
  /// @param terms the terms of the quip agreement
  function createQuip(bytes32 secretDigest, QuipTerms calldata terms) external payable {
    _enforceValidSecret(secretDigest);
    _validateQuipCreation(terms);
    _ensureCorrectNative(creationFee + AssetLib.totalNativeAmount(terms.partyAssets));

    address quip = _deployQuip(secretDigest);
    IQuip(quip).initialize(secretDigest, terms);

    accumulatedFees += creationFee;
    AssetLib.transferAssets(terms.partyAssets, _msgSender(), quip);

    emit QuipCreated(quip);
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
  /// @param secretDigest the salt for deterministic deployment
  /// @return quip the address of the deployed quip
  function _deployQuip(bytes32 secretDigest) internal returns (address quip) {
    quip = LibClone.cloneDeterministic(QUIP_IMPLEMENTATION, abi.encode(VERSION), secretDigest);
  }

  /// @notice reverts if msg.value does not match the expected amount
  /// @param amount the expected native amount
  function _ensureCorrectNative(uint256 amount) internal view {
    if (msg.value != amount) {
      revert IncorrectNativeAmount();
    }
  }

  /// @notice reverts if the secret digest is empty or has already been used
  /// @param digest the secret digest to validate
  function _enforceValidSecret(bytes32 digest) internal view {
    if (digest == bytes32(0)) {
      revert DigestEmpty();
    }

    if (isDigestSpent[digest]) {
      revert SecretNotFresh();
    }
  }

  /// @notice validates the quip terms provided during creation
  /// @param quip the terms to validate
  function _validateQuipCreation(QuipTerms calldata quip) internal pure {
    if (quip.party == address(0)) {
      revert NoParty();
    }

    if (quip.partyRecipient == address(0)) {
      revert NoPartyRecipient();
    }

    if (quip.partyExpiry == 0) {
      revert NoPartyExpiry();
    }

    if (quip.partyAssets.length == 0) {
      revert NoPartyAssets();
    }

    for (uint256 i; i < quip.partyAssets.length; ++i) {
      AssetLib.validateAsset(quip.partyAssets[i]);
    }

    if (quip.counterparty == address(0)) {
      revert NoCounterparty();
    }

    if (quip.counterpartyRecipient == address(0)) {
      revert NoCounterpartyRecipient();
    }

    if (quip.counterpartyExpiry == 0) {
      revert NoCounterpartyExpiry();
    }

    if (quip.counterpartyAssets.length == 0) {
      revert NoCounterpartyAssets();
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
}
