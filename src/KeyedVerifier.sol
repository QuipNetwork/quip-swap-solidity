// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {
  IERC7913SignatureVerifier
} from '@quip.network/hashsigs-solidity-0.2.0/contracts/interfaces/IERC7913SignatureVerifier.sol';

library KeyedVerifier {
  function isValid(bytes memory keyedVerifier, bytes32 digest, bytes memory signature) internal view returns (bool) {
    if (keyedVerifier.length <= 20) return false;
    address verifier;
    assembly ('memory-safe') { verifier := shr(96, mload(add(keyedVerifier, 32))) }
    bytes memory key = new bytes(keyedVerifier.length - 20);
    for (uint256 i; i < key.length; ++i) {
      key[i] = keyedVerifier[i + 20];
    }
    try IERC7913SignatureVerifier(verifier).verify(key, digest, signature) returns (bytes4 result) {
      return result == IERC7913SignatureVerifier.verify.selector;
    } catch {
      return false;
    }
  }
}
