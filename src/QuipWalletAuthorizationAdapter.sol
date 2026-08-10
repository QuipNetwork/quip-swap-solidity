// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {AuthorizationSubmitter} from './AuthorizationSubmitter.sol';
import {KeyedVerifier} from './KeyedVerifier.sol';
import {PQIdentityRegistry} from './PQIdentityRegistry.sol';
import {ProtocolHashing} from './ProtocolHashing.sol';
import {
  AuthorizationMode,
  CommitAuthorizationRequest,
  ExpectedSourceState,
  KeyRole,
  ProtocolTerms,
  SideTerms,
  VerifiedCommitAuthorization,
  WrapperMode
} from './ProtocolTypes.sol';
import {ICommitAuthorizationReceiver} from './interfaces/ICommitAuthorizationReceiver.sol';

contract QuipWalletAuthorizationAdapter {
  string internal constant ROTATION_DOMAIN = 'InterlockWalletKeyRotation-v1.1';
  string internal constant POSSESSION_DOMAIN = 'InterlockKeyPossession-v1.1';

  error NotOwner();
  error InvalidAuthorizationMode();
  error InvalidWalletPrincipal();
  error InvalidChain();
  error InvalidPQAuthorization();
  error InvalidKey();
  error AuthorizationExpired();
  error RotationNonceAlreadyConsumed();

  address public immutable OWNER;
  PQIdentityRegistry public immutable REGISTRY;
  bytes private activePQKey;
  uint256 public walletKeyEpoch = 1;
  mapping(bytes32 => bool) public consumedRotationNonces;

  constructor(address owner, PQIdentityRegistry registry, bytes memory initialPQKey) {
    if (owner == address(0) || initialPQKey.length <= 20) revert InvalidKey();
    OWNER = owner;
    REGISTRY = registry;
    activePQKey = initialPQKey;
  }

  function authorizeCommit(CommitAuthorizationRequest calldata request, bytes calldata signature) external {
    VerifiedCommitAuthorization memory evidence = _verify(request, signature, msg.sender);
    ICommitAuthorizationReceiver(request.receiver)
      .receiveAuthorizedCommit(
        request.terms, request.party, request.lock, request.bobCommitSecret, evidence, request.commitData
      );
  }

  function _verify(
    CommitAuthorizationRequest calldata request,
    bytes calldata signature,
    address transportCaller
  ) private view returns (VerifiedCommitAuthorization memory evidence) {
    SideTerms memory side = request.party ? request.terms.partySide : request.terms.counterpartySide;
    if (side.authorizationMode != AuthorizationMode.QuipWallet || side.principalKeyVersion != 0) {
      revert InvalidAuthorizationMode();
    }
    if (side.principal != address(this)) revert InvalidWalletPrincipal();
    if (side.chainId != block.chainid) revert InvalidChain();
    if (block.timestamp >= request.expiry) revert AuthorizationExpired();
    (bytes32 payloadHash, ExpectedSourceState sourceState) = _payload(request);
    if (!KeyedVerifier.isValid(activePQKey, payloadHash, signature)) revert InvalidPQAuthorization();
    (address submitter, uint256 submitterVersion) = AuthorizationSubmitter.derive(side, REGISTRY, transportCaller);
    evidence = VerifiedCommitAuthorization({
      payloadHash: payloadHash,
      wrapperCaller: address(this),
      authenticatedSubmitter: submitter,
      authenticatedSubmitterKeyVersion: submitterVersion,
      expectedSourceState: sourceState,
      actionNonce: request.actionNonce,
      expiry: request.expiry
    });
  }

  function rotateActiveKey(
    bytes calldata newPQKey,
    bytes32 rotationNonce,
    uint256 expiry,
    bytes calldata currentKeySignature,
    bytes calldata newKeyProof
  ) external {
    if (msg.sender != OWNER) revert NotOwner();
    if (newPQKey.length <= 20) revert InvalidKey();
    if (block.timestamp >= expiry) revert AuthorizationExpired();
    if (consumedRotationNonces[rotationNonce]) revert RotationNonceAlreadyConsumed();
    bytes32 digest = rotationDigest(newPQKey, rotationNonce, expiry);
    if (!KeyedVerifier.isValid(activePQKey, digest, currentKeySignature)) revert InvalidPQAuthorization();
    bytes32 proofDigest = keccak256(abi.encode(POSSESSION_DOMAIN, digest, KeyRole.Active, keccak256(newPQKey)));
    if (!KeyedVerifier.isValid(newPQKey, proofDigest, newKeyProof)) revert InvalidPQAuthorization();
    activePQKey = newPQKey;
    ++walletKeyEpoch;
    consumedRotationNonces[rotationNonce] = true;
  }

  function rotationDigest(bytes calldata newPQKey, bytes32 nonce, uint256 expiry) public view returns (bytes32) {
    return keccak256(
      abi.encode(
        ROTATION_DOMAIN,
        block.chainid,
        address(this),
        walletKeyEpoch,
        keccak256(activePQKey),
        walletKeyEpoch + 1,
        keccak256(newPQKey),
        nonce,
        expiry
      )
    );
  }

  function activeKeyHash() external view returns (bytes32) {
    return keccak256(activePQKey);
  }

  function _payload(CommitAuthorizationRequest calldata request)
    private
    view
    returns (bytes32 payloadHash, ExpectedSourceState sourceState)
  {
    sourceState = ProtocolHashing.expectedSourceState(request.party, ProtocolHashing.mode(request.terms));
    payloadHash = ProtocolHashing.commitPayloadHash(
      request.terms,
      request.party,
      address(this),
      request.receiver,
      request.lock,
      sourceState,
      request.actionNonce,
      request.expiry
    );
  }
}
