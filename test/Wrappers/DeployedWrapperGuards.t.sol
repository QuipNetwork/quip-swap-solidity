// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {AssetSupport} from '../../src/assets/AssetHandling.sol';
import {AssetSupportRegistry} from '../../src/assets/AssetSupportRegistry.sol';
import {CommitAuthorization} from '../../src/protocol/CommitValidation.sol';
import {ProgressionGate} from '../../src/protocol/CommitValidation.sol';
import {CrossChainWrapper} from '../../src/protocol/CrossChainWrapper.sol';
import {ProtocolHashing} from '../../src/protocol/ProtocolHashing.sol';
import {
  Asset,
  AssetType,
  AuthorizationMode,
  CrossChainLegState,
  DelegationPolicy,
  ExpectedSourceState,
  ProtocolTerms,
  SameChainState,
  SideTag,
  SideTerms,
  VerifiedCommitAuthorization,
  WrapperMode
} from '../../src/protocol/ProtocolTypes.sol';
import {SameChainWrapper} from '../../src/protocol/SameChainWrapper.sol';
import {Settlement} from '../../src/protocol/Settlement.sol';
import {SameChainStateMachine} from '../../src/protocol/StateMachines.sol';
import {SwapHTLC} from '../../src/protocol/SwapHTLC.sol';
import {ERC20Mock} from '../mocks/ERC20Mock.sol';
import {Test} from 'forge-std-1.14.0/Test.sol';

contract DeployedWrapperGuardsTest is Test {
  event Committed(bytes32 indexed tradeId, bytes32 indexed lock, SideTag indexed side, address principal);
  event BobCommitSecretPublished(bytes32 indexed tradeId, bytes32 bobCommitSecret);
  event Claimed(bytes32 indexed tradeId, bytes32 indexed lock, SideTag indexed side);
  event Claimed(bytes32 indexed tradeId, bytes32 indexed lock);
  event Reclaimed(bytes32 indexed tradeId, bytes32 indexed lock, SideTag indexed side);
  event Reclaimed(bytes32 indexed tradeId, bytes32 indexed lock);

  address internal constant GATEWAY = address(0xA000);
  address internal constant ALICE = address(0xA11CE);
  address internal constant BOB = address(0xB0B);
  address internal constant ALICE_RECIPIENT = address(0xA1CE);
  address internal constant BOB_RECIPIENT = address(0xB0B0);
  bytes32 internal constant SECRET = keccak256('settlement-secret');
  bytes32 internal constant BOB_COMMIT_SECRET = keccak256('bob-commit-secret');

  AssetSupportRegistry internal support;
  CrossChainWrapper internal cross;
  SameChainWrapper internal same;
  SwapHTLC internal htlcImplementation;

  function setUp() public {
    vm.chainId(31_337);
    vm.warp(100);
    support = new AssetSupportRegistry(address(this));
    htlcImplementation = new SwapHTLC();
    cross = new CrossChainWrapper(GATEWAY, support, address(htlcImplementation));
    same = new SameChainWrapper(GATEWAY, support, address(htlcImplementation));
    vm.deal(GATEWAY, 100 ether);
  }

  function test_constructorsRejectEveryZeroDependency() public {
    vm.expectRevert(CrossChainWrapper.ZeroConfiguration.selector);
    new CrossChainWrapper(address(0), support, address(htlcImplementation));
    vm.expectRevert(CrossChainWrapper.ZeroConfiguration.selector);
    new CrossChainWrapper(GATEWAY, AssetSupportRegistry(address(0)), address(htlcImplementation));
    vm.expectRevert(CrossChainWrapper.ZeroConfiguration.selector);
    new CrossChainWrapper(GATEWAY, support, address(0));
    vm.expectRevert(SameChainWrapper.ZeroConfiguration.selector);
    new SameChainWrapper(address(0), support, address(htlcImplementation));
    vm.expectRevert(SameChainWrapper.ZeroConfiguration.selector);
    new SameChainWrapper(GATEWAY, AssetSupportRegistry(address(0)), address(htlcImplementation));
    vm.expectRevert(SameChainWrapper.ZeroConfiguration.selector);
    new SameChainWrapper(GATEWAY, support, address(0));
  }

  function test_wrappersPinAndPredictIsolatedHTLCAddresses() public view {
    ProtocolTerms memory crossTerms = _crossTerms();
    ProtocolTerms memory sameTerms = _sameTerms();
    bytes32 crossLock = _lock(crossTerms);
    bytes32 sameLock = _lock(sameTerms);

    assertEq(cross.HTLC_IMPLEMENTATION(), address(htlcImplementation));
    assertEq(same.HTLC_IMPLEMENTATION(), address(htlcImplementation));
    assertEq(cross.htlcOf(crossTerms, true, crossLock), address(0));
    assertEq(same.htlcOf(sameTerms, true, sameLock), address(0));

    address crossParty = cross.predictHTLC(crossTerms, true, crossLock);
    address crossCounterparty = cross.predictHTLC(crossTerms, false, crossLock);
    address sameParty = same.predictHTLC(sameTerms, true, sameLock);
    address sameCounterparty = same.predictHTLC(sameTerms, false, sameLock);

    assertTrue(crossParty != crossCounterparty);
    assertTrue(sameParty != sameCounterparty);
    assertTrue(crossParty != sameParty);
    assertEq(crossParty, cross.predictHTLC(crossTerms, true, crossLock));
    assertEq(sameCounterparty, same.predictHTLC(sameTerms, false, sameLock));
  }

  function test_bothWrappersRejectWrongModeAtomically() public {
    ProtocolTerms memory crossTerms = _crossTerms();
    ProtocolTerms memory sameTerms = _sameTerms();
    bytes32 crossLock = _lock(crossTerms);
    bytes32 sameLock = _lock(sameTerms);

    vm.expectRevert(CrossChainWrapper.InvalidWrapperMode.selector);
    vm.prank(GATEWAY);
    cross.receiveAuthorizedCommit(
      sameTerms, true, sameLock, bytes32(0), _evidence(sameTerms, true, address(cross), sameLock, 1, 190), ''
    );
    _assertCrossUnused(sameTerms, true, sameLock);

    vm.expectRevert(SameChainWrapper.InvalidWrapperMode.selector);
    vm.prank(GATEWAY);
    same.receiveAuthorizedCommit(
      crossTerms, true, crossLock, BOB_COMMIT_SECRET, _evidence(crossTerms, true, address(same), crossLock, 2, 190), ''
    );
    assertEq(uint8(same.state(crossTerms, crossLock)), uint8(SameChainState.Unused));
  }

  function test_bothWrappersRejectNonlocalSideAtomically() public {
    ProtocolTerms memory nonlocalCross = _crossTerms();
    nonlocalCross.partySide.chainId = block.chainid + 2;
    _bindCross(nonlocalCross);
    bytes32 nonlocalCrossLock = _lock(nonlocalCross);
    vm.expectRevert(CrossChainWrapper.InvalidLocalChain.selector);
    vm.prank(GATEWAY);
    cross.receiveAuthorizedCommit(
      nonlocalCross,
      true,
      nonlocalCrossLock,
      BOB_COMMIT_SECRET,
      _evidence(nonlocalCross, true, address(cross), nonlocalCrossLock, 3, 190),
      ''
    );
    _assertCrossUnused(nonlocalCross, true, nonlocalCrossLock);

    ProtocolTerms memory nonlocalSame = _sameTerms();
    nonlocalSame.partySide.chainId = block.chainid + 1;
    nonlocalSame.counterpartySide.chainId = block.chainid + 1;
    bytes32 nonlocalSameLock = _lock(nonlocalSame);
    vm.expectRevert(SameChainWrapper.InvalidLocalChain.selector);
    vm.prank(GATEWAY);
    same.receiveAuthorizedCommit(
      nonlocalSame,
      true,
      nonlocalSameLock,
      bytes32(0),
      _evidence(nonlocalSame, true, address(same), nonlocalSameLock, 4, 190),
      ''
    );
    assertEq(uint8(same.state(nonlocalSame, nonlocalSameLock)), uint8(SameChainState.Unused));
  }

  function test_bothWrappersRejectClosedCommitWindowAtomically() public {
    ProtocolTerms memory crossTerms = _crossTerms();
    ProtocolTerms memory sameTerms = _sameTerms();
    bytes32 crossLock = _lock(crossTerms);
    bytes32 sameLock = _lock(sameTerms);
    VerifiedCommitAuthorization memory crossEvidence = _evidence(crossTerms, true, address(cross), crossLock, 5, 1000);
    vm.warp(crossTerms.partySide.commitmentDeadline);
    vm.expectRevert(CrossChainWrapper.CommitWindowClosed.selector);
    vm.prank(GATEWAY);
    cross.receiveAuthorizedCommit{value: 1}(crossTerms, true, crossLock, BOB_COMMIT_SECRET, crossEvidence, '');
    _assertCrossUnused(crossTerms, true, crossLock);

    vm.warp(sameTerms.partySide.commitmentDeadline);
    vm.expectRevert(SameChainWrapper.CommitWindowClosed.selector);
    vm.prank(GATEWAY);
    same.receiveAuthorizedCommit{value: 1}(
      sameTerms, true, sameLock, bytes32(0), _evidence(sameTerms, true, address(same), sameLock, 6, 1000), ''
    );
    assertEq(uint8(same.state(sameTerms, sameLock)), uint8(SameChainState.Unused));
  }

  function test_crossSettlementEntryPointsRejectWrongModeAndNonlocalSide() public {
    ProtocolTerms memory sameTerms = _sameTerms();
    bytes32 sameLock = _lock(sameTerms);
    vm.expectRevert(Settlement.InvalidSettlementMode.selector);
    cross.claim(sameTerms, true, sameLock, SECRET);
    vm.expectRevert(Settlement.InvalidSettlementMode.selector);
    cross.reclaim(sameTerms, true, sameLock);

    ProtocolTerms memory nonlocal = _crossTerms();
    nonlocal.partySide.chainId = block.chainid + 2;
    _bindCross(nonlocal);
    bytes32 nonlocalLock = _lock(nonlocal);
    vm.expectRevert(Settlement.InvalidLocalChain.selector);
    cross.claim(nonlocal, true, nonlocalLock, SECRET);
    vm.expectRevert(Settlement.InvalidLocalChain.selector);
    cross.reclaim(nonlocal, true, nonlocalLock);
  }

  function test_sameSettlementEntryPointsRejectWrongModeAndNonlocalTerms() public {
    ProtocolTerms memory crossTerms = _crossTerms();
    bytes32 crossLock = _lock(crossTerms);
    vm.expectRevert(Settlement.InvalidSettlementMode.selector);
    same.claim(crossTerms, crossLock, SECRET);
    vm.expectRevert(Settlement.InvalidSettlementMode.selector);
    same.reclaimParty(crossTerms, crossLock);
    vm.expectRevert(Settlement.InvalidSettlementMode.selector);
    same.reclaimBoth(crossTerms, crossLock);

    ProtocolTerms memory nonlocal = _sameTerms();
    nonlocal.partySide.chainId = block.chainid + 1;
    nonlocal.counterpartySide.chainId = block.chainid + 1;
    bytes32 nonlocalLock = _lock(nonlocal);
    vm.expectRevert(Settlement.InvalidLocalChain.selector);
    same.claim(nonlocal, nonlocalLock, SECRET);
    vm.expectRevert(Settlement.InvalidLocalChain.selector);
    same.reclaimParty(nonlocal, nonlocalLock);
    vm.expectRevert(Settlement.InvalidLocalChain.selector);
    same.reclaimBoth(nonlocal, nonlocalLock);
  }

  function test_crossWrapperRejectsMalformedEvidenceProgressionAndUnsupportedAssetsAtomically() public {
    ProtocolTerms memory terms = _crossTerms();
    bytes32 lock = _lock(terms);
    VerifiedCommitAuthorization memory evidence = _evidence(terms, true, address(cross), lock, 10, 190);

    VerifiedCommitAuthorization memory malformed = evidence;
    malformed.wrapperCaller = address(0xBAD);
    vm.expectRevert(CommitAuthorization.InvalidAuthorizationCaller.selector);
    vm.prank(GATEWAY);
    cross.receiveAuthorizedCommit{value: 1}(terms, true, lock, BOB_COMMIT_SECRET, malformed, '');

    malformed = _evidence(terms, true, address(cross), lock, 10, 190);
    malformed.payloadHash = keccak256('bad-payload');
    vm.expectRevert(CommitAuthorization.InvalidAuthorizationPayload.selector);
    vm.prank(GATEWAY);
    cross.receiveAuthorizedCommit{value: 1}(terms, true, lock, BOB_COMMIT_SECRET, malformed, '');

    malformed = _evidence(terms, true, address(cross), lock, 10, 190);
    malformed.expectedSourceState = ExpectedSourceState.PartyCommitted;
    vm.expectRevert(CommitAuthorization.InvalidExpectedSourceState.selector);
    vm.prank(GATEWAY);
    cross.receiveAuthorizedCommit{value: 1}(terms, true, lock, BOB_COMMIT_SECRET, malformed, '');

    evidence = _evidence(terms, true, address(cross), lock, 10, 190);
    vm.expectRevert(ProgressionGate.MissingBobCommitSecret.selector);
    vm.prank(GATEWAY);
    cross.receiveAuthorizedCommit{value: 1}(terms, true, lock, bytes32(0), evidence, '');
    vm.expectRevert(ProgressionGate.InvalidBobCommitSecret.selector);
    vm.prank(GATEWAY);
    cross.receiveAuthorizedCommit{value: 1}(terms, true, lock, keccak256('wrong'), evidence, '');
    _assertCrossUnused(terms, true, lock);
    assertEq(address(cross).balance, 0);

    ERC20Mock unsupported = new ERC20Mock('Unsupported', 'NO', 18);
    ProtocolTerms memory unsupportedTerms = _crossTerms();
    unsupportedTerms.partySide.assets = _oneAsset(AssetType.ERC20, address(unsupported), 0, 1);
    _bindCross(unsupportedTerms);
    bytes32 unsupportedLock = _lock(unsupportedTerms);
    vm.expectRevert(
      abi.encodeWithSelector(AssetSupport.UnsupportedAsset.selector, AssetType.ERC20, address(unsupported))
    );
    vm.prank(GATEWAY);
    cross.receiveAuthorizedCommit(
      unsupportedTerms,
      true,
      unsupportedLock,
      BOB_COMMIT_SECRET,
      _evidence(unsupportedTerms, true, address(cross), unsupportedLock, 11, 190),
      ''
    );
    _assertCrossUnused(unsupportedTerms, true, unsupportedLock);
  }

  function test_sameWrapperRejectsMalformedEvidenceProgressionUnsupportedAssetsAndSourceStateAtomically() public {
    ProtocolTerms memory terms = _sameTerms();
    bytes32 lock = _lock(terms);
    VerifiedCommitAuthorization memory evidence = _evidence(terms, true, address(same), lock, 20, 190);

    VerifiedCommitAuthorization memory malformed = evidence;
    malformed.authenticatedSubmitter = BOB;
    vm.expectRevert(CommitAuthorization.InvalidAuthenticatedSubmitter.selector);
    vm.prank(GATEWAY);
    same.receiveAuthorizedCommit{value: 1}(terms, true, lock, bytes32(0), malformed, '');

    malformed = _evidence(terms, true, address(same), lock, 20, 190);
    malformed.payloadHash = keccak256('bad-payload');
    vm.expectRevert(CommitAuthorization.InvalidAuthorizationPayload.selector);
    vm.prank(GATEWAY);
    same.receiveAuthorizedCommit{value: 1}(terms, true, lock, bytes32(0), malformed, '');

    malformed = _evidence(terms, true, address(same), lock, 20, 190);
    malformed.expectedSourceState = ExpectedSourceState.PartyCommitted;
    vm.expectRevert(CommitAuthorization.InvalidExpectedSourceState.selector);
    vm.prank(GATEWAY);
    same.receiveAuthorizedCommit{value: 1}(terms, true, lock, bytes32(0), malformed, '');

    evidence = _evidence(terms, true, address(same), lock, 20, 190);
    vm.expectRevert(ProgressionGate.UnexpectedBobCommitSecret.selector);
    vm.prank(GATEWAY);
    same.receiveAuthorizedCommit{value: 1}(terms, true, lock, BOB_COMMIT_SECRET, evidence, '');

    VerifiedCommitAuthorization memory counterEvidence = _evidence(terms, false, address(same), lock, 21, 190);
    vm.expectRevert(
      abi.encodeWithSelector(
        SameChainStateMachine.InvalidSameChainState.selector, SameChainState.PartyCommitted, SameChainState.Unused
      )
    );
    vm.prank(GATEWAY);
    same.receiveAuthorizedCommit{value: 2}(terms, false, lock, bytes32(0), counterEvidence, '');
    assertEq(uint8(same.state(terms, lock)), uint8(SameChainState.Unused));
    assertEq(address(same).balance, 0);

    ERC20Mock unsupported = new ERC20Mock('Unsupported', 'NO', 18);
    ProtocolTerms memory unsupportedTerms = _sameTerms();
    unsupportedTerms.partySide.assets = _oneAsset(AssetType.ERC20, address(unsupported), 0, 1);
    bytes32 unsupportedLock = _lock(unsupportedTerms);
    vm.expectRevert(
      abi.encodeWithSelector(AssetSupport.UnsupportedAsset.selector, AssetType.ERC20, address(unsupported))
    );
    vm.prank(GATEWAY);
    same.receiveAuthorizedCommit(
      unsupportedTerms,
      true,
      unsupportedLock,
      bytes32(0),
      _evidence(unsupportedTerms, true, address(same), unsupportedLock, 22, 190),
      ''
    );
    assertEq(uint8(same.state(unsupportedTerms, unsupportedLock)), uint8(SameChainState.Unused));
  }

  function test_crossWrapperEmitsExactCommitSecretClaimAndReclaimEvents() public {
    ProtocolTerms memory claimTerms = _crossTerms();
    bytes32 claimLock = _lock(claimTerms);
    bytes32 claimTrade = ProtocolHashing.tradeId(claimTerms);
    vm.expectEmit(true, true, true, true, address(cross));
    emit Committed(claimTrade, claimLock, SideTag.Party, ALICE);
    vm.expectEmit(true, false, false, true, address(cross));
    emit BobCommitSecretPublished(claimTrade, BOB_COMMIT_SECRET);
    _commitCross(claimTerms, true, claimLock, 30, 1);
    address claimHTLC = cross.htlcOf(claimTerms, true, claimLock);
    assertEq(claimHTLC, cross.predictHTLC(claimTerms, true, claimLock));
    assertGt(claimHTLC.code.length, 0);
    assertEq(claimHTLC.balance, 1);
    assertEq(SwapHTLC(payable(claimHTLC)).controller(), address(cross));
    assertTrue(SwapHTLC(payable(claimHTLC)).funded());
    assertFalse(SwapHTLC(payable(claimHTLC)).released());
    assertEq(address(cross).balance, 0);

    vm.expectEmit(true, true, true, true, address(cross));
    emit Claimed(claimTrade, claimLock, SideTag.Party);
    cross.claim(claimTerms, true, claimLock, SECRET);
    assertEq(uint8(cross.state(claimTerms, true, claimLock)), uint8(CrossChainLegState.Claimed));
    assertTrue(SwapHTLC(payable(claimHTLC)).released());
    assertEq(claimHTLC.balance, 0);

    ProtocolTerms memory reclaimTerms = _crossTerms();
    reclaimTerms.partySide.sideNonce = bytes32(uint256(31));
    _bindCross(reclaimTerms);
    bytes32 reclaimLock = _lock(reclaimTerms);
    bytes32 reclaimTrade = ProtocolHashing.tradeId(reclaimTerms);
    _commitCross(reclaimTerms, true, reclaimLock, 31, 1);
    vm.warp(reclaimTerms.partySide.reclaimRelease);
    vm.expectEmit(true, true, true, true, address(cross));
    emit Reclaimed(reclaimTrade, reclaimLock, SideTag.Party);
    cross.reclaim(reclaimTerms, true, reclaimLock);
    assertEq(uint8(cross.state(reclaimTerms, true, reclaimLock)), uint8(CrossChainLegState.Reclaimed));
  }

  function test_sameChainCommitsFundTwoIsolatedHTLCs() public {
    ProtocolTerms memory terms = _sameTerms();
    bytes32 lock = _lock(terms);

    _commitSame(terms, true, lock, 40, 1);
    address partyHTLC = same.htlcOf(terms, true, lock);
    assertEq(partyHTLC, same.predictHTLC(terms, true, lock));
    assertGt(partyHTLC.code.length, 0);
    assertEq(partyHTLC.balance, 1);
    assertTrue(SwapHTLC(payable(partyHTLC)).funded());
    assertFalse(SwapHTLC(payable(partyHTLC)).released());
    assertEq(uint8(same.state(terms, lock)), uint8(SameChainState.PartyCommitted));

    _commitSame(terms, false, lock, 41, 2);
    address counterpartyHTLC = same.htlcOf(terms, false, lock);
    assertEq(counterpartyHTLC, same.predictHTLC(terms, false, lock));
    assertTrue(counterpartyHTLC != partyHTLC);
    assertGt(counterpartyHTLC.code.length, 0);
    assertEq(counterpartyHTLC.balance, 2);
    assertTrue(SwapHTLC(payable(counterpartyHTLC)).funded());
    assertFalse(SwapHTLC(payable(counterpartyHTLC)).released());
    assertEq(address(same).balance, 0);
    assertEq(uint8(same.state(terms, lock)), uint8(SameChainState.BothCommitted));
  }

  function test_sameWrapperEmitsExactCommitClaimAndReclaimEvents() public {
    ProtocolTerms memory claimTerms = _sameTerms();
    bytes32 claimLock = _lock(claimTerms);
    bytes32 claimTrade = ProtocolHashing.tradeId(claimTerms);

    _expectSameCommitEvents(claimTerms, true, claimLock);
    _commitSame(claimTerms, true, claimLock, 40, 1);
    _expectSameCommitEvents(claimTerms, false, claimLock);
    _commitSame(claimTerms, false, claimLock, 41, 2);
    address claimPartyHTLC = same.htlcOf(claimTerms, true, claimLock);
    address claimCounterpartyHTLC = same.htlcOf(claimTerms, false, claimLock);

    vm.expectEmit(true, true, false, true, address(same));
    emit Claimed(claimTrade, claimLock);
    same.claim(claimTerms, claimLock, SECRET);
    assertEq(uint8(same.state(claimTerms, claimLock)), uint8(SameChainState.Claimed));
    assertTrue(SwapHTLC(payable(claimPartyHTLC)).released());
    assertTrue(SwapHTLC(payable(claimCounterpartyHTLC)).released());
    assertEq(claimPartyHTLC.balance, 0);
    assertEq(claimCounterpartyHTLC.balance, 0);

    ProtocolTerms memory reclaimTerms = _sameTerms();
    reclaimTerms.partySide.sideNonce = bytes32(uint256(50));
    reclaimTerms.counterpartySide.sideNonce = bytes32(uint256(51));
    bytes32 reclaimLock = _lock(reclaimTerms);
    bytes32 reclaimTrade = ProtocolHashing.tradeId(reclaimTerms);
    _commitSame(reclaimTerms, true, reclaimLock, 50, 1);
    _commitSame(reclaimTerms, false, reclaimLock, 51, 2);
    address reclaimPartyHTLC = same.htlcOf(reclaimTerms, true, reclaimLock);
    address reclaimCounterpartyHTLC = same.htlcOf(reclaimTerms, false, reclaimLock);
    vm.warp(reclaimTerms.counterpartySide.reclaimRelease);
    vm.expectEmit(true, true, false, true, address(same));
    emit Reclaimed(reclaimTrade, reclaimLock);
    same.reclaimBoth(reclaimTerms, reclaimLock);
    assertEq(uint8(same.state(reclaimTerms, reclaimLock)), uint8(SameChainState.Reclaimed));
    assertTrue(SwapHTLC(payable(reclaimPartyHTLC)).released());
    assertTrue(SwapHTLC(payable(reclaimCounterpartyHTLC)).released());
    assertEq(reclaimPartyHTLC.balance, 0);
    assertEq(reclaimCounterpartyHTLC.balance, 0);
  }

  function test_sameChainPartyOnlyReclaimReleasesItsHTLC() public {
    ProtocolTerms memory terms = _sameTerms();
    bytes32 lock = _lock(terms);
    _commitSame(terms, true, lock, 60, 1);
    address partyHTLC = same.htlcOf(terms, true, lock);

    vm.warp(terms.partySide.reclaimRelease);
    same.reclaimParty(terms, lock);

    assertEq(uint8(same.state(terms, lock)), uint8(SameChainState.Reclaimed));
    assertTrue(SwapHTLC(payable(partyHTLC)).released());
    assertEq(partyHTLC.balance, 0);
    assertEq(ALICE.balance, 1);
  }

  function _expectSameCommitEvents(ProtocolTerms memory terms, bool party, bytes32 lock) internal {
    SideTerms memory side = party ? terms.partySide : terms.counterpartySide;
    vm.expectEmit(true, true, true, true, address(same));
    emit Committed(ProtocolHashing.tradeId(terms), lock, party ? SideTag.Party : SideTag.Counterparty, side.principal);
  }

  function _commitCross(ProtocolTerms memory terms, bool party, bytes32 lock, uint256 nonce, uint256 value) internal {
    vm.prank(GATEWAY);
    cross.receiveAuthorizedCommit{value: value}(
      terms, party, lock, BOB_COMMIT_SECRET, _evidence(terms, party, address(cross), lock, nonce, 190), ''
    );
  }

  function _commitSame(ProtocolTerms memory terms, bool party, bytes32 lock, uint256 nonce, uint256 value) internal {
    vm.prank(GATEWAY);
    same.receiveAuthorizedCommit{value: value}(
      terms, party, lock, bytes32(0), _evidence(terms, party, address(same), lock, nonce, 190), ''
    );
  }

  function _evidence(
    ProtocolTerms memory terms,
    bool party,
    address wrapper,
    bytes32 lock,
    uint256 nonce,
    uint256 expiry
  ) internal pure returns (VerifiedCommitAuthorization memory evidence) {
    SideTerms memory side = party ? terms.partySide : terms.counterpartySide;
    ExpectedSourceState source = ProtocolHashing.expectedSourceState(party, ProtocolHashing.mode(terms));
    evidence.payloadHash =
      ProtocolHashing.commitPayloadHash(terms, party, GATEWAY, wrapper, lock, source, bytes32(nonce), expiry);
    evidence.wrapperCaller = GATEWAY;
    evidence.authenticatedSubmitter = side.principal;
    evidence.authenticatedSubmitterKeyVersion = side.principalKeyVersion;
    evidence.expectedSourceState = source;
    evidence.actionNonce = bytes32(nonce);
    evidence.expiry = expiry;
  }

  function _crossTerms() internal view returns (ProtocolTerms memory terms) {
    terms.partySide = _side(block.chainid, ALICE, BOB_RECIPIENT, 1, 200, 300, 500, 1);
    terms.counterpartySide = _side(block.chainid + 1, BOB, ALICE_RECIPIENT, 2, 220, 320, 520, 2);
    _bindCross(terms);
  }

  function _sameTerms() internal view returns (ProtocolTerms memory terms) {
    terms.partySide = _side(block.chainid, ALICE, BOB_RECIPIENT, 1, 200, 300, 500, 3);
    terms.counterpartySide = _side(block.chainid, BOB, ALICE_RECIPIENT, 2, 220, 320, 520, 4);
  }

  function _side(
    uint256 chainId,
    address principal,
    address recipient,
    uint256 amount,
    uint256 commitmentDeadline,
    uint256 claimDeadline,
    uint256 reclaimRelease,
    uint256 nonce
  ) internal pure returns (SideTerms memory side) {
    side = SideTerms({
      chainId: chainId,
      assets: _oneAsset(AssetType.Native, address(0), 0, amount),
      principal: principal,
      authorizationMode: AuthorizationMode.RegisteredDirect,
      principalKeyVersion: 1,
      reclaimRecipient: principal,
      recipient: recipient,
      commitmentDeadline: commitmentDeadline,
      claimDeadline: claimDeadline,
      reclaimRelease: reclaimRelease,
      commitLock: bytes32(0),
      delegationPolicy: DelegationPolicy.NotAllowed,
      delegate: address(0),
      delegateKeyVersion: 0,
      sideNonce: bytes32(nonce)
    });
  }

  function _oneAsset(
    AssetType assetType,
    address target,
    uint256 id,
    uint256 amount
  ) internal pure returns (Asset[] memory assets) {
    assets = new Asset[](1);
    assets[0] = Asset({assetType: assetType, target: target, id: id, amount: amount});
  }

  function _bindCross(ProtocolTerms memory terms) internal pure {
    terms.counterpartySide.commitLock = bytes32(0);
    terms.counterpartySide.commitLock =
      ProtocolHashing.commitLock(ProtocolHashing.gateContextId(terms), BOB_COMMIT_SECRET);
  }

  function _lock(ProtocolTerms memory terms) internal pure returns (bytes32) {
    return ProtocolHashing.settlementLock(ProtocolHashing.tradeId(terms), SECRET);
  }

  function _assertCrossUnused(ProtocolTerms memory terms, bool party, bytes32 lock) internal view {
    assertEq(uint8(cross.state(terms, party, lock)), uint8(CrossChainLegState.Unused));
  }
}
