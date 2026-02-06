// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Asset} from './AssetLib.sol';
import {IQuip, QuipTerms} from './interfaces/IQuip.sol';
import {Context} from '@openzeppelin-contracts-5.6.0-rc.1/utils/Context.sol';
import {EfficientHashLib} from 'solady-0.1.26/utils/EfficientHashLib.sol';
import {Initializable} from 'solady-0.1.26/utils/Initializable.sol';
import {LibClone} from 'solady-0.1.26/utils/LibClone.sol';

contract Quip is Context, Initializable, IQuip {
  bytes32 public lock;
  bytes32 public termsDigest; // TODO: either termsDigest or terms must be saved; no need for both
  QuipTerms public terms;

  /// @notice returns the version of this quip, stored as an immutable clone argument
  function version() public view returns (uint256) {
    return abi.decode(LibClone.argsOnClone(address(this), 0, 32), (uint256));
  }

  /// @notice initializes the quip with a lock and terms
  /// @param _lock the hash of the secret
  /// @param _terms the terms of the quip agreement
  function initialize(bytes32 _lock, QuipTerms calldata _terms) external initializer {
    lock = _lock;
    terms = _terms;
    termsDigest = _digestTerms(_terms);

    emit PartyCommitment(terms);
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
