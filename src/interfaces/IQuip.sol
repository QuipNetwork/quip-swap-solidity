// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Asset} from '../AssetLib.sol';

/// @notice the status of a quip
enum Status {
  Open,
  Accepted,
  Committed,
  Claimed,
  Reclaimed,
  Slashed
}

/// @notice the terms of a quip agreement
struct QuipTerms {
  /// @notice the address that creates the quip
  address party;
  /// @notice the address that receives the counterparty's assets
  address partyRecipient;
  /// @notice the address that accepts the quip
  address counterparty;
  /// @notice the address that receives the party's assets
  address counterpartyRecipient;
  /// @notice the deadline for the party to commit
  uint64 partyExpiry;
  /// @notice the deadline for the counterparty to accept
  uint64 counterpartyExpiry;
  /// @notice the assets offered by the party
  Asset[] partyAssets;
  /// @notice the assets offered by the counterparty
  Asset[] counterpartyAssets;
}

interface IQuip {
  /// @notice emitted when the party commits their assets to a quip
  event PartyCommitment(QuipTerms terms);

  /// @notice returns the version of this quip
  /// @return the version number stored as an immutable clone argument
  function version() external view returns (uint256);

  /// @notice initializes the quip with a secret digest and terms
  /// @param lock the hash of the secret
  /// @param terms the terms of the quip agreement
  function initialize(bytes32 lock, QuipTerms calldata terms) external;
}
