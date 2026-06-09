// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Omnibus} from '../../src/Omnibus.sol';
import {Terms, TermsLib} from '../../src/TermsLib.sol';
import {LockState} from '../../src/interfaces/IOmnibus.sol';

/// @title Omnibus Harness
/// @dev Wrapper contract to expose Omnibus internal functions for testing
contract OmnibusHarness is Omnibus {
  /// @notice initializes the harness with an owner
  /// @param initialOwner the address that will own the contract
  constructor(address initialOwner) Omnibus(initialOwner) {}

  /// @notice exposes _advanceLockTo
  function exposed_advanceLockTo(bytes32 lock, LockState current, LockState to) external {
    _advanceLockTo(lock, current, to);
  }

  /// @notice exposes _enforceSameTerms
  function exposed_enforceSameTerms(bytes32 expected, bytes32 actual) external pure {
    _enforceSameTerms(expected, actual);
  }

  /// @notice exposes _enforceCorrectNative
  function exposed_enforceCorrectNative(uint256 expected) external payable {
    _enforceCorrectNative(expected);
  }

  /// @notice exposes _enforceCommittedLock
  function exposed_enforceCommittedLock(LockState current) external pure {
    _enforceCommittedLock(current);
  }

  /// @notice exposes _enforcePosted
  function exposed_enforcePosted(bytes32 lock, bytes32 termsDigest) external view {
    _enforcePosted(lock, termsDigest);
  }

  /// @notice helper to set lock state directly for testing
  function setLockState(bytes32 lock, LockState state) external {
    lockState[lock] = state;
  }

  /// @notice helper to set terms hash directly for testing
  function setTermsHash(bytes32 lock, bytes32 hash) external {
    termsHash[lock] = hash;
  }

  /// @notice helper to set a posted bit directly for testing
  function setPosted(bytes32 lock, bytes32 termsDigest, bool value) external {
    posted[lock][termsDigest] = value;
  }

  /// @notice helper to compute terms hash (exposed for testing)
  function computeTermsHash(Terms calldata party, Terms calldata counterparty) external pure returns (bytes32) {
    return TermsLib.digestTermsCanonically(party, counterparty);
  }

  /// @notice helper to compute a single side's terms digest (exposed for testing)
  function computeTermsDigest(Terms calldata terms) external pure returns (bytes32) {
    return TermsLib.digestTerms(terms);
  }

  /// @notice exposes _generateLock
  function exposed_generateLock(bytes32 secret) external pure returns (bytes32) {
    return _generateLock(secret);
  }
}
