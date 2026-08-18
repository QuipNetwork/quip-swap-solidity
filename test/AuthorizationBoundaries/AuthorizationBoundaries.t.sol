// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {DirectAuthorization} from '../../src/authorization/direct/DirectAuthorization.sol';
import {AuthorizationSubmitter} from '../../src/authorization/shared/AuthorizationSubmitter.sol';
import {QuipWallet} from '../../src/authorization/wallet/QuipWallet.sol';
import {ICommitAuthorizationReceiver} from '../../src/interfaces/ICommitAuthorizationReceiver.sol';
import {ProgressionGate} from '../../src/protocol/CommitValidation.sol';
import {ProtocolHashing} from '../../src/protocol/ProtocolHashing.sol';
import {
  AuthorizationMode,
  CommitAuthorizationRequest,
  DelegationPolicy,
  ExpectedSourceState,
  InitialRegistration,
  KeyRole,
  ProtocolTerms,
  RegistryActionTag,
  RegistryAuthorization,
  RegistryOperation,
  SideTerms,
  VerifiedCommitAuthorization
} from '../../src/protocol/ProtocolTypes.sol';
import {Asset, AssetType} from '../../src/protocol/ProtocolTypes.sol';
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

  DirectAuthorization internal registry;
  DirectAuthorization internal gateway;
  QuipWallet internal wallet;
  AuthorizationReceiverHarness internal receiver;
  RegisteredCommitTargetHarness internal registrationTarget;
  KeyBoundVerifierMock internal verifier;
  bytes internal directPQKey;
  bytes internal walletPQKey;

  function setUp() public {
    directUser = vm.addr(DIRECT_KEY);
    broker = vm.addr(BROKER_KEY);
    vm.warp(1000);
    verifier = new KeyBoundVerifierMock();
    registry = new DirectAuthorization(address(verifier));
    directPQKey = _key('direct');
    walletPQKey = _key('wallet-1');
    registrationTarget = new RegisteredCommitTargetHarness();
    _register(directUser, directPQKey);
    _register(broker, _key('broker'));
    gateway = registry;
    receiver = new AuthorizationReceiverHarness(address(gateway));
    wallet = new QuipWallet(owner, registry, walletPQKey);
  }

  function test_walletConstructorAndExecuteFailuresAreAtomic() public {
    vm.expectRevert(QuipWallet.InvalidKey.selector);
    new QuipWallet(address(0), registry, walletPQKey);
    vm.expectRevert(QuipWallet.InvalidKey.selector);
    new QuipWallet(owner, registry, '');

    bytes32 keyHash = wallet.activeKeyHash();
    vm.expectRevert(QuipWallet.NotOwner.selector);
    vm.prank(relayer);
    wallet.execute(address(receiver), 0, hex'deadbeef');
    _assertWalletState(1, keyHash, 0);

    vm.expectRevert(QuipWallet.ExecutionFailed.selector);
    vm.prank(owner);
    wallet.execute(address(receiver), 0, hex'deadbeef');
    _assertWalletState(1, keyHash, 0);
  }

  function test_walletRejectsMalformedCommitContextWithoutEffects() public {
    bytes32 keyHash = wallet.activeKeyHash();

    ProtocolTerms memory wrongMode = _terms(address(wallet), AuthorizationMode.RegisteredDirect, 1);
    CommitAuthorizationRequest memory request = _request(wrongMode, keccak256('wrong-mode'));
    vm.expectRevert(QuipWallet.InvalidAuthorizationMode.selector);
    wallet.authorizeCommit(request, hex'00');
    _assertWalletState(1, keyHash, 0);

    ProtocolTerms memory wrongPrincipal = _terms(address(0xBAD), AuthorizationMode.QuipWallet, 0);
    request = _request(wrongPrincipal, keccak256('wrong-principal'));
    vm.expectRevert(QuipWallet.InvalidWalletPrincipal.selector);
    wallet.authorizeCommit(request, hex'00');
    _assertWalletState(1, keyHash, 0);

    ProtocolTerms memory wrongChain = _terms(address(wallet), AuthorizationMode.QuipWallet, 0);
    wrongChain.partySide.chainId = block.chainid + 1;
    request = _request(wrongChain, keccak256('wrong-chain'));
    vm.expectRevert(QuipWallet.InvalidChain.selector);
    wallet.authorizeCommit(request, hex'00');
    _assertWalletState(1, keyHash, 0);

    ProtocolTerms memory validTerms = _terms(address(wallet), AuthorizationMode.QuipWallet, 0);
    validTerms.partySide.delegationPolicy = DelegationPolicy.Permissionless;
    request = _request(validTerms, keccak256('exclusive-expiry'));
    request.expiry = block.timestamp;
    vm.expectRevert(QuipWallet.AuthorizationExpired.selector);
    vm.prank(relayer);
    wallet.authorizeCommit(request, hex'00');
    _assertWalletState(1, keyHash, 0);

    request = _request(validTerms, keccak256('invalid-signature'));
    vm.expectRevert(QuipWallet.InvalidPQAuthorization.selector);
    vm.prank(relayer);
    wallet.authorizeCommit(request, _pqSig(walletPQKey, keccak256('wrong-wallet-digest')));
    _assertWalletState(1, keyHash, 0);

    // The exact rejected request and nonce remain usable with a valid envelope.
    bytes memory validSignature = _signature(request, address(wallet));
    vm.prank(relayer);
    wallet.authorizeCommit(request, validSignature);
    assertEq(receiver.commits(), 1);
  }

  function test_walletRotationFailuresAreAtomicAndNonceScoped() public {
    bytes32 initialHash = wallet.activeKeyHash();
    bytes memory nextKey = _key('wallet-failure-next');
    bytes32 nonce = keccak256('wallet-failure-rotation');
    uint256 expiry = 2000;
    bytes32 digest = wallet.rotationDigest(nextKey, nonce, expiry);
    bytes32 proofDigest = _walletPossessionDigest(digest, nextKey);

    vm.expectRevert(QuipWallet.NotOwner.selector);
    vm.prank(relayer);
    wallet.rotateActiveKey(nextKey, nonce, expiry, _pqSig(walletPQKey, digest), _pqSig(nextKey, proofDigest));
    _assertWalletState(1, initialHash, 0);
    assertFalse(wallet.consumedRotationNonces(nonce));

    vm.expectRevert(QuipWallet.InvalidKey.selector);
    vm.prank(owner);
    wallet.rotateActiveKey('', nonce, expiry, '', '');
    _assertWalletState(1, initialHash, 0);
    assertFalse(wallet.consumedRotationNonces(nonce));

    vm.expectRevert(QuipWallet.AuthorizationExpired.selector);
    vm.prank(owner);
    wallet.rotateActiveKey(nextKey, nonce, block.timestamp, '', '');
    _assertWalletState(1, initialHash, 0);
    assertFalse(wallet.consumedRotationNonces(nonce));

    vm.expectRevert(QuipWallet.InvalidPQAuthorization.selector);
    vm.prank(owner);
    wallet.rotateActiveKey(
      nextKey, nonce, expiry, _pqSig(walletPQKey, keccak256('wrong-current')), _pqSig(nextKey, proofDigest)
    );
    _assertWalletState(1, initialHash, 0);
    assertFalse(wallet.consumedRotationNonces(nonce));

    vm.expectRevert(QuipWallet.InvalidPQAuthorization.selector);
    vm.prank(owner);
    wallet.rotateActiveKey(
      nextKey, nonce, expiry, _pqSig(walletPQKey, digest), _pqSig(nextKey, keccak256('wrong-proof'))
    );
    _assertWalletState(1, initialHash, 0);
    assertFalse(wallet.consumedRotationNonces(nonce));

    _rotateWallet(walletPQKey, nextKey, nonce, expiry);
    walletPQKey = nextKey;
    _assertWalletState(2, keccak256(nextKey), 0);
    assertTrue(wallet.consumedRotationNonces(nonce));

    vm.expectRevert(QuipWallet.RotationNonceAlreadyConsumed.selector);
    vm.prank(owner);
    wallet.rotateActiveKey(_key('unused-replacement'), nonce, expiry, '', '');
    _assertWalletState(2, keccak256(nextKey), 0);
  }

  function test_walletRotateAwayAndBackCannotResurrectOldCommitAuthorization() public {
    ProtocolTerms memory terms = _terms(address(wallet), AuthorizationMode.QuipWallet, 0);
    terms.partySide.delegationPolicy = DelegationPolicy.Permissionless;
    CommitAuthorizationRequest memory pending = _request(terms, keccak256('rotate-away-pending'));
    bytes memory staleSignature = _signature(pending, address(wallet));
    bytes memory originalKey = walletPQKey;
    bytes memory secondKey = _key('wallet-away-key');
    bytes32 awayNonce = keccak256('wallet-away');

    _rotateWallet(originalKey, secondKey, awayNonce, 2000);
    walletPQKey = secondKey;
    _rotateWallet(secondKey, originalKey, keccak256('wallet-back'), 2000);
    walletPQKey = originalKey;
    _assertWalletState(3, keccak256(originalKey), 0);

    vm.expectRevert(QuipWallet.InvalidPQAuthorization.selector);
    vm.prank(relayer);
    wallet.authorizeCommit(pending, staleSignature);
    _assertWalletState(3, keccak256(originalKey), 0);

    vm.expectRevert(QuipWallet.RotationNonceAlreadyConsumed.selector);
    vm.prank(owner);
    wallet.rotateActiveKey(secondKey, awayNonce, 2000, '', '');
    _assertWalletState(3, keccak256(originalKey), 0);

    bytes memory freshSignature = _signature(pending, address(wallet));
    vm.prank(relayer);
    wallet.authorizeCommit(pending, freshSignature);
    assertEq(receiver.commits(), 1);
  }

  function test_genericWalletExecutionCannotFabricateAuthorizationEvidence() public {
    ProtocolTerms memory terms = _terms(address(wallet), AuthorizationMode.QuipWallet, 0);
    CommitAuthorizationRequest memory request = _request(terms, keccak256('generic-bypass'));
    bytes32 payloadHash = _payload(request, address(wallet));
    VerifiedCommitAuthorization memory forged =
      _evidence(payloadHash, address(wallet), address(wallet), request.actionNonce, request.expiry);
    bytes memory bypass = abi.encodeCall(
      ICommitAuthorizationReceiver.receiveAuthorizedCommit,
      (request.terms, request.party, request.lock, request.bobCommitSecret, forged, request.commitData)
    );

    vm.expectRevert(QuipWallet.ForbiddenAuthorizationBypass.selector);
    vm.prank(owner);
    wallet.execute(address(receiver), 0, bypass);
    _assertWalletState(1, keccak256(walletPQKey), 0);

    // Self-execution through authorizeCommit remains available and performs PQ
    // verification before exporting trusted evidence.
    bytes memory signature = _signature(request, address(wallet));
    vm.prank(owner);
    wallet.execute(address(wallet), 0, abi.encodeCall(QuipWallet.authorizeCommit, (request, signature)));
    assertEq(receiver.commits(), 1);
    assertEq(receiver.lastSubmitter(), address(wallet));
  }

  function test_walletAndGatewayProduceIdenticalSharedAdmissionSemantics() public {
    ProtocolTerms memory walletTerms = _terms(address(wallet), AuthorizationMode.QuipWallet, 0);
    walletTerms.partySide.delegationPolicy = DelegationPolicy.Permissionless;
    CommitAuthorizationRequest memory walletRequest = _request(walletTerms, keccak256('wallet-nonce'));
    bytes memory walletSignature = _signature(walletRequest, address(wallet));
    vm.prank(relayer);
    wallet.authorizeCommit(walletRequest, walletSignature);
    assertEq(receiver.lastSubmitter(), relayer);

    ProtocolTerms memory directTerms = _terms(directUser, AuthorizationMode.RegisteredDirect, 1);
    directTerms.partySide.delegationPolicy = DelegationPolicy.Permissionless;
    CommitAuthorizationRequest memory directRequest = _request(directTerms, keccak256('direct-nonce'));
    vm.prank(relayer);
    gateway.authorizeCommit(directRequest, _signature(directRequest, address(gateway)));
    assertEq(receiver.lastSubmitter(), relayer);
    assertEq(receiver.commits(), 2);
  }

  function test_commitSignatureRejectsCrossDeploymentCrossChainAndCrossSideReplay() public {
    ProtocolTerms memory terms = _terms(directUser, AuthorizationMode.RegisteredDirect, 1);
    CommitAuthorizationRequest memory request = _request(terms, keccak256('replay-scope'));
    bytes memory signature = _signature(request, address(gateway));

    // A second direct boundary has the same registered key, but a different signed verifier address.
    DirectAuthorization otherAuthorization = new DirectAuthorization(address(verifier));
    _registerAt(otherAuthorization, directUser, directPQKey);
    vm.expectRevert(DirectAuthorization.InvalidPQAuthorization.selector);
    vm.prank(relayer);
    otherAuthorization.authorizeCommit(request, signature);

    // The unchanged authorization cannot execute on another chain.
    uint256 originalChainId = block.chainid;
    vm.chainId(originalChainId + 1);
    vm.expectRevert(DirectAuthorization.InvalidChain.selector);
    vm.prank(relayer);
    gateway.authorizeCommit(request, signature);
    vm.chainId(originalChainId);

    // Selecting the other side changes the signed SideTag and all side-specific bindings.
    request.terms.counterpartySide = request.terms.partySide;
    request.party = false;
    vm.expectRevert(DirectAuthorization.InvalidPQAuthorization.selector);
    vm.prank(relayer);
    gateway.authorizeCommit(request, signature);
  }

  function test_commitSignatureRejectsCrossActionRegistryReplay() public {
    ProtocolTerms memory terms = _terms(directUser, AuthorizationMode.RegisteredDirect, 1);
    CommitAuthorizationRequest memory commitRequest = _request(terms, keccak256('cross-action'));
    bytes memory commitSignature = _signature(commitRequest, address(gateway));

    RegistryOperation memory operation = RegistryOperation({
      action: RegistryActionTag.RotateRecovery,
      eoa: directUser,
      expectedActiveKeyVersion: 1,
      expectedRecoveryKeyVersion: 1,
      newActivePQKey: '',
      newActiveKeyVersion: 0,
      newRecoveryPQKey: _key('cross-action-recovery'),
      newRecoveryKeyVersion: 2,
      operationNonce: commitRequest.actionNonce,
      expiry: commitRequest.expiry,
      recoveryAuthorized: false
    });
    RegistryAuthorization memory authorization;
    authorization.authorizingPQSignature = commitSignature;
    vm.expectRevert(DirectAuthorization.InvalidPQAuthorization.selector);
    vm.prank(directUser);
    registry.execute(operation, authorization);
  }

  function test_bothPathsRejectBadSignatureExpiryReplayAndReceiverSubstitution() public {
    _assertCommonRejections(true);
    _assertCommonRejections(false);
  }

  function test_notAllowedRequiresActualPrincipalTransportOnBothPaths() public {
    ProtocolTerms memory walletTerms = _terms(address(wallet), AuthorizationMode.QuipWallet, 0);
    CommitAuthorizationRequest memory walletRequest = _request(walletTerms, keccak256('wallet-principal-only'));
    bytes memory walletSignature = _signature(walletRequest, address(wallet));
    vm.expectRevert(AuthorizationSubmitter.InvalidTransportSubmitter.selector);
    vm.prank(relayer);
    wallet.authorizeCommit(walletRequest, walletSignature);
    vm.prank(owner);
    wallet.execute(address(wallet), 0, abi.encodeCall(QuipWallet.authorizeCommit, (walletRequest, walletSignature)));
    assertEq(receiver.lastSubmitter(), address(wallet));

    ProtocolTerms memory directTerms = _terms(directUser, AuthorizationMode.RegisteredDirect, 1);
    CommitAuthorizationRequest memory directRequest = _request(directTerms, keccak256('direct-principal-only'));
    bytes memory directSignature = _signature(directRequest, address(gateway));
    vm.expectRevert(AuthorizationSubmitter.InvalidTransportSubmitter.selector);
    vm.prank(relayer);
    gateway.authorizeCommit(directRequest, directSignature);
    vm.prank(directUser);
    gateway.authorizeCommit(directRequest, directSignature);
    assertEq(receiver.lastSubmitter(), directUser);
  }

  function test_specificDelegateAllowsPrincipalOrRegisteredDelegateOnBothPaths() public {
    ProtocolTerms memory walletTerms = _specificTerms(address(wallet), AuthorizationMode.QuipWallet, 0);
    CommitAuthorizationRequest memory walletPrincipal = _request(walletTerms, keccak256('wallet-specific-principal'));
    bytes memory walletPrincipalSignature = _signature(walletPrincipal, address(wallet));
    vm.prank(owner);
    wallet.execute(
      address(wallet), 0, abi.encodeCall(QuipWallet.authorizeCommit, (walletPrincipal, walletPrincipalSignature))
    );
    assertEq(receiver.lastSubmitter(), address(wallet));

    CommitAuthorizationRequest memory walletDelegate = _request(walletTerms, keccak256('wallet-specific-delegate'));
    bytes memory walletDelegateSignature = _signature(walletDelegate, address(wallet));
    vm.prank(broker);
    wallet.authorizeCommit(walletDelegate, walletDelegateSignature);
    assertEq(receiver.lastSubmitter(), broker);

    ProtocolTerms memory directTerms = _specificTerms(directUser, AuthorizationMode.RegisteredDirect, 1);
    CommitAuthorizationRequest memory directPrincipal = _request(directTerms, keccak256('direct-specific-principal'));
    vm.prank(directUser);
    gateway.authorizeCommit(directPrincipal, _signature(directPrincipal, address(gateway)));
    assertEq(receiver.lastSubmitter(), directUser);

    CommitAuthorizationRequest memory directDelegate = _request(directTerms, keccak256('direct-specific-delegate'));
    vm.prank(broker);
    gateway.authorizeCommit(directDelegate, _signature(directDelegate, address(gateway)));
    assertEq(receiver.lastSubmitter(), broker);
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
    bytes memory walletSignature = _signature(walletRequest, address(wallet));
    vm.prank(relayer);
    wallet.authorizeCommit(walletRequest, walletSignature);
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
    terms.partySide.delegationPolicy = DelegationPolicy.Permissionless;
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

    vm.expectRevert(QuipWallet.InvalidPQAuthorization.selector);
    wallet.authorizeCommit(pending, oldPendingSignature);
    wallet.authorizeCommit(pending, _signature(pending, address(wallet)));
    assertEq(receiver.commits(), 2);
  }

  function test_directPrincipalRotationRejectsStaleCommitKeyVersion() public {
    ProtocolTerms memory terms = _terms(directUser, AuthorizationMode.RegisteredDirect, 1);
    CommitAuthorizationRequest memory pending = _request(terms, keccak256('stale-direct'));
    bytes memory staleSignature = _signature(pending, address(gateway));
    bytes memory newKey = _key('direct-2');
    _rotateActive(directUser, directPQKey, newKey);

    vm.expectRevert(DirectAuthorization.InvalidVersion.selector);
    vm.prank(directUser);
    gateway.authorizeCommit(pending, staleSignature);

    directPQKey = newKey;
    terms.partySide.principalKeyVersion = 2;
    CommitAuthorizationRequest memory current = _request(terms, keccak256('current-direct'));
    vm.prank(directUser);
    gateway.authorizeCommit(current, _signature(current, address(gateway)));
    assertEq(receiver.lastSubmitter(), directUser);
  }

  function test_specificDelegateRotationRejectsStaleBrokerVersion() public {
    ProtocolTerms memory terms = _specificTerms(directUser, AuthorizationMode.RegisteredDirect, 1);
    CommitAuthorizationRequest memory pending = _request(terms, keccak256('stale-broker'));
    bytes memory signature = _signature(pending, address(gateway));
    _rotateActive(broker, _key('broker'), _key('broker-2'));

    vm.expectRevert(DirectAuthorization.InvalidVersion.selector);
    vm.prank(broker);
    gateway.authorizeCommit(pending, signature);
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
    vm.expectRevert(DirectAuthorization.CommitCallbackFailed.selector);
    vm.prank(failingUser);
    registry.registerAndCommit(registration, '', activeProof, recoveryProof, abi.encode(request, signature));
    assertEq(registry.identityOf(failingUser).activeKeyVersion, 0);
  }

  function test_atomicLazyBrokerRegistrationPreservesPrincipalAuthorization() public {
    uint256 newcomerKey = 0xB012;
    address newcomer = vm.addr(newcomerKey);
    bytes memory newcomerPQKey = _key('new-broker');
    ProtocolTerms memory terms = _specificTerms(directUser, AuthorizationMode.RegisteredDirect, 1);
    terms.partySide.delegate = newcomer;
    terms.partySide.delegateKeyVersion = 1;
    CommitAuthorizationRequest memory request = _request(terms, keccak256('lazy-broker'));
    bytes32 payloadHash = _payload(request, address(gateway));
    bytes memory principalSignature = _pqSig(directPQKey, payloadHash);
    InitialRegistration memory registration = _lazyRegistration(newcomer, newcomerPQKey, payloadHash);
    (bytes memory activeProof, bytes memory recoveryProof) = _registrationProofs(registration);

    vm.prank(relayer);
    registry.registerAndCommit(
      registration,
      _eoaSig(newcomerKey, registry.registrationDigest(registration)),
      activeProof,
      recoveryProof,
      abi.encode(request, principalSignature)
    );

    assertEq(registry.identityOf(newcomer).activeKeyVersion, 1);
    assertEq(receiver.lastSubmitter(), newcomer);
    assertEq(receiver.commits(), 1);
  }

  function test_failedLazyBrokerCommitRollsBackRegistrationAndAuthorizationNonce() public {
    uint256 newcomerKey = 0xFA12;
    address newcomer = vm.addr(newcomerKey);
    bytes memory newcomerPQKey = _key('failing-broker');
    ProtocolTerms memory terms = _specificTerms(directUser, AuthorizationMode.RegisteredDirect, 1);
    terms.partySide.delegate = newcomer;
    terms.partySide.delegateKeyVersion = 1;
    CommitAuthorizationRequest memory request = _request(terms, keccak256('failed-lazy-broker'));
    request.commitData = 'fail';
    bytes32 payloadHash = _payload(request, address(gateway));
    bytes memory principalSignature = _pqSig(directPQKey, payloadHash);
    InitialRegistration memory registration = _lazyRegistration(newcomer, newcomerPQKey, payloadHash);
    (bytes memory activeProof, bytes memory recoveryProof) = _registrationProofs(registration);

    vm.expectRevert(DirectAuthorization.CommitCallbackFailed.selector);
    vm.prank(newcomer);
    registry.registerAndCommit(registration, '', activeProof, recoveryProof, abi.encode(request, principalSignature));
    assertEq(registry.identityOf(newcomer).activeKeyVersion, 0);
    assertEq(receiver.commits(), 0);

    request.commitData = 'retry';
    vm.prank(newcomer);
    registry.registerAndCommit(registration, '', activeProof, recoveryProof, abi.encode(request, principalSignature));
    assertEq(registry.identityOf(newcomer).activeKeyVersion, 1);
    assertEq(receiver.lastSubmitter(), newcomer);
    assertEq(receiver.commits(), 1);
  }

  function test_lazyBrokerRegistrationRejectsNonDelegateAndNonPrincipalSignature() public {
    address newcomer = vm.addr(0xBAD1);
    bytes memory newcomerPQKey = _key('wrong-broker');
    ProtocolTerms memory terms = _specificTerms(directUser, AuthorizationMode.RegisteredDirect, 1);
    CommitAuthorizationRequest memory request = _request(terms, keccak256('wrong-lazy-broker'));
    bytes32 payloadHash = _payload(request, address(gateway));
    InitialRegistration memory registration = _lazyRegistration(newcomer, newcomerPQKey, payloadHash);
    (bytes memory activeProof, bytes memory recoveryProof) = _registrationProofs(registration);

    vm.expectRevert(DirectAuthorization.CommitCallbackFailed.selector);
    vm.prank(newcomer);
    registry.registerAndCommit(
      registration, '', activeProof, recoveryProof, abi.encode(request, _pqSig(directPQKey, payloadHash))
    );
    assertEq(registry.identityOf(newcomer).activeKeyVersion, 0);

    terms.partySide.delegate = newcomer;
    request = _request(terms, keccak256('wrong-principal-signature'));
    payloadHash = _payload(request, address(gateway));
    registration = _lazyRegistration(newcomer, newcomerPQKey, payloadHash);
    (activeProof, recoveryProof) = _registrationProofs(registration);
    vm.expectRevert(DirectAuthorization.CommitCallbackFailed.selector);
    vm.prank(newcomer);
    registry.registerAndCommit(
      registration, '', activeProof, recoveryProof, abi.encode(request, _pqSig(newcomerPQKey, payloadHash))
    );
    assertEq(registry.identityOf(newcomer).activeKeyVersion, 0);
  }

  function test_crossChainCounterpartyRequiresProgressionSecretAlongsideEveryDelegationPolicy() public {
    bytes32 secret = keccak256('boundary-bob-secret');
    for (uint8 i; i <= uint8(DelegationPolicy.SpecificDelegate); ++i) {
      DelegationPolicy policy = DelegationPolicy(i);
      CommitAuthorizationRequest memory request = _crossCounterpartyRequest(policy, bytes32(uint256(i + 10)), secret);
      bytes memory signature = _signature(request, address(gateway));
      address caller = policy == DelegationPolicy.NotAllowed
        ? directUser
        : policy == DelegationPolicy.SpecificDelegate ? broker : relayer;
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

  function _rotateWallet(bytes memory currentKey, bytes memory newKey, bytes32 nonce, uint256 expiry) internal {
    bytes32 digest = wallet.rotationDigest(newKey, nonce, expiry);
    vm.prank(owner);
    wallet.rotateActiveKey(
      newKey, nonce, expiry, _pqSig(currentKey, digest), _pqSig(newKey, _walletPossessionDigest(digest, newKey))
    );
  }

  function _walletPossessionDigest(bytes32 rotationDigest, bytes memory key) internal pure returns (bytes32) {
    return keccak256(abi.encode('InterlockKeyPossession-v1.1', rotationDigest, KeyRole.Active, keccak256(key)));
  }

  function _assertWalletState(uint256 epoch, bytes32 keyHash, uint256 commits) internal view {
    assertEq(wallet.walletKeyEpoch(), epoch);
    assertEq(wallet.activeKeyHash(), keyHash);
    assertEq(receiver.commits(), commits);
  }

  function _assertCommonRejections(bool walletPath) internal {
    address principal = walletPath ? address(wallet) : directUser;
    AuthorizationMode mode = walletPath ? AuthorizationMode.QuipWallet : AuthorizationMode.RegisteredDirect;
    uint256 version = walletPath ? 0 : 1;
    address boundary = walletPath ? address(wallet) : address(gateway);
    ProtocolTerms memory terms = _terms(principal, mode, version);
    terms.partySide.delegationPolicy = DelegationPolicy.Permissionless;
    CommitAuthorizationRequest memory request = _request(terms, keccak256(abi.encode(walletPath, 'common')));

    vm.expectRevert();
    _authorize(walletPath, request, hex'bad0', relayer);
    CommitAuthorizationRequest memory expired = _request(terms, keccak256(abi.encode(walletPath, 'expired')));
    expired.expiry = block.timestamp;
    bytes memory expiredSignature = _signature(expired, boundary);
    if (walletPath) {
      vm.expectRevert(QuipWallet.AuthorizationExpired.selector);
      vm.prank(relayer);
      wallet.authorizeCommit(expired, expiredSignature);
    } else {
      vm.expectRevert(DirectAuthorization.AuthorizationExpired.selector);
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
    terms.partySide.delegationPolicy = DelegationPolicy.Permissionless;
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
    bytes32 payloadHash = _payload(request, boundary);
    if (boundary == address(wallet)) {
      return _pqSig(walletPQKey, wallet.commitAuthorizationDigest(payloadHash));
    }
    return _pqSig(directPQKey, payloadHash);
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

  function _rotateActive(address eoa, bytes memory oldKey, bytes memory newKey) internal {
    RegistryOperation memory request = RegistryOperation({
      action: RegistryActionTag.RotateActive,
      eoa: eoa,
      expectedActiveKeyVersion: 1,
      expectedRecoveryKeyVersion: 1,
      newActivePQKey: newKey,
      newActiveKeyVersion: 2,
      newRecoveryPQKey: '',
      newRecoveryKeyVersion: 0,
      operationNonce: keccak256(abi.encode('rotate', eoa)),
      expiry: 2000,
      recoveryAuthorized: false
    });
    bytes32 digest = registry.operationDigest(request);
    RegistryAuthorization memory authorization;
    authorization.authorizingPQSignature = _pqSig(oldKey, digest);
    authorization.activeProofOfPossession = _pqSig(newKey, registry.possessionDigest(digest, KeyRole.Active, newKey));
    vm.prank(eoa);
    registry.execute(request, authorization);
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
    _registerAt(registry, eoa, key);
  }

  function _registerAt(DirectAuthorization target, address eoa, bytes memory key) internal {
    InitialRegistration memory request = InitialRegistration({
      eoa: eoa,
      activePQKey: key,
      recoveryPQKey: _key('recovery'),
      commitTarget: address(registrationTarget),
      commitPayloadHash: keccak256('registration'),
      operationNonce: keccak256(abi.encode(eoa)),
      expiry: 2000
    });
    bytes32 digest = target.registrationDigest(request);
    bytes32 activeProof = keccak256(abi.encode('InterlockKeyPossession-v1.1', digest, KeyRole.Active, keccak256(key)));
    bytes32 recoveryProof =
      keccak256(abi.encode('InterlockKeyPossession-v1.1', digest, KeyRole.Recovery, keccak256(request.recoveryPQKey)));
    vm.prank(eoa);
    target.registerAndCommit(request, '', _pqSig(key, activeProof), _pqSig(request.recoveryPQKey, recoveryProof), '');
  }

  function _key(string memory label) internal view returns (bytes memory) {
    return abi.encodePacked(address(verifier), keccak256(bytes(label)));
  }

  function _pqSig(bytes memory keyedVerifier, bytes32 digest) internal pure returns (bytes memory) {
    bytes memory key = new bytes(keyedVerifier.length - 20);
    for (uint256 i; i < key.length; ++i) {
      key[i] = keyedVerifier[i + 20];
    }
    return abi.encode(key, digest);
  }

  function _eoaSig(uint256 privateKey, bytes32 digest) internal pure returns (bytes memory) {
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
    return abi.encodePacked(r, s, v);
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
