// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {AssetSupport, AssetTransfers} from '../../src/assets/AssetHandling.sol';
import {AssetSupportRegistry} from '../../src/assets/AssetSupportRegistry.sol';
import {ISwapHTLC} from '../../src/interfaces/ISwapHTLC.sol';
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
import {MaliciousERC20Mock} from '../mocks/MaliciousERC20Mock.sol';
import {Test} from 'forge-std-1.14.0/Test.sol';

contract DeployedWrapperGuardsTest is Test {
  event Committed(bytes32 indexed tradeId, bytes32 indexed lock, SideTag indexed side, address principal);
  event BobCommitSecretPublished(bytes32 indexed tradeId, bytes32 bobCommitSecret);
  event ClaimSelected(bytes32 indexed tradeId, bytes32 indexed lock);
  event ReclaimSelected(bytes32 indexed tradeId, bytes32 indexed lock, uint8 expectedSides);
  event Claimed(bytes32 indexed tradeId, bytes32 indexed lock, SideTag indexed side);
  event Claimed(bytes32 indexed tradeId, bytes32 indexed lock);
  event Reclaimed(bytes32 indexed tradeId, bytes32 indexed lock, SideTag indexed side);
  event Reclaimed(bytes32 indexed tradeId, bytes32 indexed lock);

  address internal constant GATEWAY = address(0xA000);
  address internal constant ALICE = address(0xA11CE);
  address internal constant BOB = address(0xB0B);
  address internal constant ALICE_RECIPIENT = address(0xA1CE);
  address internal constant BOB_RECIPIENT = address(0xB0B0);
  address internal constant EXECUTOR_A = address(0xE0A);
  address internal constant EXECUTOR_B = address(0xE0B);
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
    assertTrue(crossParty != cross.predictHTLC(crossTerms, true, bytes32(uint256(crossLock) + 1)));

    crossTerms.partySide.sideNonce = bytes32(uint256(99));
    _bindCross(crossTerms);
    assertTrue(crossParty != cross.predictHTLC(crossTerms, true, _lock(crossTerms)));
  }

  function test_failedCrossFundingRollsBackCloneStateAndAssetsThenPermitsRetry() public {
    MaliciousERC20Mock malicious = new MaliciousERC20Mock();
    support.setAssetSupport(AssetType.ERC20, address(malicious), true);
    ProtocolTerms memory terms = _crossTerms();
    terms.partySide.assets = _oneAsset(AssetType.ERC20, address(malicious), 0, 10);
    _bindCross(terms);
    bytes32 lock = _lock(terms);
    address predicted = cross.predictHTLC(terms, true, lock);
    malicious.mint(ALICE, 10);
    vm.prank(ALICE);
    malicious.approve(address(cross), 10);
    malicious.setBehavior(MaliciousERC20Mock.Behavior.NoOp);

    vm.expectRevert(AssetTransfers.UnexpectedAmountReceived.selector);
    vm.prank(GATEWAY);
    cross.receiveAuthorizedCommit(
      terms, true, lock, BOB_COMMIT_SECRET, _evidence(terms, true, address(cross), lock, 70, 190), ''
    );

    _assertCrossUnused(terms, true, lock);
    assertEq(cross.htlcOf(terms, true, lock), address(0));
    assertEq(predicted.code.length, 0);
    assertEq(malicious.balanceOf(ALICE), 10);
    assertEq(malicious.balanceOf(predicted), 0);

    malicious.setBehavior(MaliciousERC20Mock.Behavior.Exact);
    vm.prank(GATEWAY);
    cross.receiveAuthorizedCommit(
      terms, true, lock, BOB_COMMIT_SECRET, _evidence(terms, true, address(cross), lock, 70, 190), ''
    );
    assertEq(cross.htlcOf(terms, true, lock), predicted);
    assertEq(malicious.balanceOf(predicted), 10);
    assertEq(uint8(cross.state(terms, true, lock)), uint8(CrossChainLegState.Committed));
  }

  function test_failedSecondSameChainFundingLeavesFirstHTLCIsolatedAndPermitsRetry() public {
    MaliciousERC20Mock malicious = new MaliciousERC20Mock();
    support.setAssetSupport(AssetType.ERC20, address(malicious), true);
    ProtocolTerms memory terms = _sameTerms();
    terms.counterpartySide.assets = _oneAsset(AssetType.ERC20, address(malicious), 0, 20);
    bytes32 lock = _lock(terms);
    _commitSame(terms, true, lock, 80, 1);
    address partyHTLC = same.htlcOf(terms, true, lock);
    address counterpartyHTLC = same.predictHTLC(terms, false, lock);
    malicious.mint(BOB, 20);
    vm.prank(BOB);
    malicious.approve(address(same), 20);
    malicious.setBehavior(MaliciousERC20Mock.Behavior.NoOp);

    vm.expectRevert(AssetTransfers.UnexpectedAmountReceived.selector);
    vm.prank(GATEWAY);
    same.receiveAuthorizedCommit(
      terms, false, lock, bytes32(0), _evidence(terms, false, address(same), lock, 81, 190), ''
    );

    assertEq(uint8(same.state(terms, lock)), uint8(SameChainState.PartyCommitted));
    assertEq(partyHTLC.balance, 1);
    assertTrue(SwapHTLC(payable(partyHTLC)).funded());
    assertEq(same.htlcOf(terms, false, lock), address(0));
    assertEq(counterpartyHTLC.code.length, 0);
    assertEq(malicious.balanceOf(BOB), 20);

    malicious.setBehavior(MaliciousERC20Mock.Behavior.Exact);
    vm.prank(GATEWAY);
    same.receiveAuthorizedCommit(
      terms, false, lock, bytes32(0), _evidence(terms, false, address(same), lock, 81, 190), ''
    );
    assertEq(uint8(same.state(terms, lock)), uint8(SameChainState.BothCommitted));
    assertEq(same.htlcOf(terms, false, lock), counterpartyHTLC);
    assertEq(malicious.balanceOf(counterpartyHTLC), 20);
  }

  function test_failedSecondSameChainPayoutPreservesSelectedFirstSideProgress() public {
    MaliciousERC20Mock malicious = new MaliciousERC20Mock();
    support.setAssetSupport(AssetType.ERC20, address(malicious), true);
    ProtocolTerms memory terms = _sameTerms();
    terms.counterpartySide.assets = _oneAsset(AssetType.ERC20, address(malicious), 0, 20);
    bytes32 lock = _lock(terms);
    malicious.mint(BOB, 20);
    vm.prank(BOB);
    malicious.approve(address(same), 20);
    _commitSame(terms, true, lock, 90, 1);
    _commitSame(terms, false, lock, 91, 0);
    address partyHTLC = same.htlcOf(terms, true, lock);
    address counterpartyHTLC = same.htlcOf(terms, false, lock);
    malicious.setBehavior(MaliciousERC20Mock.Behavior.NoOp);

    same.selectClaim(terms, lock, SECRET);
    same.executeSettlement(terms, lock, true, 1);
    vm.expectRevert(AssetTransfers.UnexpectedAmountReceived.selector);
    same.executeSettlement(terms, lock, false, 1);

    assertEq(uint8(same.state(terms, lock)), uint8(SameChainState.ClaimPending));
    assertTrue(SwapHTLC(payable(partyHTLC)).released());
    assertFalse(SwapHTLC(payable(counterpartyHTLC)).released());
    assertEq(partyHTLC.balance, 0);
    assertEq(malicious.balanceOf(counterpartyHTLC), 20);
    assertEq(BOB_RECIPIENT.balance, 1);
    assertEq(malicious.balanceOf(ALICE_RECIPIENT), 0);

    malicious.setBehavior(MaliciousERC20Mock.Behavior.Exact);
    same.executeSettlement(terms, lock, false, 1);
    assertEq(uint8(same.state(terms, lock)), uint8(SameChainState.Claimed));
    assertTrue(SwapHTLC(payable(partyHTLC)).released());
    assertTrue(SwapHTLC(payable(counterpartyHTLC)).released());
    assertEq(BOB_RECIPIENT.balance, 1);
    assertEq(malicious.balanceOf(ALICE_RECIPIENT), 20);
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
    same.selectClaim(crossTerms, crossLock, SECRET);
    vm.expectRevert(Settlement.InvalidSettlementMode.selector);
    same.selectReclaim(crossTerms, crossLock);
    vm.expectRevert(Settlement.InvalidSettlementMode.selector);
    same.executeSettlement(crossTerms, crossLock, true, 1);

    ProtocolTerms memory nonlocal = _sameTerms();
    nonlocal.partySide.chainId = block.chainid + 1;
    nonlocal.counterpartySide.chainId = block.chainid + 1;
    bytes32 nonlocalLock = _lock(nonlocal);
    vm.expectRevert(Settlement.InvalidLocalChain.selector);
    same.selectClaim(nonlocal, nonlocalLock, SECRET);
    vm.expectRevert(Settlement.InvalidLocalChain.selector);
    same.selectReclaim(nonlocal, nonlocalLock);
    vm.expectRevert(Settlement.InvalidLocalChain.selector);
    same.executeSettlement(nonlocal, nonlocalLock, true, 1);
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

  function test_sameChainClaimSelectionDoesNotCallOrReleaseEitherHTLC() public {
    ProtocolTerms memory terms = _sameTerms();
    bytes32 lock = _lock(terms);
    bytes32 trade = ProtocolHashing.tradeId(terms);
    _commitSame(terms, true, lock, 42, 1);
    _commitSame(terms, false, lock, 43, 2);
    address partyHTLC = same.htlcOf(terms, true, lock);
    address counterpartyHTLC = same.htlcOf(terms, false, lock);
    vm.deal(partyHTLC, 0);
    vm.deal(counterpartyHTLC, 0);

    vm.expectEmit(true, true, false, true, address(same));
    emit ClaimSelected(trade, lock);
    same.selectClaim(terms, lock, SECRET);

    assertEq(uint8(same.state(terms, lock)), uint8(SameChainState.ClaimPending));
    (uint8 expectedSides, uint8 completedSides) = same.settlementProgress(terms, lock);
    assertEq(expectedSides, 3);
    assertEq(completedSides, 0);
    assertFalse(SwapHTLC(payable(partyHTLC)).released());
    assertFalse(SwapHTLC(payable(counterpartyHTLC)).released());
    assertEq(BOB_RECIPIENT.balance, 0);
    assertEq(ALICE_RECIPIENT.balance, 0);
  }

  function test_sameChainUsesOnlySelectedSideExecutionSurface() public {
    ProtocolTerms memory terms = _sameTerms();
    bytes32 lock = _lock(terms);
    _commitSame(terms, true, lock, 92, 1);
    _commitSame(terms, false, lock, 93, 2);

    vm.expectRevert(
      abi.encodeWithSelector(SameChainStateMachine.SettlementNotPending.selector, SameChainState.BothCommitted)
    );
    same.executeSettlement(terms, lock, true, 1);
    vm.expectRevert(SameChainWrapper.AtomicSettlementDisabled.selector);
    same.claim(terms, lock, SECRET);
    vm.expectRevert(SameChainWrapper.AtomicSettlementDisabled.selector);
    same.reclaimParty(terms, lock);
    vm.expectRevert(SameChainWrapper.AtomicSettlementDisabled.selector);
    same.reclaimBoth(terms, lock);

    same.selectClaim(terms, lock, SECRET);
    vm.expectRevert(Settlement.InvalidBatchSize.selector);
    same.executeSettlement(terms, lock, true, 0);
    same.executeSettlement(terms, lock, true, 1);
    (uint8 expectedSides, uint8 completedSides) = same.settlementProgress(terms, lock);
    assertEq(expectedSides, 3);
    assertEq(completedSides, 1);
    assertEq(uint8(same.state(terms, lock)), uint8(SameChainState.ClaimPending));

    vm.expectRevert(abi.encodeWithSelector(SameChainStateMachine.SettlementSideAlreadyComplete.selector, SideTag.Party));
    same.executeSettlement(terms, lock, true, 1);
    same.executeSettlement(terms, lock, false, 1);
    assertEq(uint8(same.state(terms, lock)), uint8(SameChainState.Claimed));
  }

  function test_sameChainSettlementIsPermissionlessAndTermsFixEveryPayout() public {
    ProtocolTerms memory claimTerms = _sameTerms();
    bytes32 claimLock = _lock(claimTerms);
    _commitSame(claimTerms, true, claimLock, 94, 1);
    _commitSame(claimTerms, false, claimLock, 95, 2);

    vm.startPrank(EXECUTOR_A);
    same.selectClaim(claimTerms, claimLock, SECRET);
    same.executeSettlement(claimTerms, claimLock, false, 1);
    same.executeSettlement(claimTerms, claimLock, true, 1);
    vm.stopPrank();

    assertEq(BOB_RECIPIENT.balance, 1);
    assertEq(ALICE_RECIPIENT.balance, 2);
    assertEq(EXECUTOR_A.balance, 0);

    ProtocolTerms memory reclaimTerms = _sameTerms();
    reclaimTerms.partySide.sideNonce = bytes32(uint256(96));
    reclaimTerms.counterpartySide.sideNonce = bytes32(uint256(97));
    reclaimTerms.partySide.delegationPolicy = DelegationPolicy.SpecificDelegate;
    reclaimTerms.partySide.delegate = address(0xD1E6A7E);
    reclaimTerms.partySide.delegateKeyVersion = 1;
    reclaimTerms.counterpartySide.delegationPolicy = DelegationPolicy.Permissionless;
    bytes32 reclaimLock = _lock(reclaimTerms);
    _commitSame(reclaimTerms, true, reclaimLock, 96, 1);
    _commitSame(reclaimTerms, false, reclaimLock, 97, 2);
    vm.warp(reclaimTerms.counterpartySide.reclaimRelease);

    vm.startPrank(EXECUTOR_B);
    same.selectReclaim(reclaimTerms, reclaimLock);
    same.executeSettlement(reclaimTerms, reclaimLock, true, 1);
    same.executeSettlement(reclaimTerms, reclaimLock, false, 1);
    vm.stopPrank();

    assertEq(ALICE.balance, 1);
    assertEq(BOB.balance, 2);
    assertEq(EXECUTOR_B.balance, 0);
  }

  function test_sameChainExecutionRejectsAbsentUnexpectedAndMismatchedHTLCs() public {
    ProtocolTerms memory oneSidedTerms = _sameTerms();
    bytes32 oneSidedLock = _lock(oneSidedTerms);
    _commitSame(oneSidedTerms, true, oneSidedLock, 98, 1);
    vm.warp(oneSidedTerms.partySide.reclaimRelease);
    same.selectReclaim(oneSidedTerms, oneSidedLock);

    vm.expectRevert(
      abi.encodeWithSelector(SameChainStateMachine.UnexpectedSettlementSide.selector, SideTag.Counterparty)
    );
    same.executeSettlement(oneSidedTerms, oneSidedLock, false, 1);
    (uint8 expectedSides, uint8 completedSides) = same.settlementProgress(oneSidedTerms, oneSidedLock);
    assertEq(expectedSides, 1);
    assertEq(completedSides, 0);

    vm.warp(100);
    ProtocolTerms memory absentTerms = _sameTerms();
    absentTerms.partySide.sideNonce = bytes32(uint256(99));
    absentTerms.counterpartySide.sideNonce = bytes32(uint256(100));
    bytes32 absentLock = _lock(absentTerms);
    _commitSame(absentTerms, true, absentLock, 99, 1);
    _commitSame(absentTerms, false, absentLock, 100, 2);
    same.selectClaim(absentTerms, absentLock, SECRET);
    address absentHTLC = same.htlcOf(absentTerms, true, absentLock);
    vm.etch(absentHTLC, hex'');

    vm.expectRevert(Settlement.MissingHTLC.selector);
    same.executeSettlement(absentTerms, absentLock, true, 1);
    (expectedSides, completedSides) = same.settlementProgress(absentTerms, absentLock);
    assertEq(expectedSides, 3);
    assertEq(completedSides, 0);

    ProtocolTerms memory mismatchedTerms = _sameTerms();
    mismatchedTerms.partySide.sideNonce = bytes32(uint256(101));
    mismatchedTerms.counterpartySide.sideNonce = bytes32(uint256(102));
    bytes32 mismatchedLock = _lock(mismatchedTerms);
    _commitSame(mismatchedTerms, true, mismatchedLock, 101, 1);
    _commitSame(mismatchedTerms, false, mismatchedLock, 102, 2);
    same.selectClaim(mismatchedTerms, mismatchedLock, SECRET);
    address mismatchedHTLC = same.htlcOf(mismatchedTerms, true, mismatchedLock);
    vm.mockCall(
      mismatchedHTLC,
      abi.encodeWithSelector(ISwapHTLC.sideTermsHash.selector),
      abi.encode(keccak256('wrong-side-terms'))
    );

    vm.expectRevert(Settlement.InvalidHTLCBinding.selector);
    same.executeSettlement(mismatchedTerms, mismatchedLock, true, 1);
    (expectedSides, completedSides) = same.settlementProgress(mismatchedTerms, mismatchedLock);
    assertEq(expectedSides, 3);
    assertEq(completedSides, 0);
  }

  function test_sameChainExecutionRejectsModifiedTermsWithoutRedirectingPayout() public {
    ProtocolTerms memory terms = _sameTerms();
    terms.partySide.sideNonce = bytes32(uint256(103));
    terms.counterpartySide.sideNonce = bytes32(uint256(104));
    bytes32 lock = _lock(terms);
    _commitSame(terms, true, lock, 103, 1);
    _commitSame(terms, false, lock, 104, 2);
    same.selectClaim(terms, lock, SECRET);

    ProtocolTerms memory modified = abi.decode(abi.encode(terms), (ProtocolTerms));
    modified.partySide.recipient = EXECUTOR_A;
    vm.expectRevert(abi.encodeWithSelector(SameChainStateMachine.SettlementNotPending.selector, SameChainState.Unused));
    same.executeSettlement(modified, lock, true, 1);

    (, uint8 completedSides) = same.settlementProgress(terms, lock);
    assertEq(completedSides, 0);
    assertEq(EXECUTOR_A.balance, 0);
    assertEq(same.htlcOf(terms, true, lock).balance, 1);
  }

  function test_sameChainReclaimSelectionDoesNotCallTheApplicableHTLCs() public {
    ProtocolTerms memory partyTerms = _sameTerms();
    bytes32 partyLock = _lock(partyTerms);
    bytes32 partyTrade = ProtocolHashing.tradeId(partyTerms);
    _commitSame(partyTerms, true, partyLock, 44, 1);
    address partyHTLC = same.htlcOf(partyTerms, true, partyLock);
    vm.deal(partyHTLC, 0);
    vm.warp(partyTerms.partySide.reclaimRelease);

    vm.expectEmit(true, true, false, true, address(same));
    emit ReclaimSelected(partyTrade, partyLock, 1);
    same.selectReclaim(partyTerms, partyLock);
    assertEq(uint8(same.state(partyTerms, partyLock)), uint8(SameChainState.ReclaimPending));
    (uint8 expectedSides, uint8 completedSides) = same.settlementProgress(partyTerms, partyLock);
    assertEq(expectedSides, 1);
    assertEq(completedSides, 0);
    assertFalse(SwapHTLC(payable(partyHTLC)).released());

    vm.warp(100);
    ProtocolTerms memory bothTerms = _sameTerms();
    bothTerms.partySide.sideNonce = bytes32(uint256(45));
    bothTerms.counterpartySide.sideNonce = bytes32(uint256(46));
    bytes32 bothLock = _lock(bothTerms);
    bytes32 bothTrade = ProtocolHashing.tradeId(bothTerms);
    _commitSame(bothTerms, true, bothLock, 45, 1);
    _commitSame(bothTerms, false, bothLock, 46, 2);
    address bothPartyHTLC = same.htlcOf(bothTerms, true, bothLock);
    address bothCounterpartyHTLC = same.htlcOf(bothTerms, false, bothLock);
    vm.deal(bothPartyHTLC, 0);
    vm.deal(bothCounterpartyHTLC, 0);
    vm.warp(bothTerms.counterpartySide.reclaimRelease);

    vm.expectEmit(true, true, false, true, address(same));
    emit ReclaimSelected(bothTrade, bothLock, 3);
    same.selectReclaim(bothTerms, bothLock);
    assertEq(uint8(same.state(bothTerms, bothLock)), uint8(SameChainState.ReclaimPending));
    (expectedSides, completedSides) = same.settlementProgress(bothTerms, bothLock);
    assertEq(expectedSides, 3);
    assertEq(completedSides, 0);
    assertFalse(SwapHTLC(payable(bothPartyHTLC)).released());
    assertFalse(SwapHTLC(payable(bothCounterpartyHTLC)).released());
  }

  function test_sameChainClaimSelectionIsIrreversibleAcrossEveryEntryPoint() public {
    ProtocolTerms memory terms = _sameTerms();
    bytes32 lock = _lock(terms);
    _commitSame(terms, true, lock, 47, 1);
    _commitSame(terms, false, lock, 48, 2);
    address partyHTLC = same.htlcOf(terms, true, lock);
    address counterpartyHTLC = same.htlcOf(terms, false, lock);
    same.selectClaim(terms, lock, SECRET);

    vm.expectRevert(
      abi.encodeWithSelector(
        SameChainStateMachine.InvalidSameChainState.selector, SameChainState.BothCommitted, SameChainState.ClaimPending
      )
    );
    same.selectClaim(terms, lock, SECRET);
    vm.expectRevert(SameChainWrapper.AtomicSettlementDisabled.selector);
    same.claim(terms, lock, SECRET);
    vm.expectRevert(
      abi.encodeWithSelector(
        SameChainStateMachine.InvalidSameChainState.selector, SameChainState.Unused, SameChainState.ClaimPending
      )
    );
    _commitSame(terms, true, lock, 49, 1);
    vm.expectRevert(
      abi.encodeWithSelector(
        SameChainStateMachine.InvalidSameChainState.selector, SameChainState.PartyCommitted, SameChainState.ClaimPending
      )
    );
    _commitSame(terms, false, lock, 50, 2);

    vm.warp(terms.counterpartySide.reclaimRelease);
    vm.expectRevert(
      abi.encodeWithSelector(
        SameChainStateMachine.InvalidSameChainState.selector, SameChainState.BothCommitted, SameChainState.ClaimPending
      )
    );
    same.selectReclaim(terms, lock);
    vm.expectRevert(SameChainWrapper.AtomicSettlementDisabled.selector);
    same.reclaimBoth(terms, lock);

    assertEq(uint8(same.state(terms, lock)), uint8(SameChainState.ClaimPending));
    assertFalse(SwapHTLC(payable(partyHTLC)).released());
    assertFalse(SwapHTLC(payable(counterpartyHTLC)).released());
    assertEq(partyHTLC.balance, 1);
    assertEq(counterpartyHTLC.balance, 2);
  }

  function test_sameChainReclaimSelectionIsIrreversibleAcrossEveryEntryPoint() public {
    ProtocolTerms memory terms = _sameTerms();
    bytes32 lock = _lock(terms);
    _commitSame(terms, true, lock, 51, 1);
    address partyHTLC = same.htlcOf(terms, true, lock);
    vm.warp(terms.partySide.reclaimRelease);
    same.selectReclaim(terms, lock);

    vm.expectRevert(SameChainWrapper.AtomicSettlementDisabled.selector);
    same.reclaimParty(terms, lock);
    vm.expectRevert(Settlement.ClaimWindowClosed.selector);
    same.selectClaim(terms, lock, SECRET);
    vm.expectRevert(SameChainWrapper.CommitWindowClosed.selector);
    vm.prank(GATEWAY);
    same.receiveAuthorizedCommit{value: 1}(
      terms, true, lock, bytes32(0), _evidence(terms, true, address(same), lock, 52, 600), ''
    );

    vm.warp(terms.counterpartySide.reclaimRelease);
    vm.expectRevert(
      abi.encodeWithSelector(
        SameChainStateMachine.InvalidSameChainState.selector,
        SameChainState.BothCommitted,
        SameChainState.ReclaimPending
      )
    );
    same.selectReclaim(terms, lock);
    vm.expectRevert(SameChainWrapper.AtomicSettlementDisabled.selector);
    same.reclaimBoth(terms, lock);

    assertEq(uint8(same.state(terms, lock)), uint8(SameChainState.ReclaimPending));
    assertFalse(SwapHTLC(payable(partyHTLC)).released());
    assertEq(partyHTLC.balance, 1);
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
    emit ClaimSelected(claimTrade, claimLock);
    same.selectClaim(claimTerms, claimLock, SECRET);
    same.executeSettlement(claimTerms, claimLock, true, 1);
    vm.expectEmit(true, true, false, true, address(same));
    emit Claimed(claimTrade, claimLock);
    same.executeSettlement(claimTerms, claimLock, false, 1);
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
    emit ReclaimSelected(reclaimTrade, reclaimLock, 3);
    same.selectReclaim(reclaimTerms, reclaimLock);
    same.executeSettlement(reclaimTerms, reclaimLock, false, 1);
    vm.expectEmit(true, true, false, true, address(same));
    emit Reclaimed(reclaimTrade, reclaimLock);
    same.executeSettlement(reclaimTerms, reclaimLock, true, 1);
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
    same.selectReclaim(terms, lock);
    same.executeSettlement(terms, lock, true, 1);

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
