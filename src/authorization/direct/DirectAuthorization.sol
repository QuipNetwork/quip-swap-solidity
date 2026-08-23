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

/// @title DirectAuthorization
/// @notice Registers versioned PQ identities for EOAs and authenticates RegisteredDirect commits.
/// @dev Registration can be combined with the first commit. Key rotation, recovery, and revocation
///      use separately scoped nonces. This prototype pins one verifier address, code hash, version,
///      and parameter profile at deployment.
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
  error AuthorizationNonceAlreadyConsumed(bytes32 nonceKey);
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
  event AuthorizationNonceConsumed(bytes32 indexed nonceKey, bytes32 indexed actionNonce, address indexed principal);

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

  /// @dev Current direct-user identity by EOA; historical key material is not retained.
  mapping(address => PQIdentity) private identities;
  /// @dev Replay protection for version- and role-scoped registry operations.
  mapping(bytes32 => bool) private consumedNonces;
  ///  Replay protection for commit authorizations verified by this boundary.
  mapping(bytes32 => bool) private consumedCommitNonces;
  /// @notice ERC-7913 verifier accepted by every registered keyed verifier.
  address public immutable TRUSTED_VERIFIER;
  /// @notice Deployment-time verifier code hash checked whenever key material is accepted.
  bytes32 public immutable TRUSTED_VERIFIER_CODEHASH;

  /// @notice Pins a deployed verifier with the expected version and cryptographic profile.
  constructor(address trustedVerifier) {
    // Reject EOAs and undeployed verifier addresses.
    if (trustedVerifier.code.length == 0) revert InvalidVerifier();
    // Pin both implementation family and parameter profile before accepting keys.
    if (_verifierMetadata(trustedVerifier, IProfiledPQVerifier.VERSION_TAG.selector) != EXPECTED_VERIFIER_VERSION) {
      revert InvalidVerifier();
    }
    if (_verifierMetadata(trustedVerifier, IProfiledPQVerifier.PROFILE_TAG.selector) != EXPECTED_VERIFIER_PROFILE) {
      revert InvalidVerifier();
    }
    // Store the address and deployed bytecode identity as immutable trust anchors.
    TRUSTED_VERIFIER = trustedVerifier;
    TRUSTED_VERIFIER_CODEHASH = trustedVerifier.codehash;
  }

  /// @notice Registers an EOA identity and atomically performs its first bound commit.
  /// @dev The EOA authorizes registration, and both new PQ keys prove possession. If the
  ///      callback fails, registration and its emitted event revert with the transaction.
  function registerAndCommit(
    InitialRegistration calldata request,
    bytes calldata eoaSignature,
    bytes calldata activeProof,
    bytes calldata recoveryProof,
    bytes calldata commitData
  ) external payable {
    // Validate identity, callback target, uniqueness, and request lifetime first.
    if (request.eoa == address(0)) revert InvalidEOAAuthorization();
    if (request.commitTarget.code.length == 0) revert CommitCallbackFailed();
    if (identities[request.eoa].activeKeyVersion != 0) revert AlreadyRegistered();
    if (block.timestamp >= request.expiry) revert RequestExpired();
    // Both keys must use the verifier pinned by this registry deployment.
    _validateKey(request.activePQKey);
    _validateKey(request.recoveryPQKey);
    // Bind EOA consent and both proofs of possession to this exact first commit.
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

    // Install version one only after all independent signatures succeed.
    PQIdentity storage identity = identities[request.eoa];
    identity.activePQKey = request.activePQKey;
    identity.activeKeyVersion = 1;
    identity.recoveryPQKey = request.recoveryPQKey;
    identity.recoveryKeyVersion = 1;
    identity.active = true;
    emit IdentityRegistered(request.eoa, 1, 1);

    // Complete the bound first commit in the same transaction; any failure rolls registration back.
    try IRegisteredCommitTarget(request.commitTarget).completeRegisteredCommit{value: msg.value}(
      request.eoa, msg.sender, request.commitPayloadHash, commitData
    ) {}
    catch {
      revert CommitCallbackFailed();
    }
  }

  /// @notice Verifies a RegisteredDirect commit and atomically forwards it to the wrapper.
  function authorizeCommit(CommitAuthorizationRequest calldata request, bytes calldata signature) external payable {
    // Consume after verification and before wrapper delivery; callback failure rolls it back.
    VerifiedCommitAuthorization memory evidence = _verifyCommit(request, signature, msg.sender);
    _consumeCommitNonce(request, evidence.actionNonce);
    _deliver(request, evidence);
  }

  /// @notice Self-callback that reconstructs and completes the commit bound into registration.
  /// @dev Only registerAndCommit can enter this path because msg.sender must be this contract.
  function completeRegisteredCommit(
    address eoa,
    address,
    /* transportCaller: registration already authenticates the EOA below */
    bytes32 registeredPayloadHash,
    bytes calldata commitData
  ) external payable {
    // External callers cannot manufacture the privileged registration callback context.
    if (msg.sender != address(this)) revert CommitCallbackFailed();
    // Recover the exact commit request and PQ signature supplied to registerAndCommit.
    (CommitAuthorizationRequest memory request, bytes memory signature) =
      abi.decode(commitData, (CommitAuthorizationRequest, bytes));
    // Registration may bootstrap the principal or the specifically named delegate only.
    SideTerms memory side = request.party ? request.terms.partySide : request.terms.counterpartySide;
    if (eoa != side.principal && (side.delegationPolicy != DelegationPolicy.SpecificDelegate || eoa != side.delegate)) {
      revert InvalidRegisteredSubmitter();
    }
    // Treat the newly registered EOA as the authenticated transport identity.
    VerifiedCommitAuthorization memory evidence = _verifyCommit(request, signature, eoa);
    // Prevent callback calldata from substituting the commit bound into registration.
    if (evidence.payloadHash != registeredPayloadHash) revert RegistrationPayloadMismatch();
    // Registration, nonce consumption, and the first commit remain one atomic transaction.
    _consumeCommitNonce(request, evidence.actionNonce);
    _deliver(request, evidence);
  }

  /// @notice Applies an authorized active-key rotation, recovery-key rotation, recovery, or revocation.
  function execute(RegistryOperation calldata request, RegistryAuthorization calldata authorization) external {
    // Load the current versions before authenticating a lifecycle operation.
    PQIdentity storage identity = identities[request.eoa];
    if (identity.activeKeyVersion == 0) revert IdentityNotRegistered();
    if (block.timestamp >= request.expiry) revert RequestExpired();
    if (
      request.expectedActiveKeyVersion != identity.activeKeyVersion
        || request.expectedRecoveryKeyVersion != identity.recoveryKeyVersion
    ) revert InvalidVersion();

    // Select active or recovery authority, then scope replay to that exact key version.
    bytes32 digest = operationDigest(request);
    (KeyRole role, uint256 version) = _authorizer(request, identity);
    bytes32 nonceKey = registryNonceKey(request.eoa, role, version, request.operationNonce);
    if (consumedNonces[nonceKey]) revert RegistryNonceAlreadyConsumed(nonceKey);
    // Require the selected PQ authority for every lifecycle operation.
    _requireKeySignature(
      role == KeyRole.Active ? identity.activePQKey : identity.recoveryPQKey,
      digest,
      authorization.authorizingPQSignature
    );
    // Active-authorized rotations and revocation also retain native EOA control.
    if (
      _requiresEOA(request) && msg.sender != request.eoa
        && !_validEOASignature(request.eoa, digest, authorization.eoaSignature)
    ) {
      revert InvalidEOAAuthorization();
    }

    // Validate action shape and new-key possession before mutating identity state.
    _apply(
      request,
      identity,
      digest,
      authorization.activeProofOfPossession,
      authorization.recoveryProofOfPossession,
      role,
      version
    );
    // Consume only after the requested state mutation succeeds.
    consumedNonces[nonceKey] = true;
    emit RegistryNonceConsumed(nonceKey, request.eoa, request.operationNonce);
  }

  /// @notice Returns the current registered identity record for an EOA.
  function identityOf(address eoa) external view returns (PQIdentity memory) {
    return identities[eoa];
  }

  /// @inheritdoc IActiveKeyRegistry
  function activeKey(address eoa, uint256 version) external view returns (bytes memory) {
    PQIdentity storage identity = identities[eoa];
    // Inactive identities expose no commit or delegation key.
    if (!identity.active) revert IdentityNotActive();
    if (version != identity.activeKeyVersion) revert InvalidVersion();
    return identity.activePQKey;
  }

  /// @notice Reports whether a boundary-owned commit nonce has been consumed.
  function isCommitNonceConsumed(bytes32 nonceKey) external view returns (bool) {
    return consumedCommitNonces[nonceKey];
  }

  /// @notice Computes the commit nonce scope owned by this direct boundary.
  function commitNonceKey(address principal, uint256 keyVersion, bytes32 actionNonce) public view returns (bytes32) {
    return keccak256(
      ProtocolHashing.encodeAuthorizationNonceKey(block.chainid, address(this), principal, keyVersion, actionNonce)
    );
  }

  /// @notice Reports whether a scoped registry-operation nonce has been consumed.
  function isRegistryNonceConsumed(bytes32 nonceKey) external view returns (bool) {
    return consumedNonces[nonceKey];
  }

  /// @notice Validates key length, verifier prefix, and the pinned verifier code hash.
  function isTrustedKey(bytes memory key) public view returns (bool) {
    // Key encoding is 20-byte verifier address plus 32-byte SHRINCS commitment.
    if (key.length != 52 || TRUSTED_VERIFIER.codehash != TRUSTED_VERIFIER_CODEHASH) return false;
    // Read the verifier prefix without allocating a second key buffer.
    address verifier;
    assembly ('memory-safe') { verifier := shr(96, mload(add(key, 32))) }
    return verifier == TRUSTED_VERIFIER;
  }

  /// @notice Computes the chain- and registry-bound digest for initial registration.
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

  /// @notice Computes the chain- and registry-bound digest for an identity operation.
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

  /// @notice Binds a new key proof of possession to a request digest and key role.
  function possessionDigest(bytes32 requestDigest, KeyRole role, bytes calldata key) public pure returns (bytes32) {
    return keccak256(abi.encode(POSSESSION_DOMAIN, requestDigest, role, keccak256(key)));
  }

  /// @notice Computes replay scope from chain, registry, EOA, authorizing role/version, and nonce.
  function registryNonceKey(address eoa, KeyRole role, uint256 version, bytes32 nonce) public view returns (bytes32) {
    return
      keccak256(ProtocolHashing.encodeRegistryNonceKey(block.chainid, address(this), eoa, uint8(role), version, nonce));
  }

  function _consumeCommitNonce(CommitAuthorizationRequest memory request, bytes32 actionNonce) private {
    SideTerms memory side = request.party ? request.terms.partySide : request.terms.counterpartySide;
    bytes32 nonceKey = commitNonceKey(side.principal, side.principalKeyVersion, actionNonce);
    if (consumedCommitNonces[nonceKey]) revert AuthorizationNonceAlreadyConsumed(nonceKey);
    // Write before the external wrapper call; transaction rollback restores it on rejection.
    consumedCommitNonces[nonceKey] = true;
    emit AuthorizationNonceConsumed(nonceKey, actionNonce, side.principal);
  }

  function _deliver(CommitAuthorizationRequest memory request, VerifiedCommitAuthorization memory evidence) private {
    // Forward authorization evidence and all native funding atomically.
    ICommitAuthorizationReceiver(request.receiver).receiveAuthorizedCommit{value: msg.value}(
      request.terms, request.party, request.lock, request.bobCommitSecret, evidence, request.commitData
    );
  }

  function _verifyCommit(
    CommitAuthorizationRequest memory request,
    bytes memory signature,
    address transportCaller
  ) private view returns (VerifiedCommitAuthorization memory evidence) {
    // Select the signed side and reject use of this gateway for wallet-mode terms.
    SideTerms memory side = request.party ? request.terms.partySide : request.terms.counterpartySide;
    if (side.authorizationMode != AuthorizationMode.RegisteredDirect) revert InvalidAuthorizationMode();
    if (side.chainId != block.chainid) revert InvalidChain();
    if (block.timestamp >= request.expiry) revert AuthorizationExpired();
    // Resolve only the currently active key at the exact signed version.
    bytes memory key = this.activeKey(side.principal, side.principalKeyVersion);
    // Reconstruct and authenticate the complete protocol payload.
    (bytes32 payloadHash, ExpectedSourceState sourceState) = _commitPayload(request);
    if (!KeyedVerifier.isValid(key, payloadHash, signature)) revert InvalidPQAuthorization();
    // Derive attribution from the actual transaction transport under the signed policy.
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
    // Recovery authority is limited to active-key recovery or emergency revocation.
    if (request.action == RegistryActionTag.RecoverActive || request.recoveryAuthorized) {
      if (request.action != RegistryActionTag.RecoverActive && request.action != RegistryActionTag.Revoke) {
        revert InvalidOperationShape();
      }
      return (KeyRole.Recovery, identity.recoveryKeyVersion);
    }
    // All non-recovery operations require the active identity key.
    if (!identity.active) revert IdentityNotActive();
    return (KeyRole.Active, identity.activeKeyVersion);
  }

  function _requiresEOA(RegistryOperation calldata request) private pure returns (bool) {
    // Recovery is intentionally usable without the possibly compromised native EOA.
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
      // Normal active rotation changes only the active key and requires its possession proof.
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
      // Recovery replaces both keys so a compromised recovery key cannot remain installed.
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
      // Normal recovery rotation leaves the active key and version unchanged.
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
      // Revocation preserves keys and versions but makes active-key lookup fail.
      _shape(request, false, false);
      identity.active = false;
      emit IdentityRevoked(request.eoa, role, version);
    } else {
      revert InvalidOperationShape();
    }
  }

  function _shape(RegistryOperation calldata request, bool changesActive, bool changesRecovery) private pure {
    // Reject extra, missing, or semantically ignored key-update fields.
    if (
      changesActive != (request.newActivePQKey.length != 0) || changesActive != (request.newActiveKeyVersion != 0)
        || changesRecovery != (request.newRecoveryPQKey.length != 0)
        || changesRecovery != (request.newRecoveryKeyVersion != 0)
        || (request.action != RegistryActionTag.Revoke && request.recoveryAuthorized)
    ) revert InvalidOperationShape();
  }

  function _next(uint256 proposed, uint256 current) private pure {
    // Versions advance by exactly one and never wrap.
    if (current == type(uint256).max || proposed != current + 1) revert InvalidVersion();
  }

  function _verifierMetadata(address verifier, bytes4 selector) private view returns (bytes32 metadata) {
    // Metadata calls must return one canonical bytes32 word.
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
    // Accept only canonical-length secp256k1 signatures.
    if (signature.length != 65) return false;
    bytes32 r;
    bytes32 s;
    uint8 v;
    assembly ('memory-safe') {
      r := calldataload(signature.offset)
      s := calldataload(add(signature.offset, 32))
      v := byte(0, calldataload(add(signature.offset, 64)))
    }
    // Normalize v and reject high-s malleable signatures.
    if (v < 27) v += 27;
    if (v != 27 && v != 28 || uint256(s) > SECP256K1_HALF_ORDER) return false;
    return ecrecover(digest, v, r, s) == signer;
  }
}
