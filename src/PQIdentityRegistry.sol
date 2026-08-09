// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {KeyedVerifier} from './KeyedVerifier.sol';
import {ProtocolHashing} from './ProtocolHashing.sol';
import {
  InitialRegistration,
  KeyRole,
  PQIdentity,
  RegistryActionTag,
  RegistryAuthorization,
  RegistryOperation
} from './ProtocolTypes.sol';
import {IRegisteredCommitTarget} from './interfaces/IRegisteredCommitTarget.sol';
import {
  IERC7913SignatureVerifier
} from '@quip.network/hashsigs-solidity-0.2.0/contracts/interfaces/IERC7913SignatureVerifier.sol';

contract PQIdentityRegistry {
  string internal constant REGISTRATION_DOMAIN = 'InterlockRegister-v1.1';
  string internal constant REGISTRY_DOMAIN = 'InterlockRegistry-v1.1';
  string internal constant POSSESSION_DOMAIN = 'InterlockKeyPossession-v1.1';
  uint256 internal constant SECP256K1_HALF_ORDER = 0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0;

  error AlreadyRegistered();
  error IdentityNotRegistered();
  error IdentityNotActive();
  error InvalidKey();
  error InvalidVersion();
  error InvalidOperationShape();
  error InvalidEOAAuthorization();
  error InvalidPQAuthorization();
  error RequestExpired();
  error RegistryNonceAlreadyConsumed(bytes32 nonceKey);
  error CommitCallbackFailed();

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

  function registerAndCommit(
    InitialRegistration calldata request,
    bytes calldata eoaSignature,
    bytes calldata activeProof,
    bytes calldata recoveryProof,
    bytes calldata commitData
  ) external {
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

    try IRegisteredCommitTarget(request.commitTarget)
      .completeRegisteredCommit(request.eoa, msg.sender, request.commitPayloadHash, commitData) {}
    catch {
      revert CommitCallbackFailed();
    }
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

  function _validateKey(bytes calldata key) private pure {
    if (key.length <= 20) revert InvalidKey();
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
