// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {QuipTerms, TermsLib} from './TermsLib.sol';
import {IQuip} from './interfaces/IQuip.sol';
import {Context} from '@openzeppelin-contracts-5.6.0-rc.1/utils/Context.sol';
import {EfficientHashLib} from 'solady-0.1.26/utils/EfficientHashLib.sol';
import {Initializable} from 'solady-0.1.26/utils/Initializable.sol';
import {LibClone} from 'solady-0.1.26/utils/LibClone.sol';

contract Quip is Context, Initializable, IQuip {
  bytes32 public lock;
  bytes32 public termsDigest;

  /// @notice returns the version of this quip, stored as an immutable clone argument
  function version() public view returns (uint256) {
    return abi.decode(LibClone.argsOnClone(address(this), 0, 32), (uint256));
  }

  /// @notice initializes the quip with a lock and terms
  /// @param _lock the hash of the secret
  /// @param _termsDigest the hashed terms of the quip agreement
  function initialize(bytes32 _lock, bytes32 _termsDigest) external initializer {
    lock = _lock;
    termsDigest = _termsDigest;

    emit PartyCommitment(_termsDigest);
  }

  /// @notice claims the party's assets by providing the key and terms
  /// @param key the secret that unlocks the quip
  /// @param terms the terms of the quip agreement
  function claim(bytes calldata key, QuipTerms calldata terms) external {
    _verifyKey(key);
    TermsLib.verifyTerms(termsDigest, terms);
    TermsLib.enforceTermFreshness(terms.partyExpiry);
    TermsLib.fulfillPartyTerms(address(this), terms);

    emit PartyTermsFulfilled(key, terms.counterpartyRecipient, terms.partyAssets);
  }

  /// @notice reverts if the provided key does not match the lock
  /// @param key the key to verify
  function _verifyKey(bytes calldata key) internal view {
    if (EfficientHashLib.hash(key) != lock) {
      revert InvalidKey();
    }
  }
}
