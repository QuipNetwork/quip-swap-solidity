// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {IQuip, QuipTerms} from './interfaces/IQuip.sol';
import {Context} from '@openzeppelin-contracts-5.6.0-rc.1/utils/Context.sol';
import {Initializable} from 'solady-0.1.26/utils/Initializable.sol';
import {LibClone} from 'solady-0.1.26/utils/LibClone.sol';

contract Quip is Context, Initializable, IQuip {
  bytes32 public secretDigest;
  bytes32 public termsDigest;
  QuipTerms public terms;

  function version() public view returns (uint256) {
    return abi.decode(LibClone.argsOnClone(address(this), 0, 32), (uint256));
  }

  function initialize(bytes32 _secretDigest, QuipTerms calldata _terms) external initializer {
    secretDigest = _secretDigest;
    terms = _terms;
  }

  function _extractTermDigest(QuipTerms calldata _terms) internal pure returns (bytes32 digest) {
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
