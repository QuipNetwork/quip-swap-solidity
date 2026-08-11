// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Test} from 'forge-std-1.14.0/Test.sol';

import {CrossChainStateMachine} from '../../src/CrossChainStateMachine.sol';
import {ProtocolHashing} from '../../src/ProtocolHashing.sol';
import {
  AuthorizationMode,
  CrossChainLegState,
  DelegationPolicy,
  ProtocolTerms,
  SameChainState,
  SideTerms,
  TimingPolicy,
  WrapperMode
} from '../../src/ProtocolTypes.sol';
import {SameChainStateMachine} from '../../src/SameChainStateMachine.sol';
import {Settlement} from '../../src/Settlement.sol';
import {Asset, AssetType} from '../../src/TermsLib.sol';
import {SettlementHarness} from '../harness/SettlementHarness.sol';
import {ERC20Mock} from '../mocks/ERC20Mock.sol';

contract SettlementTest is Test {
  bytes32 internal constant SECRET = keccak256('settlement-secret');
  address internal constant PARTY_RECIPIENT = address(0xA11CE);
  address internal constant COUNTERPARTY_RECIPIENT = address(0xB0B);
  address internal constant PARTY_RECLAIMER = address(0xA11CE01);
  address internal constant COUNTERPARTY_RECLAIMER = address(0xB0B01);
  address internal constant EXECUTOR = address(0xE0);

  SettlementHarness internal harness;
  ERC20Mock internal partyToken;
  ERC20Mock internal counterpartyToken;

  function setUp() public {
    vm.warp(100);
    harness = new SettlementHarness();
    partyToken = new ERC20Mock('Party', 'PTY', 18);
    counterpartyToken = new ERC20Mock('Counterparty', 'CPY', 18);
  }

  function test_crossChainClaimIsPermissionlessImmediateAndPayoutFixed() public {
    (ProtocolTerms memory terms, TimingPolicy memory policy, bytes32 lock) = _crossTerms(true);
    _fundAndSeedCross(terms, true, lock);

    vm.prank(EXECUTOR);
    harness.claimCrossChain(terms, policy, true, lock, SECRET);

    assertEq(partyToken.balanceOf(PARTY_RECIPIENT), 10 ether);
    assertEq(partyToken.balanceOf(EXECUTOR), 0);
    assertEq(uint8(harness.crossState(terms, true, lock)), uint8(CrossChainLegState.Claimed));
  }

  function test_leakedSettlementSecretClaimsPartyLegBeforeCounterpartyCommit() public {
    (ProtocolTerms memory terms, TimingPolicy memory policy, bytes32 lock) = _crossTerms(true);
    _fundAndSeedCross(terms, true, lock);
    assertEq(uint8(harness.crossState(terms, false, lock)), uint8(CrossChainLegState.Unused));

    vm.prank(EXECUTOR);
    harness.claimCrossChain(terms, policy, true, lock, SECRET);

    assertEq(partyToken.balanceOf(PARTY_RECIPIENT), 10 ether);
    assertEq(uint8(harness.crossState(terms, true, lock)), uint8(CrossChainLegState.Claimed));
    assertEq(uint8(harness.crossState(terms, false, lock)), uint8(CrossChainLegState.Unused));
  }

  function test_crossChainClaimRejectsWrongSecretAndExclusiveDeadlineWithoutEffects() public {
    (ProtocolTerms memory terms, TimingPolicy memory policy, bytes32 lock) = _crossTerms(true);
    _fundAndSeedCross(terms, true, lock);

    vm.expectRevert(Settlement.InvalidSettlementSecret.selector);
    harness.claimCrossChain(terms, policy, true, lock, keccak256('wrong'));
    vm.warp(terms.partySide.claimDeadline);
    vm.expectRevert(Settlement.ClaimWindowClosed.selector);
    harness.claimCrossChain(terms, policy, true, lock, SECRET);

    assertEq(partyToken.balanceOf(address(harness)), 10 ether);
    assertEq(uint8(harness.crossState(terms, true, lock)), uint8(CrossChainLegState.Committed));
  }

  function test_crossChainCounterpartyClaimUsesItsLocalDeadlineAndRecipient() public {
    (ProtocolTerms memory terms, TimingPolicy memory policy, bytes32 lock) = _crossTerms(false);
    _fundAndSeedCross(terms, false, lock);

    vm.prank(EXECUTOR);
    harness.claimCrossChain(terms, policy, false, lock, SECRET);

    assertEq(counterpartyToken.balanceOf(COUNTERPARTY_RECIPIENT), 20 ether);
    assertEq(uint8(harness.crossState(terms, false, lock)), uint8(CrossChainLegState.Claimed));
  }

  function test_crossChainReclaimIsPermissionlessAtReleaseAndPayoutFixed() public {
    (ProtocolTerms memory terms, TimingPolicy memory policy, bytes32 lock) = _crossTerms(true);
    _fundAndSeedCross(terms, true, lock);
    vm.warp(terms.partySide.reclaimRelease);

    vm.prank(EXECUTOR);
    harness.reclaimCrossChain(terms, policy, true, lock);

    assertEq(partyToken.balanceOf(PARTY_RECLAIMER), 10 ether);
    assertEq(partyToken.balanceOf(EXECUTOR), 0);
    assertEq(uint8(harness.crossState(terms, true, lock)), uint8(CrossChainLegState.Reclaimed));
  }

  function test_crossChainReclaimRejectsBeforeReleaseAndClaimReclaimRaceIsTerminal() public {
    (ProtocolTerms memory terms, TimingPolicy memory policy, bytes32 lock) = _crossTerms(true);
    _fundAndSeedCross(terms, true, lock);
    vm.warp(terms.partySide.reclaimRelease - 1);
    vm.expectRevert(Settlement.ReclaimWindowClosed.selector);
    harness.reclaimCrossChain(terms, policy, true, lock);

    vm.warp(terms.partySide.reclaimRelease);
    harness.reclaimCrossChain(terms, policy, true, lock);
    vm.expectRevert(Settlement.ClaimWindowClosed.selector);
    harness.claimCrossChain(terms, policy, true, lock, SECRET);
    assertEq(uint8(harness.crossState(terms, true, lock)), uint8(CrossChainLegState.Reclaimed));
  }

  function test_crossChainClaimThenReclaimRacePreservesClaimedTerminalState() public {
    (ProtocolTerms memory terms, TimingPolicy memory policy, bytes32 lock) = _crossTerms(true);
    _fundAndSeedCross(terms, true, lock);
    harness.claimCrossChain(terms, policy, true, lock, SECRET);
    vm.warp(terms.partySide.reclaimRelease);

    vm.expectRevert(
      abi.encodeWithSelector(
        CrossChainStateMachine.InvalidCrossChainState.selector, CrossChainLegState.Committed, CrossChainLegState.Claimed
      )
    );
    harness.reclaimCrossChain(terms, policy, true, lock);
    assertEq(uint8(harness.crossState(terms, true, lock)), uint8(CrossChainLegState.Claimed));
  }

  function test_crossChainAsymmetricClaimedReclaimedOutcomeRemainsLocallyPossible() public {
    uint256 partyChain = block.chainid;
    (ProtocolTerms memory terms, TimingPolicy memory policy, bytes32 lock) = _crossTerms(true);
    _fundSide(terms.partySide, partyToken, 10 ether);
    _fundSide(terms.counterpartySide, counterpartyToken, 20 ether);
    harness.seedCrossChain(terms, true, lock);
    harness.seedCrossChain(terms, false, lock);

    harness.claimCrossChain(terms, policy, true, lock, SECRET);
    vm.chainId(terms.counterpartySide.chainId);
    vm.warp(terms.counterpartySide.reclaimRelease);
    harness.reclaimCrossChain(terms, policy, false, lock);

    vm.chainId(partyChain);
    assertEq(uint8(harness.crossState(terms, true, lock)), uint8(CrossChainLegState.Claimed));
    assertEq(uint8(harness.crossState(terms, false, lock)), uint8(CrossChainLegState.Reclaimed));
    assertEq(partyToken.balanceOf(PARTY_RECIPIENT), 10 ether);
    assertEq(counterpartyToken.balanceOf(COUNTERPARTY_RECLAIMER), 20 ether);
  }

  function test_crossChainRejectsWrongModeAndNonlocalSide() public {
    (ProtocolTerms memory sameTerms, TimingPolicy memory samePolicy, bytes32 sameLock) = _sameTerms();
    vm.expectRevert(Settlement.InvalidSettlementMode.selector);
    harness.claimCrossChain(sameTerms, samePolicy, true, sameLock, SECRET);

    (ProtocolTerms memory terms, TimingPolicy memory policy, bytes32 lock) = _crossTerms(true);
    terms.partySide.chainId = block.chainid + 2;
    policy.partyChainId = terms.partySide.chainId;
    terms.timingPolicyId = ProtocolHashing.timingPolicyId(policy);
    terms.counterpartySide.commitLock =
      ProtocolHashing.commitLock(ProtocolHashing.gateContextId(terms), bytes32(uint256(7)));
    lock = ProtocolHashing.settlementLock(ProtocolHashing.tradeId(terms), SECRET);
    vm.expectRevert(Settlement.InvalidLocalChain.selector);
    harness.claimCrossChain(terms, policy, true, lock, SECRET);
  }

  function test_sameChainClaimAtomicallyPaysBothFixedRecipients() public {
    (ProtocolTerms memory terms, TimingPolicy memory policy, bytes32 lock) = _sameTerms();
    _fundAndSeedSame(terms, lock, true);

    vm.prank(EXECUTOR);
    harness.claimSameChain(terms, policy, lock, SECRET);

    assertEq(partyToken.balanceOf(PARTY_RECIPIENT), 10 ether);
    assertEq(counterpartyToken.balanceOf(COUNTERPARTY_RECIPIENT), 20 ether);
    assertEq(uint8(harness.sameState(terms, lock)), uint8(SameChainState.Claimed));
  }

  function test_leakedSettlementSecretCannotClaimHalfCommittedSameChainTrade() public {
    (ProtocolTerms memory terms, TimingPolicy memory policy, bytes32 lock) = _sameTerms();
    _fundAndSeedSame(terms, lock, false);

    vm.expectRevert(
      abi.encodeWithSelector(
        SameChainStateMachine.InvalidSameChainState.selector,
        SameChainState.BothCommitted,
        SameChainState.PartyCommitted
      )
    );
    harness.claimSameChain(terms, policy, lock, SECRET);

    assertEq(partyToken.balanceOf(address(harness)), 10 ether);
    assertEq(uint8(harness.sameState(terms, lock)), uint8(SameChainState.PartyCommitted));
  }

  function test_sameChainClaimUsesMinimumExclusiveDeadline() public {
    (ProtocolTerms memory terms, TimingPolicy memory policy, bytes32 lock) = _sameTerms();
    _fundAndSeedSame(terms, lock, true);
    vm.warp(terms.partySide.claimDeadline);

    vm.expectRevert(Settlement.ClaimWindowClosed.selector);
    harness.claimSameChain(terms, policy, lock, SECRET);
    assertEq(uint8(harness.sameState(terms, lock)), uint8(SameChainState.BothCommitted));
  }

  function test_sameChainFailedSecondPayoutRollsBackFirstPayoutAndState() public {
    (ProtocolTerms memory terms, TimingPolicy memory policy, bytes32 lock) = _sameTerms();
    _fundSide(terms.partySide, partyToken, 10 ether);
    _fundSide(terms.counterpartySide, counterpartyToken, 20 ether);
    harness.seedSameChainParty(terms, lock);
    harness.seedSameChainCounterparty(terms, lock);
    counterpartyToken.burn(address(harness), 20 ether);

    vm.expectRevert();
    harness.claimSameChain(terms, policy, lock, SECRET);

    assertEq(partyToken.balanceOf(PARTY_RECIPIENT), 0);
    assertEq(partyToken.balanceOf(address(harness)), 10 ether);
    assertEq(uint8(harness.sameState(terms, lock)), uint8(SameChainState.BothCommitted));
  }

  function test_sameChainOneSidedReclaimReturnsOnlyPartyLeg() public {
    (ProtocolTerms memory terms, TimingPolicy memory policy, bytes32 lock) = _sameTerms();
    _fundSide(terms.partySide, partyToken, 10 ether);
    harness.seedSameChainParty(terms, lock);
    vm.warp(terms.partySide.reclaimRelease);

    vm.prank(EXECUTOR);
    harness.reclaimSameChainParty(terms, policy, lock);

    assertEq(partyToken.balanceOf(PARTY_RECLAIMER), 10 ether);
    assertEq(counterpartyToken.balanceOf(COUNTERPARTY_RECLAIMER), 0);
    assertEq(uint8(harness.sameState(terms, lock)), uint8(SameChainState.Reclaimed));
  }

  function test_sameChainOneSidedReclaimRejectsBeforePartyRelease() public {
    (ProtocolTerms memory terms, TimingPolicy memory policy, bytes32 lock) = _sameTerms();
    _fundSide(terms.partySide, partyToken, 10 ether);
    harness.seedSameChainParty(terms, lock);
    vm.warp(terms.partySide.reclaimRelease - 1);

    vm.expectRevert(Settlement.ReclaimWindowClosed.selector);
    harness.reclaimSameChainParty(terms, policy, lock);
    assertEq(uint8(harness.sameState(terms, lock)), uint8(SameChainState.PartyCommitted));
  }

  function test_sameChainDualReclaimRequiresBothReleasesAndIsAtomic() public {
    (ProtocolTerms memory terms, TimingPolicy memory policy, bytes32 lock) = _sameTerms();
    _fundAndSeedSame(terms, lock, true);
    vm.warp(terms.counterpartySide.reclaimRelease - 1);
    vm.expectRevert(Settlement.ReclaimWindowClosed.selector);
    harness.reclaimSameChainBoth(terms, policy, lock);

    vm.warp(terms.counterpartySide.reclaimRelease);
    vm.prank(EXECUTOR);
    harness.reclaimSameChainBoth(terms, policy, lock);
    assertEq(partyToken.balanceOf(PARTY_RECLAIMER), 10 ether);
    assertEq(counterpartyToken.balanceOf(COUNTERPARTY_RECLAIMER), 20 ether);
    assertEq(uint8(harness.sameState(terms, lock)), uint8(SameChainState.Reclaimed));
  }

  function test_finalClaimDelayNeverCreatesAClaimWait() public {
    (ProtocolTerms memory terms, TimingPolicy memory policy, bytes32 lock) = _crossTerms(true);
    policy.partyToCounterpartyDelay = 150;
    terms.timingPolicyId = ProtocolHashing.timingPolicyId(policy);
    terms.counterpartySide.commitLock =
      ProtocolHashing.commitLock(ProtocolHashing.gateContextId(terms), bytes32(uint256(7)));
    terms.counterpartySide.reclaimRelease = terms.partySide.claimDeadline + 150;
    lock = ProtocolHashing.settlementLock(ProtocolHashing.tradeId(terms), SECRET);
    _fundAndSeedCross(terms, true, lock);

    harness.claimCrossChain(terms, policy, true, lock, SECRET);
    assertEq(uint8(harness.crossState(terms, true, lock)), uint8(CrossChainLegState.Claimed));
  }

  function _fundAndSeedCross(ProtocolTerms memory terms, bool party, bytes32 lock) internal {
    if (party) _fundSide(terms.partySide, partyToken, 10 ether);
    else _fundSide(terms.counterpartySide, counterpartyToken, 20 ether);
    harness.seedCrossChain(terms, party, lock);
  }

  function _fundAndSeedSame(ProtocolTerms memory terms, bytes32 lock, bool both) internal {
    _fundSide(terms.partySide, partyToken, 10 ether);
    harness.seedSameChainParty(terms, lock);
    if (both) {
      _fundSide(terms.counterpartySide, counterpartyToken, 20 ether);
      harness.seedSameChainCounterparty(terms, lock);
    }
  }

  function _fundSide(SideTerms memory side, ERC20Mock token, uint256 amount) internal {
    token.mint(side.principal, amount);
    vm.prank(side.principal);
    token.approve(address(harness), amount);
  }

  function _crossTerms(bool partyLocal)
    internal
    view
    returns (ProtocolTerms memory terms, TimingPolicy memory policy, bytes32 lock)
  {
    uint256 partyChain = partyLocal ? block.chainid : block.chainid + 1;
    uint256 counterpartyChain = partyLocal ? block.chainid + 1 : block.chainid;
    terms.partySide = _side(partyChain, partyToken, 10 ether, PARTY_RECIPIENT, PARTY_RECLAIMER, 110, 200, 400, 1);
    terms.counterpartySide = _side(
      counterpartyChain, counterpartyToken, 20 ether, COUNTERPARTY_RECIPIENT, COUNTERPARTY_RECLAIMER, 120, 220, 400, 2
    );
    policy = TimingPolicy({
      policyVersion: 1,
      mode: WrapperMode.CrossChain,
      partyChainId: partyChain,
      counterpartyChainId: counterpartyChain,
      partyToCounterpartyDelay: 10,
      counterpartyToPartyDelay: 10
    });
    terms.timingPolicyId = ProtocolHashing.timingPolicyId(policy);
    terms.counterpartySide.commitLock =
      ProtocolHashing.commitLock(ProtocolHashing.gateContextId(terms), bytes32(uint256(7)));
    lock = ProtocolHashing.settlementLock(ProtocolHashing.tradeId(terms), SECRET);
  }

  function _sameTerms() internal view returns (ProtocolTerms memory terms, TimingPolicy memory policy, bytes32 lock) {
    terms.partySide = _side(block.chainid, partyToken, 10 ether, PARTY_RECIPIENT, PARTY_RECLAIMER, 110, 200, 300, 1);
    terms.counterpartySide = _side(
      block.chainid, counterpartyToken, 20 ether, COUNTERPARTY_RECIPIENT, COUNTERPARTY_RECLAIMER, 120, 210, 310, 2
    );
    policy = TimingPolicy({
      policyVersion: 1,
      mode: WrapperMode.SameChain,
      partyChainId: block.chainid,
      counterpartyChainId: block.chainid,
      partyToCounterpartyDelay: 0,
      counterpartyToPartyDelay: 0
    });
    terms.timingPolicyId = ProtocolHashing.timingPolicyId(policy);
    lock = ProtocolHashing.settlementLock(ProtocolHashing.tradeId(terms), SECRET);
  }

  function _side(
    uint256 chainId,
    ERC20Mock token,
    uint256 amount,
    address recipient,
    address reclaimer,
    uint256 commitmentDeadline,
    uint256 claimDeadline,
    uint256 reclaimRelease,
    uint256 nonce
  ) internal pure returns (SideTerms memory side) {
    side.chainId = chainId;
    side.assets = new Asset[](1);
    side.assets[0] = Asset({assetType: AssetType.ERC20, target: address(token), id: 0, amount: amount});
    side.principal = nonce == 1 ? address(0x1001) : address(0x1002);
    side.authorizationMode = AuthorizationMode.RegisteredDirect;
    side.principalKeyVersion = 1;
    side.reclaimRecipient = reclaimer;
    side.recipient = recipient;
    side.commitmentDeadline = commitmentDeadline;
    side.claimDeadline = claimDeadline;
    side.reclaimRelease = reclaimRelease;
    side.delegationPolicy = DelegationPolicy.NotAllowed;
    side.sideNonce = bytes32(nonce);
  }
}
