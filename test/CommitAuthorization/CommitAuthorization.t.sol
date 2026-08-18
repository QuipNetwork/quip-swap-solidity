// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Test} from 'forge-std-1.14.0/Test.sol';

import {CommitAuthorization} from '../../src/protocol/CommitValidation.sol';
import {ProtocolHashing} from '../../src/protocol/ProtocolHashing.sol';
import {
  AuthorizationMode,
  DelegationPolicy,
  ExpectedSourceState,
  ProtocolTerms,
  SideTerms,
  VerifiedCommitAuthorization
} from '../../src/protocol/ProtocolTypes.sol';
import {Asset, AssetType} from '../../src/protocol/ProtocolTypes.sol';
import {CommitAuthorizationHarness} from '../harness/CommitAuthorizationHarness.sol';

contract CommitAuthorizationTest is Test {
  address internal constant ALICE = address(0xA11CE);
  address internal constant BOB = address(0xB0B);
  address internal constant BROKER = address(0xB0B0);
  address internal constant RELAYER = address(0x7E1A);
  address internal constant GATEWAY = address(0x6A7E);
  address internal constant TOKEN = address(0x70AE);
  bytes32 internal constant LOCK = keccak256('settlement-lock');
  bytes32 internal constant NONCE = keccak256('authorization-nonce');

  CommitAuthorizationHarness internal harness;

  function setUp() public {
    vm.warp(1000);
    harness = new CommitAuthorizationHarness(GATEWAY);
  }

  function test_walletNotAllowedAcceptsPrincipalAndConsumesNonceLast() public {
    ProtocolTerms memory terms = _crossChainTerms();
    VerifiedCommitAuthorization memory evidence = _evidence(terms, true, ALICE, 0, NONCE, 2000);
    bytes32 nonceKey = _nonceKey(terms.partySide, ALICE, NONCE);

    vm.prank(ALICE);
    harness.commitAuthorized(terms, true, LOCK, evidence, 0);

    assertEq(harness.stateEffects(), 1);
    assertEq(harness.custodyEffects(), 1);
    assertTrue(harness.isConsumed(nonceKey));
  }

  function test_directNotAllowedAcceptsRegisteredPrincipalVersion() public {
    ProtocolTerms memory terms = _crossChainTerms();
    VerifiedCommitAuthorization memory evidence = _evidence(terms, false, BOB, 7, NONCE, 2000);
    vm.prank(GATEWAY);
    harness.commitAuthorized(terms, false, LOCK, evidence, 0);
    assertTrue(harness.isConsumed(_nonceKey(terms.counterpartySide, GATEWAY, NONCE)));
  }

  function test_permissionlessAcceptsAnyAuthenticatedNonzeroSubmitter() public {
    ProtocolTerms memory terms = _crossChainTerms();
    terms.counterpartySide.delegationPolicy = DelegationPolicy.Permissionless;
    terms.counterpartySide.delegate = address(0);
    terms.counterpartySide.delegateKeyVersion = 0;
    VerifiedCommitAuthorization memory evidence = _evidence(terms, false, RELAYER, 91, NONCE, 2000);
    vm.prank(GATEWAY);
    harness.commitAuthorized(terms, false, LOCK, evidence, 0);
  }

  function test_specificDelegateRequiresExactBrokerAndVersion() public {
    ProtocolTerms memory terms = _crossChainTerms();
    terms.counterpartySide.delegationPolicy = DelegationPolicy.SpecificDelegate;
    terms.counterpartySide.delegate = BROKER;
    terms.counterpartySide.delegateKeyVersion = 3;
    VerifiedCommitAuthorization memory evidence = _evidence(terms, false, BROKER, 3, NONCE, 2000);
    vm.prank(GATEWAY);
    harness.commitAuthorized(terms, false, LOCK, evidence, 0);
  }

  function test_rejectsForgedActualBoundaryCaller() public {
    ProtocolTerms memory terms = _crossChainTerms();
    VerifiedCommitAuthorization memory evidence = _evidence(terms, false, BOB, 7, NONCE, 2000);
    vm.expectRevert(CommitAuthorization.InvalidAuthorizationCaller.selector);
    vm.prank(RELAYER);
    harness.commitAuthorized(terms, false, LOCK, evidence, 0);
  }

  function test_rejectsSubstitutedCallerInsideEvidence() public {
    ProtocolTerms memory terms = _crossChainTerms();
    VerifiedCommitAuthorization memory evidence = _evidence(terms, false, BOB, 7, NONCE, 2000);
    evidence.wrapperCaller = RELAYER;
    vm.expectRevert(CommitAuthorization.InvalidAuthorizationCaller.selector);
    vm.prank(GATEWAY);
    harness.commitAuthorized(terms, false, LOCK, evidence, 0);
  }

  function test_rejectsPayloadNotVerifiedForExactCommit() public {
    ProtocolTerms memory terms = _crossChainTerms();
    VerifiedCommitAuthorization memory evidence = _evidence(terms, false, BOB, 7, NONCE, 2000);
    evidence.payloadHash = bytes32(uint256(evidence.payloadHash) ^ 1);
    vm.expectRevert(CommitAuthorization.InvalidAuthorizationPayload.selector);
    vm.prank(GATEWAY);
    harness.commitAuthorized(terms, false, LOCK, evidence, 0);
  }

  function test_rejectsPayloadAuthorizedForWrongVerifier() public {
    ProtocolTerms memory terms = _crossChainTerms();
    VerifiedCommitAuthorization memory evidence = _evidence(terms, false, BOB, 7, NONCE, 2000);
    evidence.payloadHash = ProtocolHashing.commitPayloadHash(
      terms, false, RELAYER, address(harness), LOCK, evidence.expectedSourceState, NONCE, evidence.expiry
    );
    _expectInvalidPayload(terms, LOCK, evidence);
  }

  function test_rejectsTermsLockNonceAndExpirySubstitution() public {
    ProtocolTerms memory terms = _crossChainTerms();
    VerifiedCommitAuthorization memory evidence = _evidence(terms, false, BOB, 7, NONCE, 2000);

    ProtocolTerms memory changedTerms = _crossChainTerms();
    changedTerms.counterpartySide.sideNonce = bytes32(uint256(changedTerms.counterpartySide.sideNonce) ^ 1);
    _expectInvalidPayload(changedTerms, bytes32(LOCK), evidence);
    _expectInvalidPayload(terms, bytes32(uint256(LOCK) ^ 1), evidence);

    evidence.actionNonce = bytes32(uint256(NONCE) ^ 1);
    _expectInvalidPayload(terms, LOCK, evidence);
    evidence = _evidence(terms, false, BOB, 7, NONCE, 2000);
    evidence.expiry = 2001;
    _expectInvalidPayload(terms, LOCK, evidence);
  }

  function test_rejectsWrongExpectedSourceState() public {
    ProtocolTerms memory terms = _crossChainTerms();
    VerifiedCommitAuthorization memory evidence = _evidence(terms, false, BOB, 7, NONCE, 2000);
    evidence.expectedSourceState = ExpectedSourceState.PartyCommitted;
    vm.expectRevert(CommitAuthorization.InvalidExpectedSourceState.selector);
    vm.prank(GATEWAY);
    harness.commitAuthorized(terms, false, LOCK, evidence, 0);
  }

  function test_sameChainCounterpartyRequiresPartyCommittedSourceState() public {
    ProtocolTerms memory terms = _sameChainTerms();
    VerifiedCommitAuthorization memory evidence = _evidence(terms, false, BOB, 7, NONCE, 2000);
    assertEq(uint8(evidence.expectedSourceState), uint8(ExpectedSourceState.PartyCommitted));
    vm.prank(GATEWAY);
    harness.commitAuthorized(terms, false, LOCK, evidence, 0);
  }

  function test_expiryIsExclusiveAndDoesNotConsumeNonce() public {
    ProtocolTerms memory terms = _crossChainTerms();
    VerifiedCommitAuthorization memory evidence = _evidence(terms, false, BOB, 7, NONCE, block.timestamp);
    vm.expectRevert(CommitAuthorization.AuthorizationExpired.selector);
    vm.prank(GATEWAY);
    harness.commitAuthorized(terms, false, LOCK, evidence, 0);
    assertFalse(harness.isConsumed(_nonceKey(terms.counterpartySide, GATEWAY, NONCE)));
  }

  function test_notAllowedRejectsSubstitutedSubmitterAndVersion() public {
    ProtocolTerms memory terms = _crossChainTerms();
    VerifiedCommitAuthorization memory evidence = _evidence(terms, false, RELAYER, 7, NONCE, 2000);
    _expectSubmitterError(terms, evidence, CommitAuthorization.InvalidAuthenticatedSubmitter.selector);
    evidence = _evidence(terms, false, BOB, 8, NONCE, 2000);
    _expectSubmitterError(terms, evidence, CommitAuthorization.InvalidAuthenticatedSubmitterKeyVersion.selector);
  }

  function test_specificDelegateRejectsSubstitutedBrokerAndVersion() public {
    ProtocolTerms memory terms = _crossChainTerms();
    terms.counterpartySide.delegationPolicy = DelegationPolicy.SpecificDelegate;
    terms.counterpartySide.delegate = BROKER;
    terms.counterpartySide.delegateKeyVersion = 3;
    VerifiedCommitAuthorization memory evidence = _evidence(terms, false, RELAYER, 3, NONCE, 2000);
    _expectSubmitterError(terms, evidence, CommitAuthorization.InvalidAuthenticatedSubmitter.selector);
    evidence = _evidence(terms, false, BROKER, 4, NONCE, 2000);
    _expectSubmitterError(terms, evidence, CommitAuthorization.InvalidAuthenticatedSubmitterKeyVersion.selector);
  }

  function test_permissionlessStillRejectsZeroAuthenticatedIdentity() public {
    ProtocolTerms memory terms = _crossChainTerms();
    terms.counterpartySide.delegationPolicy = DelegationPolicy.Permissionless;
    VerifiedCommitAuthorization memory evidence = _evidence(terms, false, address(0), 0, NONCE, 2000);
    _expectSubmitterError(terms, evidence, CommitAuthorization.InvalidAuthenticatedSubmitter.selector);
  }

  function test_successfulAuthorizationCannotReplay() public {
    ProtocolTerms memory terms = _crossChainTerms();
    VerifiedCommitAuthorization memory evidence = _evidence(terms, false, BOB, 7, NONCE, 2000);
    bytes32 nonceKey = _nonceKey(terms.counterpartySide, GATEWAY, NONCE);
    vm.prank(GATEWAY);
    harness.commitAuthorized(terms, false, LOCK, evidence, 0);

    vm.expectRevert(abi.encodeWithSelector(CommitAuthorization.AuthorizationNonceAlreadyConsumed.selector, nonceKey));
    vm.prank(GATEWAY);
    harness.commitAuthorized(terms, false, LOCK, evidence, 0);
    assertEq(harness.stateEffects(), 1);
    assertEq(harness.custodyEffects(), 1);
  }

  function test_sameNonceIsScopedByPrincipalAndVerifier() public {
    ProtocolTerms memory terms = _crossChainTerms();
    VerifiedCommitAuthorization memory alice = _evidence(terms, true, ALICE, 0, NONCE, 2000);
    VerifiedCommitAuthorization memory bob = _evidence(terms, false, BOB, 7, NONCE, 2000);
    vm.prank(ALICE);
    harness.commitAuthorized(terms, true, LOCK, alice, 0);
    vm.prank(GATEWAY);
    harness.commitAuthorized(terms, false, LOCK, bob, 0);
    assertTrue(harness.isConsumed(_nonceKey(terms.partySide, ALICE, NONCE)));
    assertTrue(harness.isConsumed(_nonceKey(terms.counterpartySide, GATEWAY, NONCE)));
  }

  function test_authorizationNonceKeyScopesEverySpecifiedField() public pure {
    bytes32 base = keccak256(ProtocolHashing.encodeAuthorizationNonceKey(31_337, GATEWAY, BOB, 7, NONCE));
    assertNotEq(base, keccak256(ProtocolHashing.encodeAuthorizationNonceKey(31_338, GATEWAY, BOB, 7, NONCE)));
    assertNotEq(base, keccak256(ProtocolHashing.encodeAuthorizationNonceKey(31_337, RELAYER, BOB, 7, NONCE)));
    assertNotEq(base, keccak256(ProtocolHashing.encodeAuthorizationNonceKey(31_337, GATEWAY, ALICE, 7, NONCE)));
    assertNotEq(base, keccak256(ProtocolHashing.encodeAuthorizationNonceKey(31_337, GATEWAY, BOB, 8, NONCE)));
    assertNotEq(
      base, keccak256(ProtocolHashing.encodeAuthorizationNonceKey(31_337, GATEWAY, BOB, 7, bytes32(uint256(NONCE) + 1)))
    );
  }

  function test_sameAuthorizationNonceCannotAuthorizeDifferentTrade() public {
    ProtocolTerms memory first = _crossChainTerms();
    VerifiedCommitAuthorization memory firstEvidence = _evidence(first, false, BOB, 7, NONCE, 2000);
    vm.prank(GATEWAY);
    harness.commitAuthorized(first, false, LOCK, firstEvidence, 0);

    ProtocolTerms memory second = _crossChainTerms();
    second.partySide.sideNonce = keccak256('fresh-party-run');
    second.counterpartySide.sideNonce = keccak256('fresh-counterparty-run');
    assertNotEq(ProtocolHashing.tradeId(first), ProtocolHashing.tradeId(second));
    VerifiedCommitAuthorization memory secondEvidence = _evidence(second, false, BOB, 7, NONCE, 2000);
    bytes32 nonceKey = _nonceKey(second.counterpartySide, GATEWAY, NONCE);
    vm.expectRevert(abi.encodeWithSelector(CommitAuthorization.AuthorizationNonceAlreadyConsumed.selector, nonceKey));
    vm.prank(GATEWAY);
    harness.commitAuthorized(second, false, LOCK, secondEvidence, 0);
    assertEq(harness.stateEffects(), 1);
  }

  function test_nonMonotonicAuthorizationNoncesAreAccepted() public {
    ProtocolTerms memory first = _crossChainTerms();
    bytes32 highNonce = bytes32(type(uint256).max);
    vm.prank(GATEWAY);
    harness.commitAuthorized(first, false, LOCK, _evidence(first, false, BOB, 7, highNonce, 2000), 0);

    ProtocolTerms memory second = _crossChainTerms();
    second.counterpartySide.sideNonce = keccak256('second-run');
    bytes32 lowNonce = bytes32(uint256(1));
    vm.prank(GATEWAY);
    harness.commitAuthorized(second, false, LOCK, _evidence(second, false, BOB, 7, lowNonce, 2000), 0);
    assertTrue(harness.isConsumed(_nonceKey(first.counterpartySide, GATEWAY, highNonce)));
    assertTrue(harness.isConsumed(_nonceKey(second.counterpartySide, GATEWAY, lowNonce)));
  }

  function test_sideNoncesBindRunsButAreNotAuthorizationCounters() public pure {
    ProtocolTerms memory original = _crossChainTerms();
    ProtocolTerms memory changedParty = _crossChainTerms();
    changedParty.partySide.sideNonce = keccak256('changed-party');
    ProtocolTerms memory changedCounterparty = _crossChainTerms();
    changedCounterparty.counterpartySide.sideNonce = keccak256('changed-counterparty');

    assertNotEq(ProtocolHashing.tradeId(original), ProtocolHashing.tradeId(changedParty));
    assertNotEq(ProtocolHashing.tradeId(original), ProtocolHashing.tradeId(changedCounterparty));
    assertNotEq(ProtocolHashing.gateContextId(original), ProtocolHashing.gateContextId(changedParty));
    assertNotEq(ProtocolHashing.gateContextId(original), ProtocolHashing.gateContextId(changedCounterparty));
    // sideNonce is intentionally absent from the verifier-local authorization nonce key.
    assertEq(
      _nonceKey(original.counterpartySide, GATEWAY, NONCE),
      _nonceKey(changedCounterparty.counterpartySide, GATEWAY, NONCE)
    );
  }

  function test_stateFailureRollsBackEffectsAndNonceThenRetrySucceeds() public {
    ProtocolTerms memory terms = _crossChainTerms();
    VerifiedCommitAuthorization memory evidence = _evidence(terms, false, BOB, 7, NONCE, 2000);
    bytes32 nonceKey = _nonceKey(terms.counterpartySide, GATEWAY, NONCE);
    vm.expectRevert(CommitAuthorizationHarness.SimulatedStateFailure.selector);
    vm.prank(GATEWAY);
    harness.commitAuthorized(terms, false, LOCK, evidence, 1);
    assertEq(harness.stateEffects(), 0);
    assertEq(harness.custodyEffects(), 0);
    assertFalse(harness.isConsumed(nonceKey));
    vm.prank(GATEWAY);
    harness.commitAuthorized(terms, false, LOCK, evidence, 0);
    assertTrue(harness.isConsumed(nonceKey));
  }

  function test_custodyFailureRollsBackStateCustodyAndNonce() public {
    ProtocolTerms memory terms = _crossChainTerms();
    VerifiedCommitAuthorization memory evidence = _evidence(terms, false, BOB, 7, NONCE, 2000);
    vm.expectRevert(CommitAuthorizationHarness.SimulatedCustodyFailure.selector);
    vm.prank(GATEWAY);
    harness.commitAuthorized(terms, false, LOCK, evidence, 2);
    assertEq(harness.stateEffects(), 0);
    assertEq(harness.custodyEffects(), 0);
    assertFalse(harness.isConsumed(_nonceKey(terms.counterpartySide, GATEWAY, NONCE)));
  }

  function _evidence(
    ProtocolTerms memory terms,
    bool party,
    address submitter,
    uint256 submitterKeyVersion,
    bytes32 nonce,
    uint256 expiry
  ) internal view returns (VerifiedCommitAuthorization memory evidence) {
    SideTerms memory side = party ? terms.partySide : terms.counterpartySide;
    address verifier = side.authorizationMode == AuthorizationMode.QuipWallet ? side.principal : GATEWAY;
    ExpectedSourceState sourceState = ProtocolHashing.expectedSourceState(party, ProtocolHashing.mode(terms));
    evidence = VerifiedCommitAuthorization({
      payloadHash: ProtocolHashing.commitPayloadHash(
        terms, party, verifier, address(harness), LOCK, sourceState, nonce, expiry
      ),
      wrapperCaller: verifier,
      authenticatedSubmitter: submitter,
      authenticatedSubmitterKeyVersion: submitterKeyVersion,
      expectedSourceState: sourceState,
      actionNonce: nonce,
      expiry: expiry
    });
  }

  function _crossChainTerms() internal pure returns (ProtocolTerms memory terms) {
    terms.partySide = _side(ALICE, 31_337, AuthorizationMode.QuipWallet, 0, 100, 300, 600);
    terms.counterpartySide = _side(BOB, 31_338, AuthorizationMode.RegisteredDirect, 7, 200, 400, 700);
    terms.counterpartySide.commitLock = keccak256('bob-commit-lock');
  }

  function _sameChainTerms() internal pure returns (ProtocolTerms memory terms) {
    terms = _crossChainTerms();
    terms.counterpartySide.chainId = terms.partySide.chainId;
    terms.counterpartySide.commitLock = bytes32(0);
  }

  function _side(
    address principal,
    uint256 chainId,
    AuthorizationMode authorizationMode,
    uint256 keyVersion,
    uint256 commitmentDeadline,
    uint256 claimDeadline,
    uint256 reclaimRelease
  ) internal pure returns (SideTerms memory side) {
    Asset[] memory assets = new Asset[](1);
    assets[0] = Asset({assetType: AssetType.ERC20, target: TOKEN, id: 0, amount: 1 ether});
    side = SideTerms({
      chainId: chainId,
      assets: assets,
      principal: principal,
      authorizationMode: authorizationMode,
      principalKeyVersion: keyVersion,
      reclaimRecipient: principal,
      recipient: principal == ALICE ? BOB : ALICE,
      commitmentDeadline: commitmentDeadline,
      claimDeadline: claimDeadline,
      reclaimRelease: reclaimRelease,
      commitLock: bytes32(0),
      delegationPolicy: DelegationPolicy.NotAllowed,
      delegate: address(0),
      delegateKeyVersion: 0,
      sideNonce: keccak256(abi.encode(principal, chainId))
    });
  }

  function _nonceKey(SideTerms memory side, address verifier, bytes32 nonce) internal pure returns (bytes32) {
    return keccak256(
      ProtocolHashing.encodeAuthorizationNonceKey(
        side.chainId, verifier, side.principal, side.principalKeyVersion, nonce
      )
    );
  }

  function _expectInvalidPayload(
    ProtocolTerms memory terms,
    bytes32 lock,
    VerifiedCommitAuthorization memory evidence
  ) internal {
    vm.expectRevert(CommitAuthorization.InvalidAuthorizationPayload.selector);
    vm.prank(GATEWAY);
    harness.commitAuthorized(terms, false, lock, evidence, 0);
  }

  function _expectSubmitterError(
    ProtocolTerms memory terms,
    VerifiedCommitAuthorization memory evidence,
    bytes4 selector
  ) internal {
    vm.expectRevert(selector);
    vm.prank(GATEWAY);
    harness.commitAuthorized(terms, false, LOCK, evidence, 0);
  }
}
