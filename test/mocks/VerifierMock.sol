// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {
  IERC7913SignatureVerifier
} from '@quip.network/hashsigs-solidity-0.2.0/contracts/interfaces/IERC7913SignatureVerifier.sol';

/// @title ERC-7913 Verifier Mock
/// @dev test double for the keyed commit route. `verify` is `view` and reached by
/// STATICCALL, so the mock cannot RECORD calls — tests are expectation-based
/// instead: prime a mode (and, for AcceptMatching, the expected inputs) BEFORE the
/// commit and assert on the commit's outcome. Deploy two instances to test
/// per-verifier trust independence.
contract VerifierMock is IERC7913SignatureVerifier {
  enum Mode {
    /// @notice returns the magic value for any input
    AcceptAll,
    /// @notice returns the magic value iff (key, hash, signature) equal the primed expectation
    AcceptMatching,
    /// @notice returns 0xffffffff for any input
    RejectAll,
    /// @notice reverts for any input
    RevertAll,
    /// @notice returns a non-magic, non-0xffffffff selector
    WrongMagic
  }

  Mode public mode;

  // AcceptMatching expectation (primed via prime())
  bytes32 public expectedKeyHash;
  bytes32 public expectedHash;
  bytes32 public expectedSignatureHash;

  bytes4 private constant INVALID_SIGNATURE = 0xffffffff;

  function setMode(Mode newMode) external {
    mode = newMode;
  }

  /// @notice primes the AcceptMatching expectation (hashes, so any-length inputs work)
  function prime(bytes calldata key, bytes32 hash, bytes calldata signature) external {
    expectedKeyHash = keccak256(key);
    expectedHash = hash;
    expectedSignatureHash = keccak256(signature);
  }

  function verify(bytes calldata key, bytes32 hash, bytes calldata signature) external view returns (bytes4) {
    if (mode == Mode.AcceptAll) return IERC7913SignatureVerifier.verify.selector;
    if (mode == Mode.AcceptMatching) {
      bool matches =
        keccak256(key) == expectedKeyHash && hash == expectedHash && keccak256(signature) == expectedSignatureHash;
      return matches ? IERC7913SignatureVerifier.verify.selector : INVALID_SIGNATURE;
    }
    if (mode == Mode.RejectAll) return INVALID_SIGNATURE;
    if (mode == Mode.RevertAll) revert('VerifierMock: revert mode');
    // WrongMagic: a plausible-but-wrong selector must NOT be treated as valid
    return bytes4(0x12345678);
  }
}
