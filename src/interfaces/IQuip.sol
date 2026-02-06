// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {QuipTerms} from '../TermsLib.sol';

/// @notice the status of a quip
enum Status {
  Open,
  Accepted,
  Committed,
  Claimed,
  Reclaimed,
  Slashed
}

interface IQuip {
  /// @notice emitted when the party commits their assets to a quip
  /// @param termsDigest hash terms of the quip agreement
  event PartyCommitment(bytes32 termsDigest);

  /// @notice returns the version of this quip
  /// @return the version number stored as an immutable clone argument
  function version() external view returns (uint256);

  /// @notice initializes the quip with a secret digest and terms
  /// @param lock the hash of the secret
  /// @param termsDigest the hashed terms of the quip agreement
  function initialize(bytes32 lock, bytes32 termsDigest) external;
}
