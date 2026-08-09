// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {
  IERC7913SignatureVerifier
} from '@quip.network/hashsigs-solidity-0.2.0/contracts/interfaces/IERC7913SignatureVerifier.sol';

contract KeyBoundVerifierMock is IERC7913SignatureVerifier {
  function verify(bytes calldata key, bytes32 digest, bytes calldata signature) external pure returns (bytes4) {
    if (keccak256(signature) == keccak256(abi.encode(key, digest))) {
      return IERC7913SignatureVerifier.verify.selector;
    }
    return 0xffffffff;
  }
}
