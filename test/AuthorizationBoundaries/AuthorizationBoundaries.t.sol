// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {AuthorizationSubmitter} from '../../src/AuthorizationSubmitter.sol';
import {PQAuthorizationGateway} from '../../src/PQAuthorizationGateway.sol';
import {PQIdentityRegistry} from '../../src/PQIdentityRegistry.sol';
import {ProgressionGate} from '../../src/ProgressionGate.sol';
import {ProtocolHashing} from '../../src/ProtocolHashing.sol';
import {
  AuthorizationMode,
  CommitAuthorizationRequest,
  DelegationPolicy,
  ExpectedSourceState,
  InitialRegistration,
  KeyRole,
  ProtocolTerms,
  SideTerms,
  VerifiedCommitAuthorization
} from '../../src/ProtocolTypes.sol';
import {QuipWalletAuthorizationAdapter} from '../../src/QuipWalletAuthorizationAdapter.sol';
import {Asset, AssetType} from '../../src/TermsLib.sol';
import {AuthorizationReceiverHarness} from '../harness/AuthorizationReceiverHarness.sol';
import {RegisteredCommitTargetHarness} from '../harness/RegisteredCommitTargetHarness.sol';
import {KeyBoundVerifierMock} from '../mocks/KeyBoundVerifierMock.sol';
import {Test} from 'forge-std-1.14.0/Test.sol';

contract AuthorizationBoundariesTest is Test {
  uint256 internal constant DIRECT_KEY = 0xD1EC7;
  uint256 internal constant BROKER_KEY = 0xB0B0;
  address internal directUser;
  address internal broker;
  address internal owner = address(0xA11CE);
  address internal relayer = address(0x7E1A);
  bytes32 internal constant LOCK = keccak256('lock');

  PQIdentityRegistry internal registry;
  PQAuthorizationGateway internal gateway;
  QuipWalletAuthorizationAdapter internal wallet;
  AuthorizationReceiverHarness internal receiver;
  RegisteredCommitTargetHarness internal registrationTarget;
  KeyBoundVerifierMock internal verifier;
  bytes internal directPQKey;
  bytes internal walletPQKey;

  function setUp() public {
    directUser = vm.addr(DIRECT_KEY);
    broker = vm.addr(BROKER_KEY);
    vm.warp(1000);
    registry = new PQIdentityRegistry();
    verifier = new KeyBoundVerifierMock();
    directPQKey = _key('direct');
    walletPQKey = _key('wallet-1');
    registrationTarget = new RegisteredCommitTargetHarness();
    _register(directUser, directPQKey);
    _register(broker, _key('broker'));
    gateway = new PQAuthorizationGateway(registry);
    receiver = new AuthorizationReceiverHarness(address(gateway));
    wallet = new QuipWalletAuthorizationAdapter(owner, registry, walletPQKey);
  }

  function test_walletAndGatewayProduceIdenticalSharedAdmissionSemantics() public {
    ProtocolTerms memory walletTerms = _terms(address(wallet), AuthorizationMode.QuipWallet, 0);
    CommitAuthorizationRequest memory walletRequest = _request(walletTerms, keccak256('wallet-nonce'));
    vm.prank(relayer);
    wallet.authorizeCommit(walletRequest, _signature(walletRequest, address(wallet)));
    assertEq(receiver.lastSubmitter(), address(wallet));

    ProtocolTerms memory directTerms = _terms(directUser, AuthorizationMode.RegisteredDirect, 1);
    CommitAuthorizationRequest memory directRequest = _request(directTerms, keccak256('direct-nonce'));
    vm.prank(relayer);
    gateway.authorizeCommit(directRequest, _signature(directRequest, address(gateway)));
    assertEq(receiver.lastSubmitter(), directUser);
    assertEq(receiver.commits(), 2);
  }

  function test_bothPathsRejectBadSignatureExpiryReplayAndReceiverSubstitution() public {
    _assertCommonRejections(true);
    _assertCommonRejections(false);
  }

  function test_specificDelegateUsesRegisteredActualTransportOnBothPaths() public {
    ProtocolTerms memory walletTerms = _specificTerms(address(wallet), AuthorizationMode.QuipWallet, 0);
    CommitAuthorizationRequest memory walletRequest = _request(walletTerms, keccak256('wallet-delegate'));
    bytes memory walletSignature = _signature(walletRequest, address(wallet));
    vm.expectRevert(AuthorizationSubmitter.InvalidTransportSubmitter.selector);
    vm.prank(relayer);
    wallet.authorizeCommit(walletRequest, walletSignature);
    vm.prank(broker);
    wallet.authorizeCommit(walletRequest, walletSignature);
    assertEq(receiver.lastSubmitter(), broker);

    ProtocolTerms memory directTerms = _specificTerms(directUser, AuthorizationMode.RegisteredDirect, 1);
    CommitAuthorizationRequest memory directRequest = _request(directTerms, keccak256('direct-delegate'));
    bytes memory directSignature = _signature(directRequest, address(gateway));
    vm.expectRevert(AuthorizationSubmitter.InvalidTransportSubmitter.selector);
    vm.prank(relayer);
    gateway.authorizeCommit(directRequest, directSignature);
    vm.prank(broker);
    gateway.authorizeCommit(directRequest, directSignature);
    assertEq(receiver.lastSubmitter(), broker);
  }

  function test_permissionlessUsesActualCallerOnBothPaths() public {
    ProtocolTerms memory walletTerms = _terms(address(wallet), AuthorizationMode.QuipWallet, 0);
    walletTerms.partySide.delegationPolicy = DelegationPolicy.Permissionless;
    CommitAuthorizationRequest memory walletRequest = _request(walletTerms, keccak256('wallet-open'));
    vm.prank(relayer);
    wallet.authorizeCommit(walletRequest, _signature(walletRequest, address(wallet)));
    assertEq(receiver.lastSubmitter(), relayer);

    ProtocolTerms memory directTerms = _terms(directUser, AuthorizationMode.RegisteredDirect, 1);
    directTerms.partySide.delegationPolicy = DelegationPolicy.Permissionless;
    CommitAuthorizationRequest memory directRequest = _request(directTerms, keccak256('direct-open'));
    vm.prank(relayer);
    gateway.authorizeCommit(directRequest, _signature(directRequest, address(gateway)));
    assertEq(receiver.lastSubmitter(), relayer);
  }

  function test_walletRotationInvalidatesPendingOldKeyAuthorizationButNotCommittedState() public {
    ProtocolTerms memory terms = _terms(address(wallet), AuthorizationMode.QuipWallet, 0);
    CommitAuthorizationRequest memory committed = _request(terms, keccak256('committed'));
    bytes memory committedSignature = _signature(committed, address(wallet));
    wallet.authorizeCommit(committed, committedSignature);
    assertEq(receiver.commits(), 1);

    CommitAuthorizationRequest memory pending = _request(terms, keccak256('pending'));
    bytes memory oldPendingSignature = _signature(pending, address(wallet));
    bytes memory newKey = _key('wallet-2');
    bytes32 rotationNonce = keccak256('rotation');
    uint256 expiry = 2000;
    bytes32 rotationDigest = wallet.rotationDigest(newKey, rotationNonce, expiry);
    bytes32 proofDigest =
      keccak256(abi.encode('InterlockKeyPossession-v1.1', rotationDigest, KeyRole.Active, keccak256(newKey)));
    vm.prank(owner);
    wallet.rotateActiveKey(
      newKey, rotationNonce, expiry, _pqSig(walletPQKey, rotationDigest), _pqSig(newKey, proofDigest)
    );
    walletPQKey = newKey;
    assertEq(wallet.walletKeyEpoch(), 2);
    assertEq(receiver.commits(), 1);

    vm.expectRevert(QuipWalletAuthorizationAdapter.InvalidPQAuthorization.selector);
    wallet.authorizeCommit(pending, oldPendingSignature);
    wallet.authorizeCommit(pending, _signature(pending, address(wallet)));
    assertEq(receiver.commits(), 2);
  }

  function test_failedReceiverRollsBackSharedNonceForBothPaths() public {
    _assertReceiverRollback(true);
    _assertReceiverRollback(false);
  }

  function test_atomicRegistrationEntersGatewayAndRollsBackOnCommitFailure() public {
    address newcomer = vm.addr(0xCA11);
    bytes memory newcomerKey = _key('newcomer');
    ProtocolTerms memory terms = _terms(newcomer, AuthorizationMode.RegisteredDirect, 1);
    CommitAuthorizationRequest memory request = _request(terms, keccak256('lazy-register'));
    bytes32 payloadHash = _payload(request, address(gateway));
    bytes memory signature = _pqSig(newcomerKey, payloadHash);
    InitialRegistration memory registration = _lazyRegistration(newcomer, newcomerKey, payloadHash);
    (bytes memory activeProof, bytes memory recoveryProof) = _registrationProofs(registration);
    vm.prank(newcomer);
    registry.registerAndCommit(registration, '', activeProof, recoveryProof, abi.encode(request, signature));
    assertEq(registry.identityOf(newcomer).activeKeyVersion, 1);
    assertEq(receiver.lastSubmitter(), newcomer);

    address failingUser = vm.addr(0xFA11);
    bytes memory failingKey = _key('failing');
    terms = _terms(failingUser, AuthorizationMode.RegisteredDirect, 1);
    request = _request(terms, keccak256('failed-register'));
    request.commitData = 'fail';
    payloadHash = _payload(request, address(gateway));
    signature = _pqSig(failingKey, payloadHash);
    registration = _lazyRegistration(failingUser, failingKey, payloadHash);
    (activeProof, recoveryProof) = _registrationProofs(registration);
    vm.expectRevert(PQIdentityRegistry.CommitCallbackFailed.selector);
    vm.prank(failingUser);
    registry.registerAndCommit(registration, '', activeProof, recoveryProof, abi.encode(request, signature));
    assertEq(registry.identityOf(failingUser).activeKeyVersion, 0);
  }

  function test_crossChainCounterpartyRequiresProgressionSecretAlongsideEveryDelegationPolicy() public {
    bytes32 secret = keccak256('boundary-bob-secret');
    for (uint8 i; i <= uint8(DelegationPolicy.SpecificDelegate); ++i) {
      DelegationPolicy policy = DelegationPolicy(i);
      CommitAuthorizationRequest memory request = _crossCounterpartyRequest(policy, bytes32(uint256(i + 10)), secret);
      bytes memory signature = _signature(request, address(gateway));
      address caller = policy == DelegationPolicy.SpecificDelegate ? broker : relayer;
      request.bobCommitSecret = bytes32(0);
      vm.expectRevert(ProgressionGate.MissingBobCommitSecret.selector);
      _authorize(false, request, signature, caller);
      request.bobCommitSecret = secret;
      _authorize(false, request, signature, caller);
    }
  }

  function test_directCallCannotForgeEitherTrustedBoundary() public {
    ProtocolTerms memory walletTerms = _terms(address(wallet), AuthorizationMode.QuipWallet, 0);
    CommitAuthorizationRequest memory request = _request(walletTerms, keccak256('forged'));
    bytes32 hash = _payload(request, address(wallet));
    vm.expectRevert();
    receiver.receiveAuthorizedCommit(
      request.terms,
      true,
      LOCK,
      bytes32(0),
      _evidence(hash, relayer, address(wallet), request.actionNonce, request.expiry),
      ''
    );
  }

  function _assertCommonRejections(bool walletPath) internal {
    address principal = walletPath ? address(wallet) : directUser;
    AuthorizationMode mode = walletPath ? AuthorizationMode.QuipWallet : AuthorizationMode.RegisteredDirect;
    uint256 version = walletPath ? 0 : 1;
    address boundary = walletPath ? address(wallet) : address(gateway);
    ProtocolTerms memory terms = _terms(principal, mode, version);
    CommitAuthorizationRequest memory request = _request(terms, keccak256(abi.encode(walletPath, 'common')));

    vm.expectRevert();
    _authorize(walletPath, request, hex'bad0', relayer);
    CommitAuthorizationRequest memory expired = _request(terms, keccak256(abi.encode(walletPath, 'expired')));
    expired.expiry = block.timestamp;
    bytes memory expiredSignature = _signature(expired, boundary);
    if (walletPath) {
      vm.expectRevert(QuipWalletAuthorizationAdapter.AuthorizationExpired.selector);
      vm.prank(relayer);
      wallet.authorizeCommit(expired, expiredSignature);
    } else {
      vm.expectRevert(PQAuthorizationGateway.AuthorizationExpired.selector);
      vm.prank(relayer);
      gateway.authorizeCommit(expired, expiredSignature);
    }

    bytes memory signature = _signature(request, boundary);
    _authorize(walletPath, request, signature, relayer);
    vm.expectRevert();
    _authorize(walletPath, request, signature, relayer);

    AuthorizationReceiverHarness other = new AuthorizationReceiverHarness(address(gateway));
    request.actionNonce = keccak256(abi.encode(walletPath, 'substitute'));
    signature = _signature(request, boundary);
    request.receiver = address(other);
    vm.expectRevert();
    _authorize(walletPath, request, signature, relayer);
  }

  function _assertReceiverRollback(bool walletPath) internal {
    address principal = walletPath ? address(wallet) : directUser;
    AuthorizationMode mode = walletPath ? AuthorizationMode.QuipWallet : AuthorizationMode.RegisteredDirect;
    address boundary = walletPath ? address(wallet) : address(gateway);
    ProtocolTerms memory terms = _terms(principal, mode, walletPath ? 0 : 1);
    CommitAuthorizationRequest memory request = _request(terms, keccak256(abi.encode(walletPath, 'rollback')));
    request.commitData = 'fail';
    bytes memory signature = _signature(request, boundary);
    vm.expectRevert();
    _authorize(walletPath, request, signature, relayer);
    request.commitData = 'retry';
    _authorize(walletPath, request, signature, relayer);
  }

  function _authorize(
    bool walletPath,
    CommitAuthorizationRequest memory request,
    bytes memory signature,
    address caller
  ) internal {
    vm.prank(caller);
    if (walletPath) wallet.authorizeCommit(request, signature);
    else gateway.authorizeCommit(request, signature);
  }

  function _crossCounterpartyRequest(
    DelegationPolicy policy,
    bytes32 nonce,
    bytes32 secret
  ) internal view returns (CommitAuthorizationRequest memory request) {
    ProtocolTerms memory terms = _terms(address(0xA11CE), AuthorizationMode.RegisteredDirect, 1);
    terms.partySide.chainId = block.chainid + 1;
    terms.partySide.sideNonce = keccak256(abi.encode(nonce, 'party'));
    terms.counterpartySide = _side(directUser, AuthorizationMode.RegisteredDirect, 1, address(0), 0);
    terms.counterpartySide.sideNonce = keccak256(abi.encode(nonce, 'counterparty'));
    terms.counterpartySide.delegationPolicy = policy;
    if (policy == DelegationPolicy.SpecificDelegate) {
      terms.counterpartySide.delegate = broker;
      terms.counterpartySide.delegateKeyVersion = 1;
    }
    terms.counterpartySide.commitLock = ProtocolHashing.commitLock(ProtocolHashing.gateContextId(terms), secret);
    request = _request(terms, nonce);
    request.party = false;
    request.bobCommitSecret = secret;
  }

  function _request(
    ProtocolTerms memory terms,
    bytes32 nonce
  ) internal view returns (CommitAuthorizationRequest memory) {
    return CommitAuthorizationRequest({
      receiver: address(receiver),
      terms: terms,
      party: true,
      lock: LOCK,
      actionNonce: nonce,
      bobCommitSecret: bytes32(0),
      expiry: 2000,
      commitData: hex'c0ffee'
    });
  }

  function _signature(
    CommitAuthorizationRequest memory request,
    address boundary
  ) internal view returns (bytes memory) {
    return _pqSig(boundary == address(wallet) ? walletPQKey : directPQKey, _payload(request, boundary));
  }

  function _payload(CommitAuthorizationRequest memory request, address boundary) internal pure returns (bytes32) {
    return ProtocolHashing.commitPayloadHash(
      request.terms,
      request.party,
      boundary,
      request.receiver,
      request.lock,
      ExpectedSourceState.Unused,
      request.actionNonce,
      request.expiry
    );
  }

  function _terms(
    address principal,
    AuthorizationMode mode,
    uint256 version
  ) internal view returns (ProtocolTerms memory terms) {
    terms.partySide = _side(principal, mode, version, address(0), 0);
    terms.counterpartySide = _side(address(0xB0B), AuthorizationMode.RegisteredDirect, 1, address(0), 0);
  }

  function _specificTerms(
    address principal,
    AuthorizationMode mode,
    uint256 version
  ) internal view returns (ProtocolTerms memory terms) {
    terms = _terms(principal, mode, version);
    terms.partySide.delegationPolicy = DelegationPolicy.SpecificDelegate;
    terms.partySide.delegate = broker;
    terms.partySide.delegateKeyVersion = 1;
  }

  function _side(
    address principal,
    AuthorizationMode mode,
    uint256 version,
    address delegate,
    uint256 delegateVersion
  ) internal view returns (SideTerms memory side) {
    Asset[] memory assets = new Asset[](1);
    assets[0] = Asset({assetType: AssetType.Native, target: address(0), id: 0, amount: 1});
    side = SideTerms({
      chainId: block.chainid,
      assets: assets,
      principal: principal,
      authorizationMode: mode,
      principalKeyVersion: version,
      reclaimRecipient: principal,
      recipient: address(0xCAFE),
      commitmentDeadline: 3000,
      claimDeadline: 4000,
      reclaimRelease: 5000,
      commitLock: bytes32(0),
      delegationPolicy: DelegationPolicy.NotAllowed,
      delegate: delegate,
      delegateKeyVersion: delegateVersion,
      sideNonce: keccak256(abi.encode(principal, mode))
    });
  }

  function _lazyRegistration(
    address eoa,
    bytes memory key,
    bytes32 payloadHash
  ) internal view returns (InitialRegistration memory) {
    return InitialRegistration({
      eoa: eoa,
      activePQKey: key,
      recoveryPQKey: _key('lazy-recovery'),
      commitTarget: address(gateway),
      commitPayloadHash: payloadHash,
      operationNonce: keccak256(abi.encode('lazy', eoa)),
      expiry: 2000
    });
  }

  function _registrationProofs(InitialRegistration memory request)
    internal
    view
    returns (bytes memory activeProof, bytes memory recoveryProof)
  {
    bytes32 digest = registry.registrationDigest(request);
    bytes32 activeDigest =
      keccak256(abi.encode('InterlockKeyPossession-v1.1', digest, KeyRole.Active, keccak256(request.activePQKey)));
    bytes32 recoveryDigest =
      keccak256(abi.encode('InterlockKeyPossession-v1.1', digest, KeyRole.Recovery, keccak256(request.recoveryPQKey)));
    return (_pqSig(request.activePQKey, activeDigest), _pqSig(request.recoveryPQKey, recoveryDigest));
  }

  function _register(address eoa, bytes memory key) internal {
    InitialRegistration memory request = InitialRegistration({
      eoa: eoa,
      activePQKey: key,
      recoveryPQKey: _key('recovery'),
      commitTarget: address(registrationTarget),
      commitPayloadHash: keccak256('registration'),
      operationNonce: keccak256(abi.encode(eoa)),
      expiry: 2000
    });
    bytes32 digest = registry.registrationDigest(request);
    bytes32 activeProof = keccak256(abi.encode('InterlockKeyPossession-v1.1', digest, KeyRole.Active, keccak256(key)));
    bytes32 recoveryProof =
      keccak256(abi.encode('InterlockKeyPossession-v1.1', digest, KeyRole.Recovery, keccak256(request.recoveryPQKey)));
    vm.prank(eoa);
    registry.registerAndCommit(request, '', _pqSig(key, activeProof), _pqSig(request.recoveryPQKey, recoveryProof), '');
  }

  function _key(string memory label) internal view returns (bytes memory) {
    return abi.encodePacked(address(verifier), bytes(label));
  }

  function _pqSig(bytes memory keyedVerifier, bytes32 digest) internal pure returns (bytes memory) {
    bytes memory key = new bytes(keyedVerifier.length - 20);
    for (uint256 i; i < key.length; ++i) {
      key[i] = keyedVerifier[i + 20];
    }
    return abi.encode(key, digest);
  }

  function _evidence(
    bytes32 payloadHash,
    address caller,
    address submitter,
    bytes32 nonce,
    uint256 expiry
  ) internal pure returns (VerifiedCommitAuthorization memory evidence) {
    evidence.payloadHash = payloadHash;
    evidence.wrapperCaller = caller;
    evidence.authenticatedSubmitter = submitter;
    evidence.expectedSourceState = ExpectedSourceState.Unused;
    evidence.actionNonce = nonce;
    evidence.expiry = expiry;
  }
}
