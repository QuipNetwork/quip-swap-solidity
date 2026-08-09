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
  SideTerms,
  VerifiedCommitAuthorization
} from './ProtocolTypes.sol';
import {ICommitAuthorizationReceiver} from './interfaces/ICommitAuthorizationReceiver.sol';
import {IRegisteredCommitTarget} from './interfaces/IRegisteredCommitTarget.sol';

contract PQAuthorizationGateway is IRegisteredCommitTarget {
  error InvalidAuthorizationMode();
  error InvalidChain();
  error InvalidPQAuthorization();
  error AuthorizationExpired();
  error InvalidRegistryCaller();
  error InvalidRegisteredPrincipal();
  error RegistrationPayloadMismatch();

  PQIdentityRegistry public immutable REGISTRY;

  constructor(PQIdentityRegistry registry) {
    REGISTRY = registry;
  }

  function authorizeCommit(CommitAuthorizationRequest calldata request, bytes calldata signature) external {
    _deliver(request, _verify(request, signature, msg.sender));
  }

  function completeRegisteredCommit(
    address eoa,
    address registrationCaller,
    bytes32 registeredPayloadHash,
    bytes calldata commitData
  ) external {
    if (msg.sender != address(REGISTRY)) revert InvalidRegistryCaller();
    (CommitAuthorizationRequest memory request, bytes memory signature) =
      abi.decode(commitData, (CommitAuthorizationRequest, bytes));
    SideTerms memory side = request.party ? request.terms.partySide : request.terms.counterpartySide;
    if (side.principal != eoa) revert InvalidRegisteredPrincipal();
    VerifiedCommitAuthorization memory evidence = _verify(request, signature, registrationCaller);
    if (evidence.payloadHash != registeredPayloadHash) revert RegistrationPayloadMismatch();
    _deliver(request, evidence);
  }

  function _deliver(CommitAuthorizationRequest memory request, VerifiedCommitAuthorization memory evidence) private {
    ICommitAuthorizationReceiver(request.receiver)
      .receiveAuthorizedCommit(request.terms, request.party, request.lock, evidence, request.commitData);
  }

  function _verify(
    CommitAuthorizationRequest memory request,
    bytes memory signature,
    address transportCaller
  ) private view returns (VerifiedCommitAuthorization memory evidence) {
    SideTerms memory side = request.party ? request.terms.partySide : request.terms.counterpartySide;
    if (side.authorizationMode != AuthorizationMode.RegisteredDirect) revert InvalidAuthorizationMode();
    if (side.chainId != block.chainid) revert InvalidChain();
    if (block.timestamp >= request.expiry) revert AuthorizationExpired();
    bytes memory key = REGISTRY.activeKey(side.principal, side.principalKeyVersion);
    (bytes32 payloadHash, ExpectedSourceState sourceState) = _payload(request);
    if (!KeyedVerifier.isValid(key, payloadHash, signature)) revert InvalidPQAuthorization();
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

  function _payload(CommitAuthorizationRequest memory request)
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
