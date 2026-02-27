// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Asset, PartyTerms, QuipTerms} from '../TermsLib.sol';
import {WOTSPlus} from '@quip.network/hashsigs-solidity-0.1.0/contracts/WOTSPlus.sol';

interface IQuip {
  /// @notice thrown when the provided signature is invalid
  error InvalidSignature();

  /// @notice thrown when an operation is invalid for the current state
  error InvalidOperation();

  /// @notice thrown when the commitment value is insufficient
  error InsufficientCommitment();

  /// @notice thrown when caller is not authorized for the operation
  error UnauthorizedCaller();

  /// @notice thrown when caller is not the portal
  error CallerNotPortal();

  /// @notice emitted when the party commits their assets to a quip
  /// @param pqOwnerHash the hash of the WOTS+ public key
  /// @param termsDigest hash terms of the quip agreement
  event PartyCommitment(bytes32 indexed pqOwnerHash, bytes32 termsDigest);

  /// @notice emitted when a party proposes uncoupled terms
  /// @param pqOwnerHash the hash of the WOTS+ public key
  /// @param termsDigest hash of the party terms
  event PartyProposal(bytes32 indexed pqOwnerHash, bytes32 termsDigest);

  /// @notice emitted when a quip is committed (coupled)
  /// @param termsDigest hash of the coupled terms
  event QuipCommitted(bytes32 termsDigest);

  /// @notice emitted when the party's terms are fulfilled
  /// @param signature WOTS+ signature that authorized the claim
  /// @param recipient the address that received the assets
  /// @param assets the assets that were transferred
  event PartyTermsFulfilled(WOTSPlus.WinternitzElements signature, address indexed recipient, Asset[] assets);

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

  /// @notice returns the WOTS+ public key that secures this quip
  /// @return publicSeed the public seed of the WOTS+ key
  /// @return publicKeyHash the hash of the public key segments
  function pqOwner() external view returns (bytes32 publicSeed, bytes32 publicKeyHash);

  /// @notice returns the hash of the WOTS+ public key
  /// @return the EfficientHashLib hash of (publicSeed, publicKeyHash)
  function pqOwnerHash() external view returns (bytes32);

  /// @notice initializes the quip with a WOTS+ public key and coupled terms
  /// @param _pqOwner the WOTS+ public key
  /// @param _termsDigest the canonical hashed terms of the quip agreement
  function initializeCoupled(WOTSPlus.WinternitzAddress calldata _pqOwner, bytes32 _termsDigest) external;

  /// @notice initializes the quip with a WOTS+ public key and uncoupled party terms
  /// @param _pqOwner the WOTS+ public key
  /// @param _termsDigest the hashed party terms
  function initializeUncoupled(WOTSPlus.WinternitzAddress calldata _pqOwner, bytes32 _termsDigest) external;

  /// @notice couples an uncoupled quip with counterparty terms
  /// @dev Verifies party terms against stored termsDigest, then updates to coupled terms digest
  /// @param party the initiating party's terms (must match stored digest)
  /// @param counterparty the counterparty's terms
  function coupleQuip(PartyTerms calldata party, PartyTerms calldata counterparty) external payable;

  /// @notice claims the party's assets by providing a WOTS+ signature and terms
  /// @param signature the WOTS+ signature authorizing the claim
  /// @param terms the terms of the quip agreement
  function claim(WOTSPlus.WinternitzElements calldata signature, QuipTerms calldata terms) external;

  /// @notice reclaims the party's assets after the terms have expired
  /// @param terms the terms of the quip agreement
  function reclaim(QuipTerms calldata terms) external;
}
