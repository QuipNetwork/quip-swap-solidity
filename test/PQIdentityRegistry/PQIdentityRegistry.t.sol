// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {PQIdentityRegistry} from '../../src/PQIdentityRegistry.sol';
import {
  InitialRegistration,
  KeyRole,
  PQIdentity,
  RegistryActionTag,
  RegistryAuthorization,
  RegistryOperation
} from '../../src/ProtocolTypes.sol';
import {RegisteredCommitTargetHarness} from '../harness/RegisteredCommitTargetHarness.sol';
import {DigestVerifierMock} from '../mocks/DigestVerifierMock.sol';
import {SHRINCS256sKeccak} from '@quip.network/hashsigs-solidity-0.2.0/contracts/SHRINCS256sKeccak.sol';
import {Test} from 'forge-std-1.14.0/Test.sol';

contract WrongProfileVerifier {
  bytes32 public constant VERSION_TAG = keccak256('quip.shrincs-verifier.v1');
  bytes32 public constant PROFILE_TAG = keccak256('shrincs-128s-q20-keccak');
}

contract PQIdentityRegistryTest is Test {
  string internal constant REGISTRY_DOMAIN = 'InterlockRegistry-v1.1';
  string internal constant POSSESSION_DOMAIN = 'InterlockKeyPossession-v1.1';

  struct TestRegistryPayload {
    RegistryActionTag action;
    uint256 chainId;
    address registryAddress;
    address eoaAddress;
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
  uint256 internal constant EOA_KEY = 0xA11CE;
  address internal eoa;
  address internal relayer = address(0xB0B);
  PQIdentityRegistry internal registry;
  DigestVerifierMock internal verifier;
  RegisteredCommitTargetHarness internal target;

  function setUp() public {
    eoa = vm.addr(EOA_KEY);
    vm.warp(1000);
    verifier = new DigestVerifierMock();
    registry = new PQIdentityRegistry(address(verifier));
    target = new RegisteredCommitTargetHarness();
  }

  function test_directInitialRegistrationAndCommitAreAtomic() public {
    InitialRegistration memory request = _registration();
    bytes32 digest = registry.registrationDigest(request);
    vm.deal(eoa, 1 ether);
    vm.prank(eoa);
    registry.registerAndCommit{value: 1 ether}(
      request,
      '',
      _pqSig(_possessionDigest(digest, KeyRole.Active, request.activePQKey)),
      _pqSig(_possessionDigest(digest, KeyRole.Recovery, request.recoveryPQKey)),
      hex'c0ffee'
    );
    PQIdentity memory identity = registry.identityOf(eoa);
    assertEq(identity.activeKeyVersion, 1);
    assertEq(identity.recoveryKeyVersion, 1);
    assertTrue(identity.active);
    assertEq(target.registryCaller(), address(registry));
    assertEq(target.registeredEOA(), eoa);
    assertEq(target.commitPayloadHash(), request.commitPayloadHash);
    assertEq(target.valueReceived(), 1 ether);
  }

  function test_registryPinsV10Shrincs256sKeccakProfileAndDeploymentCode() public {
    SHRINCS256sKeccak shrincs = new SHRINCS256sKeccak();
    PQIdentityRegistry pinned = new PQIdentityRegistry(address(shrincs));
    assertEq(pinned.TRUSTED_VERIFIER(), address(shrincs));
    assertEq(pinned.TRUSTED_VERIFIER_CODEHASH(), address(shrincs).codehash);
    assertEq(pinned.EXPECTED_VERIFIER_VERSION(), keccak256('quip.shrincs-verifier.v1'));
    assertEq(pinned.EXPECTED_VERIFIER_PROFILE(), keccak256('shrincs-256s-keccak'));
    assertTrue(pinned.isTrustedKey(abi.encodePacked(address(shrincs), bytes32(uint256(1)))));
  }

  function test_registryRejectsMissingOrWrongVerifierProfile() public {
    vm.expectRevert(PQIdentityRegistry.InvalidVerifier.selector);
    new PQIdentityRegistry(address(0));
    WrongProfileVerifier wrongProfile = new WrongProfileVerifier();
    vm.expectRevert(PQIdentityRegistry.InvalidVerifier.selector);
    new PQIdentityRegistry(address(wrongProfile));
  }

  function test_registrationRejectsWrongVerifierPrefixAndNonCommitmentKeyLength() public {
    InitialRegistration memory request = _registration();
    DigestVerifierMock otherVerifier = new DigestVerifierMock();
    request.activePQKey = abi.encodePacked(address(otherVerifier), keccak256('other'));
    vm.expectRevert(PQIdentityRegistry.InvalidKey.selector);
    vm.prank(eoa);
    registry.registerAndCommit(request, '', '', '', '');

    request.activePQKey = abi.encodePacked(address(verifier), bytes31(uint248(1)));
    vm.expectRevert(PQIdentityRegistry.InvalidKey.selector);
    vm.prank(eoa);
    registry.registerAndCommit(request, '', '', '', '');
  }

  function test_relayedRegistrationRequiresNativeEOASignature() public {
    InitialRegistration memory request = _registration();
    bytes32 digest = registry.registrationDigest(request);
    vm.expectRevert(PQIdentityRegistry.InvalidEOAAuthorization.selector);
    vm.prank(relayer);
    registry.registerAndCommit(
      request, '', _activeRegistrationProof(request, digest), _recoveryRegistrationProof(request, digest), ''
    );

    vm.prank(relayer);
    registry.registerAndCommit(
      request,
      _eoaSig(digest),
      _activeRegistrationProof(request, digest),
      _recoveryRegistrationProof(request, digest),
      ''
    );
    assertTrue(registry.identityOf(eoa).active);
  }

  function test_failedCommitRollsBackRegistrationAndAllowsRetry() public {
    InitialRegistration memory request = _registration();
    bytes32 digest = registry.registrationDigest(request);
    target.setReject(true);
    vm.expectRevert(PQIdentityRegistry.CommitCallbackFailed.selector);
    vm.prank(eoa);
    registry.registerAndCommit(
      request, '', _activeRegistrationProof(request, digest), _recoveryRegistrationProof(request, digest), ''
    );
    assertEq(registry.identityOf(eoa).activeKeyVersion, 0);

    target.setReject(false);
    vm.prank(eoa);
    registry.registerAndCommit(
      request, '', _activeRegistrationProof(request, digest), _recoveryRegistrationProof(request, digest), ''
    );
    assertEq(registry.identityOf(eoa).activeKeyVersion, 1);
  }

  function test_registrationRejectsBadProofExpiryAndOverwrite() public {
    InitialRegistration memory request = _registration();
    bytes32 digest = registry.registrationDigest(request);
    vm.expectRevert(PQIdentityRegistry.InvalidPQAuthorization.selector);
    vm.prank(eoa);
    registry.registerAndCommit(request, '', hex'bad0', _recoveryRegistrationProof(request, digest), '');
    request.expiry = block.timestamp;
    vm.expectRevert(PQIdentityRegistry.RequestExpired.selector);
    vm.prank(eoa);
    registry.registerAndCommit(request, '', '', '', '');

    _register();
    request = _registration();
    vm.expectRevert(PQIdentityRegistry.AlreadyRegistered.selector);
    vm.prank(eoa);
    registry.registerAndCommit(request, '', '', '', '');
  }

  function test_registrationRejectsZeroIdentityAndNonContractCommitTarget() public {
    InitialRegistration memory request = _registration();
    request.eoa = address(0);
    vm.expectRevert(PQIdentityRegistry.InvalidEOAAuthorization.selector);
    registry.registerAndCommit(request, hex'00', hex'00', hex'00', hex'');

    request = _registration();
    request.commitTarget = relayer;
    vm.expectRevert(PQIdentityRegistry.CommitCallbackFailed.selector);
    vm.prank(eoa);
    registry.registerAndCommit(request, hex'', hex'', hex'', hex'');
  }

  function test_rotateActiveRequiresCurrentPQEOAControlPoPAndNextVersion() public {
    _register();
    RegistryOperation memory request = _operation(RegistryActionTag.RotateActive);
    request.newActivePQKey = _key('active-2');
    request.newActiveKeyVersion = 2;
    RegistryAuthorization memory auth = _authorization(request, true, false);

    vm.expectRevert(PQIdentityRegistry.InvalidEOAAuthorization.selector);
    vm.prank(relayer);
    registry.execute(request, auth);
    vm.prank(eoa);
    registry.execute(request, auth);
    PQIdentity memory identity = registry.identityOf(eoa);
    assertEq(identity.activeKeyVersion, 2);
    assertEq(identity.activePQKey, request.newActivePQKey);
    vm.expectRevert(PQIdentityRegistry.InvalidVersion.selector);
    registry.activeKey(eoa, 1);
  }

  function test_rotateRecoveryLeavesActiveVersionUnchanged() public {
    _register();
    RegistryOperation memory request = _operation(RegistryActionTag.RotateRecovery);
    request.newRecoveryPQKey = _key('recovery-2');
    request.newRecoveryKeyVersion = 2;
    vm.prank(eoa);
    registry.execute(request, _authorization(request, false, true));
    PQIdentity memory identity = registry.identityOf(eoa);
    assertEq(identity.activeKeyVersion, 1);
    assertEq(identity.recoveryKeyVersion, 2);
  }

  function test_recoveryIsPermissionlesslyRelayedRotatesBothKeysAndReactivates() public {
    _register();
    _revoke(true);
    RegistryOperation memory request = _operation(RegistryActionTag.RecoverActive);
    request.newActivePQKey = _key('recovered-active');
    request.newActiveKeyVersion = 2;
    request.newRecoveryPQKey = _key('recovered-recovery');
    request.newRecoveryKeyVersion = 2;
    vm.prank(relayer);
    registry.execute(request, _authorization(request, true, true));
    PQIdentity memory identity = registry.identityOf(eoa);
    assertTrue(identity.active);
    assertEq(identity.activeKeyVersion, 2);
    assertEq(identity.recoveryKeyVersion, 2);
  }

  function test_normalAndEmergencyRevocation() public {
    _register();
    RegistryOperation memory normal = _operation(RegistryActionTag.Revoke);
    vm.prank(eoa);
    registry.execute(normal, _authorization(normal, false, false));
    assertFalse(registry.identityOf(eoa).active);
    vm.expectRevert(PQIdentityRegistry.IdentityNotActive.selector);
    registry.activeKey(eoa, 1);

    RegistryOperation memory recovery = _operation(RegistryActionTag.RecoverActive);
    recovery.newActivePQKey = _key('a2');
    recovery.newActiveKeyVersion = 2;
    recovery.newRecoveryPQKey = _key('r2');
    recovery.newRecoveryKeyVersion = 2;
    registry.execute(recovery, _authorization(recovery, true, true));
    _revoke(true);
    assertFalse(registry.identityOf(eoa).active);
  }

  function test_replayNonceWrongVersionsExpiredAndBadShapesDoNotMutate() public {
    _register();
    RegistryOperation memory request = _operation(RegistryActionTag.RotateRecovery);
    request.newRecoveryPQKey = _key('r2');
    request.newRecoveryKeyVersion = 2;
    RegistryAuthorization memory auth = _authorization(request, false, true);
    bytes32 key = registry.registryNonceKey(eoa, KeyRole.Active, 1, request.operationNonce);
    vm.prank(eoa);
    registry.execute(request, auth);
    assertTrue(registry.isRegistryNonceConsumed(key));
    RegistryOperation memory replay = _operation(RegistryActionTag.RotateRecovery);
    replay.newRecoveryPQKey = _key('r3');
    replay.newRecoveryKeyVersion = 3;
    replay.operationNonce = request.operationNonce;
    RegistryAuthorization memory replayAuth = _authorization(replay, false, true);
    vm.expectRevert(abi.encodeWithSelector(PQIdentityRegistry.RegistryNonceAlreadyConsumed.selector, key));
    vm.prank(eoa);
    registry.execute(replay, replayAuth);

    vm.expectRevert(PQIdentityRegistry.InvalidVersion.selector);
    vm.prank(eoa);
    registry.execute(request, auth);

    RegistryOperation memory bad = _operation(RegistryActionTag.RotateActive);
    bad.newActivePQKey = _key('a2');
    bad.newActiveKeyVersion = 3;
    vm.expectRevert(PQIdentityRegistry.InvalidVersion.selector);
    vm.prank(eoa);
    registry.execute(bad, _authorization(bad, true, false));
    assertEq(registry.identityOf(eoa).activeKeyVersion, 1);

    bad.newActiveKeyVersion = 2;
    bad.expiry = block.timestamp;
    vm.expectRevert(PQIdentityRegistry.RequestExpired.selector);
    vm.prank(eoa);
    registry.execute(bad, _authorization(bad, true, false));
  }

  function test_failedLifecycleProofDoesNotConsumeNonce() public {
    _register();
    RegistryOperation memory request = _operation(RegistryActionTag.RotateActive);
    request.newActivePQKey = _key('a2');
    request.newActiveKeyVersion = 2;
    RegistryAuthorization memory auth = _authorization(request, true, false);
    auth.activeProofOfPossession = hex'bad0';
    bytes32 key = registry.registryNonceKey(eoa, KeyRole.Active, 1, request.operationNonce);
    vm.expectRevert(PQIdentityRegistry.InvalidPQAuthorization.selector);
    vm.prank(eoa);
    registry.execute(request, auth);
    assertFalse(registry.isRegistryNonceConsumed(key));
    assertEq(registry.identityOf(eoa).activeKeyVersion, 1);
  }

  function _register() internal {
    InitialRegistration memory request = _registration();
    bytes32 digest = registry.registrationDigest(request);
    vm.prank(eoa);
    registry.registerAndCommit(
      request, '', _activeRegistrationProof(request, digest), _recoveryRegistrationProof(request, digest), ''
    );
  }

  function _revoke(bool recoveryAuthorized) internal {
    RegistryOperation memory request = _operation(RegistryActionTag.Revoke);
    request.recoveryAuthorized = recoveryAuthorized;
    if (recoveryAuthorized) vm.prank(relayer);
    else vm.prank(eoa);
    registry.execute(request, _authorization(request, false, false));
  }

  function _registration() internal view returns (InitialRegistration memory) {
    return InitialRegistration({
      eoa: eoa,
      activePQKey: _key('active-1'),
      recoveryPQKey: _key('recovery-1'),
      commitTarget: address(target),
      commitPayloadHash: keccak256('commit'),
      operationNonce: keccak256('register-nonce'),
      expiry: 2000
    });
  }

  function _operation(RegistryActionTag action) internal view returns (RegistryOperation memory request) {
    PQIdentity memory identity = registry.identityOf(eoa);
    request.action = action;
    request.eoa = eoa;
    request.expectedActiveKeyVersion = identity.activeKeyVersion;
    request.expectedRecoveryKeyVersion = identity.recoveryKeyVersion;
    request.operationNonce = keccak256(abi.encode(action, identity.activeKeyVersion, identity.recoveryKeyVersion));
    request.expiry = 2000;
  }

  function _authorization(
    RegistryOperation memory request,
    bool proveActive,
    bool proveRecovery
  ) internal view returns (RegistryAuthorization memory auth) {
    bytes32 digest = _operationDigest(request);
    auth.authorizingPQSignature = _pqSig(digest);
    if (proveActive) {
      auth.activeProofOfPossession = _pqSig(_possessionDigest(digest, KeyRole.Active, request.newActivePQKey));
    }
    if (proveRecovery) {
      auth.recoveryProofOfPossession = _pqSig(_possessionDigest(digest, KeyRole.Recovery, request.newRecoveryPQKey));
    }
  }

  function _activeRegistrationProof(
    InitialRegistration memory request,
    bytes32 digest
  ) internal pure returns (bytes memory) {
    return _pqSig(_possessionDigest(digest, KeyRole.Active, request.activePQKey));
  }

  function _recoveryRegistrationProof(
    InitialRegistration memory request,
    bytes32 digest
  ) internal pure returns (bytes memory) {
    return _pqSig(_possessionDigest(digest, KeyRole.Recovery, request.recoveryPQKey));
  }

  function _key(string memory label) internal view returns (bytes memory) {
    return abi.encodePacked(address(verifier), keccak256(bytes(label)));
  }

  function _operationDigest(RegistryOperation memory request) internal view returns (bytes32) {
    TestRegistryPayload memory payload = TestRegistryPayload({
      action: request.action,
      chainId: block.chainid,
      registryAddress: address(registry),
      eoaAddress: request.eoa,
      expectedActiveKeyVersion: request.expectedActiveKeyVersion,
      expectedRecoveryKeyVersion: request.expectedRecoveryKeyVersion,
      newActivePQKeyHash: keccak256(request.newActivePQKey),
      newActiveKeyVersion: request.newActiveKeyVersion,
      newRecoveryPQKeyHash: keccak256(request.newRecoveryPQKey),
      newRecoveryKeyVersion: request.newRecoveryKeyVersion,
      operationNonce: request.operationNonce,
      expiry: request.expiry,
      recoveryAuthorized: request.recoveryAuthorized
    });
    return keccak256(abi.encode(REGISTRY_DOMAIN, payload));
  }

  function _possessionDigest(bytes32 digest, KeyRole role, bytes memory key) internal pure returns (bytes32) {
    return keccak256(abi.encode(POSSESSION_DOMAIN, digest, role, keccak256(key)));
  }

  function _pqSig(bytes32 digest) internal pure returns (bytes memory) {
    return abi.encode(digest);
  }

  function _eoaSig(bytes32 digest) internal pure returns (bytes memory) {
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(EOA_KEY, digest);
    return abi.encodePacked(r, s, v);
  }
}
