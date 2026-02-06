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
}
