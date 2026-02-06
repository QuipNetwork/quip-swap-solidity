// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {IQuip} from './interfaces/IQuip.sol';
import {QuipTerms} from './interfaces/IQuip.sol';
import {IQuipPortal} from './interfaces/IQuipPortal.sol';
import {Context} from '@openzeppelin-contracts-5.6.0-rc.1/utils/Context.sol';
import {LibClone} from 'solady-0.1.26/utils/LibClone.sol';
import {SafeTransferLib} from 'solady-0.1.26/utils/SafeTransferLib.sol';

contract QuipPortal is Context, IQuipPortal {
  uint256 public constant VERSION = 1;
  uint256 public immutable MAX_FEE;
  uint256 public creationFee;
  address public admin;
  address immutable QUIP_IMPLEMENTATION;
  mapping(bytes32 digest => bool ispent) public isDigestSpent;

  modifier onlyAdmin() {
    if (_msgSender() != admin) {
      revert NotAdmin();
    }
    _;
  }

  constructor(address firstAdmin, address quipImpl, uint256 maxFee, uint256 _creationFee) {
    if (_creationFee > maxFee) revert FeeExceedsMax();
    QUIP_IMPLEMENTATION = quipImpl;
    MAX_FEE = maxFee;
    admin = firstAdmin;
    creationFee = _creationFee;
  }

  function createQuip(bytes32 secretDigest, QuipTerms calldata terms) external payable {
    _ensureFeePayment();
    _enforceValidSecret(secretDigest);
    _validateQuipCreation(terms);

    address quip = _deployQuip(secretDigest);

    IQuip(quip).initialize(secretDigest, terms);

    emit QuipCreated(quip);
  }

  function withdrawFees(address receiver, uint256 amount) external onlyAdmin {
    SafeTransferLib.safeTransferETH(receiver, amount);

    emit FeesWithdrawn(receiver, amount);
  }

  function setCreationFee(uint256 newFee) external onlyAdmin {
    if (newFee > MAX_FEE) revert FeeExceedsMax();
    creationFee = newFee;

    emit CreationFeeUpdated(newFee);
  }

  function _deployQuip(bytes32 secretDigest) internal returns (address quip) {
    quip = LibClone.cloneDeterministic(QUIP_IMPLEMENTATION, abi.encode(VERSION), secretDigest);
  }

  function _ensureFeePayment() internal view {
    if (msg.value != creationFee) {
      revert InvalidFee();
    }
  }

  function _enforceValidSecret(bytes32 digest) internal view {
    if (digest == bytes32(0)) {
      revert DigestEmpty();
    }

    if (isDigestSpent[digest]) {
      revert SecretNotFresh();
    }
  }

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
  }
}
