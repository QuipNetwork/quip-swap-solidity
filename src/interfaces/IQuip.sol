// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Asset, PartyTerms, QuipTerms} from '../TermsLib.sol';

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

  /// @notice thrown when an operation is invalid for the current state
  error InvalidOperation();

  /// @notice thrown when the commitment value is insufficient
  error InsufficientCommitment();

  /// @notice thrown when caller is not authorized for the operation
  error UnauthorizedCaller();

  /// @notice thrown when bytecode portal doesn't match predetermined portal
  error PortalMismatch();

  /// @notice thrown when caller is not the portal
  error CallerNotPortal();

  /// @notice emitted when the party commits their assets to a quip
  /// @param lock the hash of the secret
  /// @param termsDigest hash terms of the quip agreement
  event PartyCommitment(bytes32 indexed lock, bytes32 termsDigest);

  /// @notice emitted when a party proposes uncoupled terms
  /// @param lock the hash of the secret
  /// @param termsDigest hash of the party terms
  event PartyProposal(bytes32 indexed lock, bytes32 termsDigest);

  /// @notice emitted when a quip is committed (coupled)
  /// @param termsDigest hash of the coupled terms
  event QuipCommitted(bytes32 termsDigest);

  /// @notice emitted when the party's terms are fulfilled
  /// @param key secret used to create the lock hash
  /// @param recipient the address that received the assets
  /// @param assets the assets that were transferred
  event PartyTermsFulfilled(bytes key, address indexed recipient, Asset[] assets);

  /// @notice emitted when the party reclaims their assets after expiry
  /// @param recipient the address that received the assets
  /// @param assets the assets that were transferred
  event PartyUnbound(address indexed recipient, Asset[] assets);

  /// @notice returns the version of this quip implementation
  /// @return the version number
  function VERSION() external view returns (uint256);

  /// @notice returns the portal that deployed this quip from bytecode
  /// @return the portal address stored as an immutable clone argument
  function PORTAL_FROM_BYTECODE() external view returns (address);

  /// @notice initializes the quip with a lock and coupled terms
  /// @param lock the hash of the secret
  /// @param termsDigest the hashed terms of the quip agreement
  function initializeCoupled(bytes32 lock, bytes32 termsDigest) external;

  /// @notice initializes the quip with a lock and uncoupled party terms
  /// @param lock the hash of the secret
  /// @param termsDigest the hashed party terms
  function initializeUncoupled(bytes32 lock, bytes32 termsDigest) external;

  /// @notice couples an uncoupled quip with counterparty terms
  /// @param party the initiating party's terms
  /// @param counterparty the counterparty's terms
  /// @param termsDigest the digest to verify against stored terms
  function coupleQuip(PartyTerms calldata party, PartyTerms calldata counterparty, bytes32 termsDigest) external payable;

  /// @notice claims the party's assets by providing the key and terms
  /// @param key the secret that unlocks the quip
  /// @param terms the terms of the quip agreement
  function claim(bytes calldata key, QuipTerms calldata terms) external;

  /// @notice reclaims the party's assets after the terms have expired
  /// @param terms the terms of the quip agreement
  function reclaim(QuipTerms calldata terms) external;
}
