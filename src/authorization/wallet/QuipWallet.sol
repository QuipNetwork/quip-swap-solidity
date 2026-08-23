// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {ICommitAuthorizationReceiver} from '../../interfaces/ICommitAuthorizationReceiver.sol';
import {ProtocolHashing} from '../../protocol/ProtocolHashing.sol';
import {
  AuthorizationMode,
  CommitAuthorizationRequest,
  ExpectedSourceState,
  KeyRole,
  ProtocolTerms,
  SideTerms,
  VerifiedCommitAuthorization,
  WrapperMode
} from '../../protocol/ProtocolTypes.sol';
import {DirectAuthorization} from '../direct/DirectAuthorization.sol';
import {AuthorizationSubmitter} from '../shared/AuthorizationSubmitter.sol';
import {KeyedVerifier} from '../shared/KeyedVerifier.sol';

/// @notice Prototype implementation of the deployable wallet-mode principal boundary.
/// @dev The wallet stores its ERC-7913 keyed verifier and public key together as
///      `verifier address || 32-byte SHRINCS commitment`. Commit authorization is
///      always checked against that wallet-owned key state before the exact signed
///      request is forwarded atomically to its named receiver. Selecting and pinning
///      the production verifier implementation is a separate deployment decision.
contract QuipWallet {
  string internal constant COMMIT_DOMAIN = 'InterlockWalletCommitAuthorization-v1.1';
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
  error AuthorizationNonceAlreadyConsumed(bytes32 nonceKey);
  error ExecutionFailed();
  error ForbiddenAuthorizationBypass();

  event AuthorizationNonceConsumed(bytes32 indexed nonceKey, bytes32 indexed actionNonce, address indexed principal);

  /// @notice Address allowed to execute arbitrary wallet calls and rotate the PQ key.
  address public immutable OWNER;
  /// @notice Direct registry used to validate specific delegated submitters and trusted key shape.
  DirectAuthorization public immutable REGISTRY;
  /// @dev Verifier-prefixed key bytes are private storage, but their hash is publicly observable.
  bytes private activePQKey;
  /// @notice Monotonic epoch included in wallet commit and rotation digests.
  uint256 public walletKeyEpoch = 1;
  /// @notice Wallet-local replay protection for key-rotation authorizations.
  mapping(bytes32 => bool) public consumedRotationNonces;
  /// @dev Replay protection for commit authorizations verified by this wallet.
  mapping(bytes32 => bool) private consumedCommitNonces;

  /// @notice Allows the wallet to receive native currency for later owner-directed execution.
  receive() external payable {}

  /// @notice Creates a wallet with one owner and one verifier-prefixed active PQ key.
  constructor(address owner, DirectAuthorization registry, bytes memory initialPQKey) {
    // The registry supplies the verifier trust policy shared with direct authorization.
    if (owner == address(0) || !registry.isTrustedKey(initialPQKey)) revert InvalidKey();
    OWNER = owner;
    REGISTRY = registry;
    activePQKey = initialPQKey;
  }

  /// @notice Verifies and atomically forwards a wallet-mode commit to its named wrapper.
  /// @dev Any transport caller allowed by the signed delegation policy may submit the request.
  function authorizeCommit(CommitAuthorizationRequest calldata request, bytes calldata signature) external payable {
    // Authenticate and consume before forwarding; callback failure rolls both changes back.
    VerifiedCommitAuthorization memory evidence = _verify(request, signature, msg.sender);
    _consumeCommitNonce(request, evidence.actionNonce);
    ICommitAuthorizationReceiver(request.receiver).receiveAuthorizedCommit{value: msg.value}(
      request.terms, request.party, request.lock, request.bobCommitSecret, evidence, request.commitData
    );
  }

  /// @notice Executes an owner-directed call while preventing bypass of commit authorization.
  function execute(address target, uint256 value, bytes calldata data) external returns (bytes memory result) {
    // Generic execution remains under native owner control.
    if (msg.sender != OWNER) revert NotOwner();
    // Block the only callback that could forge wallet authorization evidence.
    if (data.length >= 4 && bytes4(data[:4]) == ICommitAuthorizationReceiver.receiveAuthorizedCommit.selector) {
      revert ForbiddenAuthorizationBypass();
    }
    bool success;
    // Forward the requested value and calldata without interpreting the result.
    (success, result) = target.call{value: value}(data);
    if (!success) revert ExecutionFailed();
  }

  function _verify(
    CommitAuthorizationRequest calldata request,
    bytes calldata signature,
    address transportCaller
  ) private view returns (VerifiedCommitAuthorization memory evidence) {
    // Wallet mode requires this contract itself to be the signed principal.
    SideTerms memory side = request.party ? request.terms.partySide : request.terms.counterpartySide;
    if (side.authorizationMode != AuthorizationMode.QuipWallet || side.principalKeyVersion != 0) {
      revert InvalidAuthorizationMode();
    }
    if (side.principal != address(this)) revert InvalidWalletPrincipal();
    if (side.chainId != block.chainid) revert InvalidChain();
    if (block.timestamp >= request.expiry) revert AuthorizationExpired();
    // Reconstruct the wrapper payload, then bind it to this wallet current key epoch.
    (bytes32 payloadHash, ExpectedSourceState sourceState) = _payload(request);
    if (!KeyedVerifier.isValid(activePQKey, commitAuthorizationDigest(payloadHash), signature)) {
      revert InvalidPQAuthorization();
    }
    // Attribute the actual relay according to the signed delegation policy.
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

  /// @notice Rotates the wallet PQ key with old-key approval and new-key proof of possession.
  function rotateActiveKey(
    bytes calldata newPQKey,
    bytes32 rotationNonce,
    uint256 expiry,
    bytes calldata currentKeySignature,
    bytes calldata newKeyProof
  ) external {
    // Rotation requires both native owner control and a registry-compatible new key.
    if (msg.sender != OWNER) revert NotOwner();
    if (!REGISTRY.isTrustedKey(newPQKey)) revert InvalidKey();
    if (block.timestamp >= expiry) revert AuthorizationExpired();
    if (consumedRotationNonces[rotationNonce]) revert RotationNonceAlreadyConsumed();
    // The old key authorizes rotation; the new key separately proves possession.
    bytes32 digest = rotationDigest(newPQKey, rotationNonce, expiry);
    if (!KeyedVerifier.isValid(activePQKey, digest, currentKeySignature)) revert InvalidPQAuthorization();
    bytes32 proofDigest = keccak256(abi.encode(POSSESSION_DOMAIN, digest, KeyRole.Active, keccak256(newPQKey)));
    if (!KeyedVerifier.isValid(newPQKey, proofDigest, newKeyProof)) revert InvalidPQAuthorization();
    // Change key and epoch together so every pending old-key commit becomes invalid.
    activePQKey = newPQKey;
    ++walletKeyEpoch;
    // Consume the nonce only after both signatures and the state update succeed.
    consumedRotationNonces[rotationNonce] = true;
  }

  /// @notice Wraps a protocol payload in the wallet, chain, and current key epoch domain.
  function commitAuthorizationDigest(bytes32 payloadHash) public view returns (bytes32) {
    return keccak256(abi.encode(COMMIT_DOMAIN, block.chainid, address(this), walletKeyEpoch, payloadHash));
  }

  /// @notice Computes the current-to-next key rotation digest.
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

  /// @notice Reports whether a boundary-owned commit nonce has been consumed.
  function isCommitNonceConsumed(bytes32 nonceKey) external view returns (bool) {
    return consumedCommitNonces[nonceKey];
  }

  /// @notice Computes the commit nonce scope owned by this wallet.
  function commitNonceKey(bytes32 actionNonce) public view returns (bytes32) {
    return
      keccak256(
        ProtocolHashing.encodeAuthorizationNonceKey(block.chainid, address(this), address(this), 0, actionNonce)
      );
  }

  /// @notice Returns the hash of the current verifier-prefixed PQ key bytes.
  function activeKeyHash() external view returns (bytes32) {
    return keccak256(activePQKey);
  }

  function _consumeCommitNonce(CommitAuthorizationRequest calldata request, bytes32 actionNonce) private {
    SideTerms memory side = request.party ? request.terms.partySide : request.terms.counterpartySide;
    bytes32 nonceKey = commitNonceKey(actionNonce);
    if (side.principal != address(this) || side.principalKeyVersion != 0) revert InvalidWalletPrincipal();
    if (consumedCommitNonces[nonceKey]) revert AuthorizationNonceAlreadyConsumed(nonceKey);
    // Write before the external wrapper call; transaction rollback restores it on rejection.
    consumedCommitNonces[nonceKey] = true;
    emit AuthorizationNonceConsumed(nonceKey, actionNonce, side.principal);
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
