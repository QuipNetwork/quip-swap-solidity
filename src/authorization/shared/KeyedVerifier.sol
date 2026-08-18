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
    if (verifier.code.length == 0) return false;
    bytes memory key = new bytes(keyedVerifier.length - 20);
    for (uint256 i; i < key.length; ++i) {
      key[i] = keyedVerifier[i + 20];
    }
    (bool success, bytes memory returnData) =
      verifier.staticcall(abi.encodeCall(IERC7913SignatureVerifier.verify, (key, digest, signature)));
    if (!success || returnData.length != 32) return false;
    bytes32 result;
    assembly ('memory-safe') { result := mload(add(returnData, 32)) }
    return result == bytes32(IERC7913SignatureVerifier.verify.selector);
  }
}
