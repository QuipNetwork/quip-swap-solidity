// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {
  IERC7913SignatureVerifier
} from '@quip.network/hashsigs-solidity-0.2.0/contracts/interfaces/IERC7913SignatureVerifier.sol';

/// @title KeyedVerifier
/// @notice Safely dispatches an ERC-7913 signature check from verifier-prefixed key bytes.
/// @dev Returns false, rather than bubbling verifier failures or malformed return data.
library KeyedVerifier {
  /// @notice Verifies a digest against verifier-address || key-material encoding.
  function isValid(bytes memory keyedVerifier, bytes32 digest, bytes memory signature) internal view returns (bool) {
    // A keyed verifier must contain an address prefix and nonempty key material.
    if (keyedVerifier.length <= 20) return false;
    // Decode the first 20 bytes as the verifier contract.
    address verifier;
    assembly ('memory-safe') { verifier := shr(96, mload(add(keyedVerifier, 32))) }
    if (verifier.code.length == 0) return false;
    // Copy only the suffix passed as ERC-7913 key material.
    bytes memory key = new bytes(keyedVerifier.length - 20);
    for (uint256 i; i < key.length; ++i) {
      key[i] = keyedVerifier[i + 20];
    }
    // Staticcall prevents a verifier from mutating state during signature checks.
    (bool success, bytes memory returnData) =
      verifier.staticcall(abi.encodeCall(IERC7913SignatureVerifier.verify, (key, digest, signature)));
    // Require the exact ABI shape before reading the return word.
    if (!success || returnData.length != 32) return false;
    bytes32 result;
    assembly ('memory-safe') { result := mload(add(returnData, 32)) }
    // ERC-7913 success is its function selector, not a boolean.
    return result == bytes32(IERC7913SignatureVerifier.verify.selector);
  }
}
