// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {
  IERC7913SignatureVerifier
} from '@quip.network/hashsigs-solidity-0.2.0/contracts/interfaces/IERC7913SignatureVerifier.sol';

contract DigestVerifierMock is IERC7913SignatureVerifier {
  bytes32 public constant VERSION_TAG = keccak256('quip.shrincs-verifier.v1');
  bytes32 public constant PROFILE_TAG = keccak256('shrincs-256s-keccak');

  function verify(bytes calldata key, bytes32 digest, bytes calldata signature) external pure returns (bytes4) {
    if (key.length != 0 && keccak256(signature) == keccak256(abi.encode(digest))) {
      return IERC7913SignatureVerifier.verify.selector;
    }
    return 0xffffffff;
  }
}
