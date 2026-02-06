// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Asset, QuipTerms} from '../TermsLib.sol';

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
  /// @notice thrown when the provided key does not match the lock
  error InvalidKey();

  /// @notice emitted when the party commits their assets to a quip
  /// @param termsDigest hash terms of the quip agreement
  event PartyCommitment(bytes32 termsDigest);

  /// @notice emitted when the party's terms are fulfilled
  /// @param key secret used to create the lock hash
  /// @param recipient the address that received the assets
  /// @param assets the assets that were transferred
  event PartyTermsFulfilled(bytes key, address indexed recipient, Asset[] assets);

  /// @notice emitted when the party reclaims their assets after expiry
  /// @param recipient the address that received the assets
  /// @param assets the assets that were transferred
  event PartyUnbound(address indexed recipient, Asset[] assets);

  /// @notice returns the version of this quip
  /// @return the version number stored as an immutable clone argument
  function version() external view returns (uint256);

  /// @notice initializes the quip with a secret digest and terms
  /// @param lock the hash of the secret
  /// @param termsDigest the hashed terms of the quip agreement
  function initialize(bytes32 lock, bytes32 termsDigest) external;

  /// @notice claims the party's assets by providing the key and terms
  /// @param key the secret that unlocks the quip
  /// @param terms the terms of the quip agreement
  function claim(bytes calldata key, QuipTerms calldata terms) external;

  /// @notice reclaims the party's assets after the terms have expired
  /// @param terms the terms of the quip agreement
  function reclaim(QuipTerms calldata terms) external;
}
