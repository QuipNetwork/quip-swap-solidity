// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {
  IERC7913SignatureVerifier
} from '@quip.network/hashsigs-solidity-0.2.0/contracts/interfaces/IERC7913SignatureVerifier.sol';

/// @title ERC-7913 Verifier Mock
/// @dev stateless accept-all test double: `verify` returns the magic value for
/// ANY input. Conditional behavior (reject / revert / wrong magic / exact-digest
/// matching) lives in the tests via vm.mockCall / vm.mockCallRevert. Kept as a
/// deployable contract ONLY because the SDK integration suite deploys it to
/// Anvil, where forge cheatcodes do not exist.
contract VerifierMock is IERC7913SignatureVerifier {
  function verify(bytes calldata, bytes32, bytes calldata) external pure returns (bytes4) {
    return IERC7913SignatureVerifier.verify.selector;
  }
}
