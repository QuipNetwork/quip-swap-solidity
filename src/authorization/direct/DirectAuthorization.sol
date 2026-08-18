// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {ICommitAuthorizationReceiver} from '../../interfaces/ICommitAuthorizationReceiver.sol';
import {IProfiledPQVerifier} from '../../interfaces/IProfiledPQVerifier.sol';
import {IRegisteredCommitTarget} from '../../interfaces/IRegisteredCommitTarget.sol';
import {ProtocolHashing} from '../../protocol/ProtocolHashing.sol';
import {
  AuthorizationMode,
  CommitAuthorizationRequest,
  DelegationPolicy,
  ExpectedSourceState,
  InitialRegistration,
  KeyRole,
  PQIdentity,
  RegistryActionTag,
  RegistryAuthorization,
  RegistryOperation,
  SideTerms,
  VerifiedCommitAuthorization
} from '../../protocol/ProtocolTypes.sol';
import {AuthorizationSubmitter, IActiveKeyRegistry} from '../shared/AuthorizationSubmitter.sol';
import {KeyedVerifier} from '../shared/KeyedVerifier.sol';
import {
  IERC7913SignatureVerifier
} from '@quip.network/hashsigs-solidity-0.2.0/contracts/interfaces/IERC7913SignatureVerifier.sol';

contract DirectAuthorization is IActiveKeyRegistry {
  string internal constant REGISTRATION_DOMAIN = 'InterlockRegister-v1.1';
  string internal constant REGISTRY_DOMAIN = 'InterlockRegistry-v1.1';
  string internal constant POSSESSION_DOMAIN = 'InterlockKeyPossession-v1.1';
  uint256 internal constant SECP256K1_HALF_ORDER = 0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0;
  bytes32 public constant EXPECTED_VERIFIER_VERSION = keccak256('quip.shrincs-verifier.v1');
  bytes32 public constant EXPECTED_VERIFIER_PROFILE = keccak256('shrincs-256s-keccak');

  error AlreadyRegistered();
  error IdentityNotRegistered();
  error IdentityNotActive();
  error InvalidKey();
  error InvalidVerifier();
  error InvalidVersion();
  error InvalidOperationShape();
  error InvalidEOAAuthorization();
  error InvalidPQAuthorization();
  error RequestExpired();
  error RegistryNonceAlreadyConsumed(bytes32 nonceKey);
  error CommitCallbackFailed();
  error InvalidAuthorizationMode();
  error InvalidChain();
  error AuthorizationExpired();
  error InvalidRegisteredSubmitter();
  error RegistrationPayloadMismatch();

  event IdentityRegistered(address indexed eoa, uint256 activeKeyVersion, uint256 recoveryKeyVersion);
  event ActiveKeyRotated(address indexed eoa, uint256 indexed activeKeyVersion);
  event IdentityRecovered(address indexed eoa, uint256 activeKeyVersion, uint256 recoveryKeyVersion);
  event RecoveryKeyRotated(address indexed eoa, uint256 indexed recoveryKeyVersion);
  event IdentityRevoked(address indexed eoa, KeyRole indexed authorizingRole, uint256 authorizingKeyVersion);
  event RegistryNonceConsumed(bytes32 indexed nonceKey, address indexed eoa, bytes32 indexed operationNonce);

  struct RegistryPayload {
    RegistryActionTag action;
    uint256 chainId;
    address registry;
    address eoa;
    uint256 expectedActiveKeyVersion;
    uint256 expectedRecoveryKeyVersion;
    bytes32 newActivePQKeyHash;
    uint256 newActiveKeyVersion;
    bytes32 newRecoveryPQKeyHash;
    uint256 newRecoveryKeyVersion;
    bytes32 operationNonce;
    uint256 expiry;
    bool recoveryAuthorized;
  }

  mapping(address => PQIdentity) private identities;
  mapping(bytes32 => bool) private consumedNonces;
  address public immutable TRUSTED_VERIFIER;
  bytes32 public immutable TRUSTED_VERIFIER_CODEHASH;

  constructor(address trustedVerifier) {
    if (trustedVerifier.code.length == 0) revert InvalidVerifier();
    if (_verifierMetadata(trustedVerifier, IProfiledPQVerifier.VERSION_TAG.selector) != EXPECTED_VERIFIER_VERSION) {
      revert InvalidVerifier();
    }
    if (_verifierMetadata(trustedVerifier, IProfiledPQVerifier.PROFILE_TAG.selector) != EXPECTED_VERIFIER_PROFILE) {
      revert InvalidVerifier();
    }
    TRUSTED_VERIFIER = trustedVerifier;
    TRUSTED_VERIFIER_CODEHASH = trustedVerifier.codehash;
  }

  function registerAndCommit(
    InitialRegistration calldata request,
    bytes calldata eoaSignature,
    bytes calldata activeProof,
    bytes calldata recoveryProof,
    bytes calldata commitData
  ) external payable {
    if (request.eoa == address(0)) revert InvalidEOAAuthorization();
    if (request.commitTarget.code.length == 0) revert CommitCallbackFailed();
    if (identities[request.eoa].activeKeyVersion != 0) revert AlreadyRegistered();
    if (block.timestamp >= request.expiry) revert RequestExpired();
    _validateKey(request.activePQKey);
    _validateKey(request.recoveryPQKey);
    bytes32 digest = registrationDigest(request);
    if (msg.sender != request.eoa && !_validEOASignature(request.eoa, digest, eoaSignature)) {
      revert InvalidEOAAuthorization();
    }
    _requireKeySignature(
      request.activePQKey, possessionDigest(digest, KeyRole.Active, request.activePQKey), activeProof
    );
    _requireKeySignature(
      request.recoveryPQKey, possessionDigest(digest, KeyRole.Recovery, request.recoveryPQKey), recoveryProof
    );

    PQIdentity storage identity = identities[request.eoa];
    identity.activePQKey = request.activePQKey;
    identity.activeKeyVersion = 1;
    identity.recoveryPQKey = request.recoveryPQKey;
    identity.recoveryKeyVersion = 1;
    identity.active = true;
    emit IdentityRegistered(request.eoa, 1, 1);

    try IRegisteredCommitTarget(request.commitTarget).completeRegisteredCommit{value: msg.value}(
      request.eoa, msg.sender, request.commitPayloadHash, commitData
    ) {}
    catch {
      revert CommitCallbackFailed();
    }
  }

  function authorizeCommit(CommitAuthorizationRequest calldata request, bytes calldata signature) external payable {
    _deliver(request, _verifyCommit(request, signature, msg.sender));
  }

  function completeRegisteredCommit(
    address eoa,
    address,
    bytes32 registeredPayloadHash,
    bytes calldata commitData
  ) external payable {
    if (msg.sender != address(this)) revert CommitCallbackFailed();
    (CommitAuthorizationRequest memory request, bytes memory signature) =
      abi.decode(commitData, (CommitAuthorizationRequest, bytes));
    SideTerms memory side = request.party ? request.terms.partySide : request.terms.counterpartySide;
    if (eoa != side.principal && (side.delegationPolicy != DelegationPolicy.SpecificDelegate || eoa != side.delegate)) {
      revert InvalidRegisteredSubmitter();
    }
    VerifiedCommitAuthorization memory evidence = _verifyCommit(request, signature, eoa);
    if (evidence.payloadHash != registeredPayloadHash) revert RegistrationPayloadMismatch();
    _deliver(request, evidence);
  }

  function execute(RegistryOperation calldata request, RegistryAuthorization calldata authorization) external {
    PQIdentity storage identity = identities[request.eoa];
    if (identity.activeKeyVersion == 0) revert IdentityNotRegistered();
    if (block.timestamp >= request.expiry) revert RequestExpired();
    if (
      request.expectedActiveKeyVersion != identity.activeKeyVersion
        || request.expectedRecoveryKeyVersion != identity.recoveryKeyVersion
    ) revert InvalidVersion();

    bytes32 digest = operationDigest(request);
    (KeyRole role, uint256 version) = _authorizer(request, identity);
    bytes32 nonceKey = registryNonceKey(request.eoa, role, version, request.operationNonce);
    if (consumedNonces[nonceKey]) revert RegistryNonceAlreadyConsumed(nonceKey);
    _requireKeySignature(
      role == KeyRole.Active ? identity.activePQKey : identity.recoveryPQKey,
      digest,
      authorization.authorizingPQSignature
    );
    if (
      _requiresEOA(request) && msg.sender != request.eoa
        && !_validEOASignature(request.eoa, digest, authorization.eoaSignature)
    ) {
      revert InvalidEOAAuthorization();
    }

    _apply(
      request,
      identity,
      digest,
      authorization.activeProofOfPossession,
      authorization.recoveryProofOfPossession,
      role,
      version
    );
    consumedNonces[nonceKey] = true;
    emit RegistryNonceConsumed(nonceKey, request.eoa, request.operationNonce);
  }

  function identityOf(address eoa) external view returns (PQIdentity memory) {
    return identities[eoa];
  }

  function activeKey(address eoa, uint256 version) external view returns (bytes memory) {
    PQIdentity storage identity = identities[eoa];
    if (!identity.active) revert IdentityNotActive();
    if (version != identity.activeKeyVersion) revert InvalidVersion();
    return identity.activePQKey;
  }

  function isRegistryNonceConsumed(bytes32 nonceKey) external view returns (bool) {
    return consumedNonces[nonceKey];
  }

  function isTrustedKey(bytes memory key) public view returns (bool) {
    if (key.length != 52 || TRUSTED_VERIFIER.codehash != TRUSTED_VERIFIER_CODEHASH) return false;
    address verifier;
    assembly ('memory-safe') { verifier := shr(96, mload(add(key, 32))) }
    return verifier == TRUSTED_VERIFIER;
  }

  function registrationDigest(InitialRegistration calldata request) public view returns (bytes32) {
    return keccak256(
      abi.encode(
        REGISTRATION_DOMAIN,
        block.chainid,
        address(this),
        request.eoa,
        keccak256(request.activePQKey),
        keccak256(request.recoveryPQKey),
        request.commitTarget,
        request.commitPayloadHash,
        request.operationNonce,
        request.expiry
      )
    );
  }

  function operationDigest(RegistryOperation calldata request) public view returns (bytes32) {
    RegistryPayload memory payload;
    payload.action = request.action;
    payload.chainId = block.chainid;
    payload.registry = address(this);
    payload.eoa = request.eoa;
    payload.expectedActiveKeyVersion = request.expectedActiveKeyVersion;
    payload.expectedRecoveryKeyVersion = request.expectedRecoveryKeyVersion;
    payload.newActivePQKeyHash = keccak256(request.newActivePQKey);
    payload.newActiveKeyVersion = request.newActiveKeyVersion;
    payload.newRecoveryPQKeyHash = keccak256(request.newRecoveryPQKey);
    payload.newRecoveryKeyVersion = request.newRecoveryKeyVersion;
    payload.operationNonce = request.operationNonce;
    payload.expiry = request.expiry;
    payload.recoveryAuthorized = request.recoveryAuthorized;
    return keccak256(abi.encode(REGISTRY_DOMAIN, payload));
  }

  function possessionDigest(bytes32 requestDigest, KeyRole role, bytes calldata key) public pure returns (bytes32) {
    return keccak256(abi.encode(POSSESSION_DOMAIN, requestDigest, role, keccak256(key)));
  }

  function registryNonceKey(address eoa, KeyRole role, uint256 version, bytes32 nonce) public view returns (bytes32) {
    return
      keccak256(ProtocolHashing.encodeRegistryNonceKey(block.chainid, address(this), eoa, uint8(role), version, nonce));
  }

  function _deliver(CommitAuthorizationRequest memory request, VerifiedCommitAuthorization memory evidence) private {
    ICommitAuthorizationReceiver(request.receiver).receiveAuthorizedCommit{value: msg.value}(
      request.terms, request.party, request.lock, request.bobCommitSecret, evidence, request.commitData
    );
  }

  function _verifyCommit(
    CommitAuthorizationRequest memory request,
    bytes memory signature,
    address transportCaller
  ) private view returns (VerifiedCommitAuthorization memory evidence) {
    SideTerms memory side = request.party ? request.terms.partySide : request.terms.counterpartySide;
    if (side.authorizationMode != AuthorizationMode.RegisteredDirect) revert InvalidAuthorizationMode();
    if (side.chainId != block.chainid) revert InvalidChain();
    if (block.timestamp >= request.expiry) revert AuthorizationExpired();
    bytes memory key = this.activeKey(side.principal, side.principalKeyVersion);
    (bytes32 payloadHash, ExpectedSourceState sourceState) = _commitPayload(request);
    if (!KeyedVerifier.isValid(key, payloadHash, signature)) revert InvalidPQAuthorization();
    (address submitter, uint256 submitterVersion) =
      AuthorizationSubmitter.derive(side, IActiveKeyRegistry(address(this)), transportCaller);
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

  function _commitPayload(CommitAuthorizationRequest memory request)
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

  function _authorizer(
    RegistryOperation calldata request,
    PQIdentity storage identity
  ) private view returns (KeyRole, uint256) {
    if (request.action == RegistryActionTag.RecoverActive || request.recoveryAuthorized) {
      if (request.action != RegistryActionTag.RecoverActive && request.action != RegistryActionTag.Revoke) {
        revert InvalidOperationShape();
      }
      return (KeyRole.Recovery, identity.recoveryKeyVersion);
    }
    if (!identity.active) revert IdentityNotActive();
    return (KeyRole.Active, identity.activeKeyVersion);
  }

  function _requiresEOA(RegistryOperation calldata request) private pure returns (bool) {
    return request.action == RegistryActionTag.RotateActive || request.action == RegistryActionTag.RotateRecovery
      || (request.action == RegistryActionTag.Revoke && !request.recoveryAuthorized);
  }

  function _apply(
    RegistryOperation calldata request,
    PQIdentity storage identity,
    bytes32 digest,
    bytes calldata activeProof,
    bytes calldata recoveryProof,
    KeyRole role,
    uint256 version
  ) private {
    if (request.action == RegistryActionTag.RotateActive) {
      _shape(request, true, false);
      _next(request.newActiveKeyVersion, identity.activeKeyVersion);
      _validateKey(request.newActivePQKey);
      _requireKeySignature(
        request.newActivePQKey, possessionDigest(digest, KeyRole.Active, request.newActivePQKey), activeProof
      );
      identity.activePQKey = request.newActivePQKey;
      identity.activeKeyVersion = request.newActiveKeyVersion;
      emit ActiveKeyRotated(request.eoa, request.newActiveKeyVersion);
    } else if (request.action == RegistryActionTag.RecoverActive) {
      _shape(request, true, true);
      _next(request.newActiveKeyVersion, identity.activeKeyVersion);
      _next(request.newRecoveryKeyVersion, identity.recoveryKeyVersion);
      _validateKey(request.newActivePQKey);
      _validateKey(request.newRecoveryPQKey);
      _requireKeySignature(
        request.newActivePQKey, possessionDigest(digest, KeyRole.Active, request.newActivePQKey), activeProof
      );
      _requireKeySignature(
        request.newRecoveryPQKey, possessionDigest(digest, KeyRole.Recovery, request.newRecoveryPQKey), recoveryProof
      );
      identity.activePQKey = request.newActivePQKey;
      identity.activeKeyVersion = request.newActiveKeyVersion;
      identity.recoveryPQKey = request.newRecoveryPQKey;
      identity.recoveryKeyVersion = request.newRecoveryKeyVersion;
      identity.active = true;
      emit IdentityRecovered(request.eoa, request.newActiveKeyVersion, request.newRecoveryKeyVersion);
    } else if (request.action == RegistryActionTag.RotateRecovery) {
      _shape(request, false, true);
      _next(request.newRecoveryKeyVersion, identity.recoveryKeyVersion);
      _validateKey(request.newRecoveryPQKey);
      _requireKeySignature(
        request.newRecoveryPQKey, possessionDigest(digest, KeyRole.Recovery, request.newRecoveryPQKey), recoveryProof
      );
      identity.recoveryPQKey = request.newRecoveryPQKey;
      identity.recoveryKeyVersion = request.newRecoveryKeyVersion;
      emit RecoveryKeyRotated(request.eoa, request.newRecoveryKeyVersion);
    } else if (request.action == RegistryActionTag.Revoke) {
      _shape(request, false, false);
      identity.active = false;
      emit IdentityRevoked(request.eoa, role, version);
    } else {
      revert InvalidOperationShape();
    }
  }

  function _shape(RegistryOperation calldata request, bool changesActive, bool changesRecovery) private pure {
    if (
      changesActive != (request.newActivePQKey.length != 0) || changesActive != (request.newActiveKeyVersion != 0)
        || changesRecovery != (request.newRecoveryPQKey.length != 0)
        || changesRecovery != (request.newRecoveryKeyVersion != 0)
        || (request.action != RegistryActionTag.Revoke && request.recoveryAuthorized)
    ) revert InvalidOperationShape();
  }

  function _next(uint256 proposed, uint256 current) private pure {
    if (current == type(uint256).max || proposed != current + 1) revert InvalidVersion();
  }

  function _verifierMetadata(address verifier, bytes4 selector) private view returns (bytes32 metadata) {
    (bool success, bytes memory returnData) = verifier.staticcall(abi.encodeWithSelector(selector));
    if (!success || returnData.length != 32) revert InvalidVerifier();
    metadata = abi.decode(returnData, (bytes32));
  }

  function _validateKey(bytes calldata key) private view {
    if (!isTrustedKey(key)) revert InvalidKey();
  }

  function _requireKeySignature(bytes memory keyedVerifier, bytes32 digest, bytes calldata signature) private view {
    if (!KeyedVerifier.isValid(keyedVerifier, digest, signature)) revert InvalidPQAuthorization();
  }

  function _validEOASignature(address signer, bytes32 digest, bytes calldata signature) private pure returns (bool) {
    if (signature.length != 65) return false;
    bytes32 r;
    bytes32 s;
    uint8 v;
    assembly ('memory-safe') {
      r := calldataload(signature.offset)
      s := calldataload(add(signature.offset, 32))
      v := byte(0, calldataload(add(signature.offset, 64)))
    }
    if (v < 27) v += 27;
    if (v != 27 && v != 28 || uint256(s) > SECP256K1_HALF_ORDER) return false;
    return ecrecover(digest, v, r, s) == signer;
  }
}
