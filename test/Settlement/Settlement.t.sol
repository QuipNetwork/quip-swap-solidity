// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {Test} from 'forge-std-1.14.0/Test.sol';

import {ProtocolHashing} from '../../src/protocol/ProtocolHashing.sol';
import {
  AuthorizationMode,
  CrossChainLegState,
  DelegationPolicy,
  ProtocolTerms,
  SameChainState,
  SideTerms,
  WrapperMode
} from '../../src/protocol/ProtocolTypes.sol';
import {Asset, AssetType} from '../../src/protocol/ProtocolTypes.sol';
import {Settlement} from '../../src/protocol/Settlement.sol';
import {CrossChainStateMachine} from '../../src/protocol/StateMachines.sol';
import {SameChainStateMachine} from '../../src/protocol/StateMachines.sol';
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
    (ProtocolTerms memory terms, bytes32 lock) = _crossTerms(true);
    _fundAndSeedCross(terms, true, lock);

    vm.prank(EXECUTOR);
    harness.claimCrossChain(terms, true, lock, SECRET);

    assertEq(partyToken.balanceOf(PARTY_RECIPIENT), 10 ether);
    assertEq(partyToken.balanceOf(EXECUTOR), 0);
    assertEq(uint8(harness.crossState(terms, true, lock)), uint8(CrossChainLegState.Claimed));
  }

  function test_leakedSettlementSecretClaimsPartyLegBeforeCounterpartyCommit() public {
    (ProtocolTerms memory terms, bytes32 lock) = _crossTerms(true);
    _fundAndSeedCross(terms, true, lock);
    assertEq(uint8(harness.crossState(terms, false, lock)), uint8(CrossChainLegState.Unused));

    vm.prank(EXECUTOR);
    harness.claimCrossChain(terms, true, lock, SECRET);

    assertEq(partyToken.balanceOf(PARTY_RECIPIENT), 10 ether);
    assertEq(uint8(harness.crossState(terms, true, lock)), uint8(CrossChainLegState.Claimed));
    assertEq(uint8(harness.crossState(terms, false, lock)), uint8(CrossChainLegState.Unused));
  }

  function test_crossChainClaimRejectsWrongSecretAndExclusiveDeadlineWithoutEffects() public {
    (ProtocolTerms memory terms, bytes32 lock) = _crossTerms(true);
    _fundAndSeedCross(terms, true, lock);

    vm.expectRevert(Settlement.InvalidSettlementSecret.selector);
    harness.claimCrossChain(terms, true, lock, keccak256('wrong'));
    vm.warp(terms.partySide.claimDeadline);
    vm.expectRevert(Settlement.ClaimWindowClosed.selector);
    harness.claimCrossChain(terms, true, lock, SECRET);

    assertEq(partyToken.balanceOf(address(harness)), 10 ether);
    assertEq(uint8(harness.crossState(terms, true, lock)), uint8(CrossChainLegState.Committed));
  }

  function test_crossChainCounterpartyClaimUsesItsLocalDeadlineAndRecipient() public {
    (ProtocolTerms memory terms, bytes32 lock) = _crossTerms(false);
    _fundAndSeedCross(terms, false, lock);

    vm.prank(EXECUTOR);
    harness.claimCrossChain(terms, false, lock, SECRET);

    assertEq(counterpartyToken.balanceOf(COUNTERPARTY_RECIPIENT), 20 ether);
    assertEq(uint8(harness.crossState(terms, false, lock)), uint8(CrossChainLegState.Claimed));
  }

  function test_crossChainReclaimIsPermissionlessAtReleaseAndPayoutFixed() public {
    (ProtocolTerms memory terms, bytes32 lock) = _crossTerms(true);
    _fundAndSeedCross(terms, true, lock);
    vm.warp(terms.partySide.reclaimRelease);

    vm.prank(EXECUTOR);
    harness.reclaimCrossChain(terms, true, lock);

    assertEq(partyToken.balanceOf(PARTY_RECLAIMER), 10 ether);
    assertEq(partyToken.balanceOf(EXECUTOR), 0);
    assertEq(uint8(harness.crossState(terms, true, lock)), uint8(CrossChainLegState.Reclaimed));
  }

  function test_crossChainReclaimRejectsBeforeReleaseAndClaimReclaimRaceIsTerminal() public {
    (ProtocolTerms memory terms, bytes32 lock) = _crossTerms(true);
    _fundAndSeedCross(terms, true, lock);
    vm.warp(terms.partySide.reclaimRelease - 1);
    vm.expectRevert(Settlement.ReclaimWindowClosed.selector);
    harness.reclaimCrossChain(terms, true, lock);

    vm.warp(terms.partySide.reclaimRelease);
    harness.reclaimCrossChain(terms, true, lock);
    vm.expectRevert(Settlement.ClaimWindowClosed.selector);
    harness.claimCrossChain(terms, true, lock, SECRET);
    assertEq(uint8(harness.crossState(terms, true, lock)), uint8(CrossChainLegState.Reclaimed));
  }

  function test_crossChainClaimThenReclaimRacePreservesClaimedTerminalState() public {
    (ProtocolTerms memory terms, bytes32 lock) = _crossTerms(true);
    _fundAndSeedCross(terms, true, lock);
    harness.claimCrossChain(terms, true, lock, SECRET);
    vm.warp(terms.partySide.reclaimRelease);

    vm.expectRevert(
      abi.encodeWithSelector(
        CrossChainStateMachine.InvalidCrossChainState.selector, CrossChainLegState.Committed, CrossChainLegState.Claimed
      )
    );
    harness.reclaimCrossChain(terms, true, lock);
    assertEq(uint8(harness.crossState(terms, true, lock)), uint8(CrossChainLegState.Claimed));
  }

  function test_crossChainAsymmetricClaimedReclaimedOutcomeRemainsLocallyPossible() public {
    uint256 partyChain = block.chainid;
    (ProtocolTerms memory terms, bytes32 lock) = _crossTerms(true);
    _fundSide(terms.partySide, partyToken, 10 ether);
    _fundSide(terms.counterpartySide, counterpartyToken, 20 ether);
    harness.seedCrossChain(terms, true, lock);
    harness.seedCrossChain(terms, false, lock);

    harness.claimCrossChain(terms, true, lock, SECRET);
    vm.chainId(terms.counterpartySide.chainId);
    vm.warp(terms.counterpartySide.reclaimRelease);
    harness.reclaimCrossChain(terms, false, lock);

    vm.chainId(partyChain);
    assertEq(uint8(harness.crossState(terms, true, lock)), uint8(CrossChainLegState.Claimed));
    assertEq(uint8(harness.crossState(terms, false, lock)), uint8(CrossChainLegState.Reclaimed));
    assertEq(partyToken.balanceOf(PARTY_RECIPIENT), 10 ether);
    assertEq(counterpartyToken.balanceOf(COUNTERPARTY_RECLAIMER), 20 ether);
  }

  function test_crossChainRejectsWrongModeAndNonlocalSide() public {
    (ProtocolTerms memory sameTerms, bytes32 sameLock) = _sameTerms();
    vm.expectRevert(Settlement.InvalidSettlementMode.selector);
    harness.claimCrossChain(sameTerms, true, sameLock, SECRET);

    (ProtocolTerms memory terms, bytes32 lock) = _crossTerms(true);
    terms.partySide.chainId = block.chainid + 2;
    terms.counterpartySide.commitLock =
      ProtocolHashing.commitLock(ProtocolHashing.gateContextId(terms), bytes32(uint256(7)));
    lock = ProtocolHashing.settlementLock(ProtocolHashing.tradeId(terms), SECRET);
    vm.expectRevert(Settlement.InvalidLocalChain.selector);
    harness.claimCrossChain(terms, true, lock, SECRET);
  }

  function test_sameChainClaimAtomicallyPaysBothFixedRecipients() public {
    (ProtocolTerms memory terms, bytes32 lock) = _sameTerms();
    _fundAndSeedSame(terms, lock, true);

    vm.prank(EXECUTOR);
    harness.claimSameChain(terms, lock, SECRET);

    assertEq(partyToken.balanceOf(PARTY_RECIPIENT), 10 ether);
    assertEq(counterpartyToken.balanceOf(COUNTERPARTY_RECIPIENT), 20 ether);
    assertEq(uint8(harness.sameState(terms, lock)), uint8(SameChainState.Claimed));
  }

  function test_sameChainClaimSelectionUsesEarlierExclusiveDeadlineWithoutPayout() public {
    (ProtocolTerms memory terms, bytes32 lock) = _sameTerms();
    _fundAndSeedSame(terms, lock, true);
    vm.warp(terms.partySide.claimDeadline - 1);

    vm.prank(EXECUTOR);
    harness.selectSameChainClaim(terms, lock, SECRET);

    assertEq(uint8(harness.sameState(terms, lock)), uint8(SameChainState.ClaimPending));
    assertEq(partyToken.balanceOf(address(harness)), 10 ether);
    assertEq(counterpartyToken.balanceOf(address(harness)), 20 ether);
    assertEq(partyToken.balanceOf(PARTY_RECIPIENT), 0);
    assertEq(counterpartyToken.balanceOf(COUNTERPARTY_RECIPIENT), 0);
  }

  function test_sameChainClaimSelectionRejectsWrongSecretAndEarlierDeadline() public {
    (ProtocolTerms memory terms, bytes32 lock) = _sameTerms();
    _fundAndSeedSame(terms, lock, true);

    vm.expectRevert(Settlement.InvalidSettlementSecret.selector);
    harness.selectSameChainClaim(terms, lock, keccak256('wrong'));
    vm.warp(terms.partySide.claimDeadline);
    vm.expectRevert(Settlement.ClaimWindowClosed.selector);
    harness.selectSameChainClaim(terms, lock, SECRET);

    assertEq(uint8(harness.sameState(terms, lock)), uint8(SameChainState.BothCommitted));
  }

  function test_leakedSettlementSecretCannotClaimHalfCommittedSameChainTrade() public {
    (ProtocolTerms memory terms, bytes32 lock) = _sameTerms();
    _fundAndSeedSame(terms, lock, false);

    vm.expectRevert(
      abi.encodeWithSelector(
        SameChainStateMachine.InvalidSameChainState.selector,
        SameChainState.BothCommitted,
        SameChainState.PartyCommitted
      )
    );
    harness.claimSameChain(terms, lock, SECRET);

    assertEq(partyToken.balanceOf(address(harness)), 10 ether);
    assertEq(uint8(harness.sameState(terms, lock)), uint8(SameChainState.PartyCommitted));
  }

  function test_sameChainClaimUsesMinimumExclusiveDeadline() public {
    (ProtocolTerms memory terms, bytes32 lock) = _sameTerms();
    _fundAndSeedSame(terms, lock, true);
    vm.warp(terms.partySide.claimDeadline);

    vm.expectRevert(Settlement.ClaimWindowClosed.selector);
    harness.claimSameChain(terms, lock, SECRET);
    assertEq(uint8(harness.sameState(terms, lock)), uint8(SameChainState.BothCommitted));
  }

  function test_sameChainFailedSecondPayoutRollsBackFirstPayoutAndState() public {
    (ProtocolTerms memory terms, bytes32 lock) = _sameTerms();
    _fundSide(terms.partySide, partyToken, 10 ether);
    _fundSide(terms.counterpartySide, counterpartyToken, 20 ether);
    harness.seedSameChainParty(terms, lock);
    harness.seedSameChainCounterparty(terms, lock);
    counterpartyToken.burn(address(harness), 20 ether);

    vm.expectRevert();
    harness.claimSameChain(terms, lock, SECRET);

    assertEq(partyToken.balanceOf(PARTY_RECIPIENT), 0);
    assertEq(partyToken.balanceOf(address(harness)), 10 ether);
    assertEq(uint8(harness.sameState(terms, lock)), uint8(SameChainState.BothCommitted));
  }

  function test_sameChainOneSidedReclaimReturnsOnlyPartyLeg() public {
    (ProtocolTerms memory terms, bytes32 lock) = _sameTerms();
    _fundSide(terms.partySide, partyToken, 10 ether);
    harness.seedSameChainParty(terms, lock);
    vm.warp(terms.partySide.reclaimRelease);

    vm.prank(EXECUTOR);
    harness.reclaimSameChainParty(terms, lock);

    assertEq(partyToken.balanceOf(PARTY_RECLAIMER), 10 ether);
    assertEq(counterpartyToken.balanceOf(COUNTERPARTY_RECLAIMER), 0);
    assertEq(uint8(harness.sameState(terms, lock)), uint8(SameChainState.Reclaimed));
  }

  function test_sameChainOneSidedReclaimRejectsBeforePartyRelease() public {
    (ProtocolTerms memory terms, bytes32 lock) = _sameTerms();
    _fundSide(terms.partySide, partyToken, 10 ether);
    harness.seedSameChainParty(terms, lock);
    vm.warp(terms.partySide.reclaimRelease - 1);

    vm.expectRevert(Settlement.ReclaimWindowClosed.selector);
    harness.reclaimSameChainParty(terms, lock);
    assertEq(uint8(harness.sameState(terms, lock)), uint8(SameChainState.PartyCommitted));
  }

  function test_sameChainOneSidedReclaimSelectionOpensAtPartyReleaseWithoutPayout() public {
    (ProtocolTerms memory terms, bytes32 lock) = _sameTerms();
    _fundAndSeedSame(terms, lock, false);
    vm.warp(terms.partySide.reclaimRelease - 1);
    vm.expectRevert(Settlement.ReclaimWindowClosed.selector);
    harness.selectSameChainPartyReclaim(terms, lock);

    vm.warp(terms.partySide.reclaimRelease);
    vm.prank(EXECUTOR);
    harness.selectSameChainPartyReclaim(terms, lock);

    assertEq(uint8(harness.sameState(terms, lock)), uint8(SameChainState.ReclaimPending));
    assertEq(partyToken.balanceOf(address(harness)), 10 ether);
    assertEq(partyToken.balanceOf(PARTY_RECLAIMER), 0);
  }

  function test_sameChainDualReclaimRequiresBothReleasesAndIsAtomic() public {
    (ProtocolTerms memory terms, bytes32 lock) = _sameTerms();
    _fundAndSeedSame(terms, lock, true);
    vm.warp(terms.counterpartySide.reclaimRelease - 1);
    vm.expectRevert(Settlement.ReclaimWindowClosed.selector);
    harness.reclaimSameChainBoth(terms, lock);

    vm.warp(terms.counterpartySide.reclaimRelease);
    vm.prank(EXECUTOR);
    harness.reclaimSameChainBoth(terms, lock);
    assertEq(partyToken.balanceOf(PARTY_RECLAIMER), 10 ether);
    assertEq(counterpartyToken.balanceOf(COUNTERPARTY_RECLAIMER), 20 ether);
    assertEq(uint8(harness.sameState(terms, lock)), uint8(SameChainState.Reclaimed));
  }

  function test_sameChainDualReclaimSelectionUsesLaterReleaseWithoutPayout() public {
    (ProtocolTerms memory terms, bytes32 lock) = _sameTerms();
    _fundAndSeedSame(terms, lock, true);
    vm.warp(terms.counterpartySide.reclaimRelease - 1);
    vm.expectRevert(Settlement.ReclaimWindowClosed.selector);
    harness.selectSameChainBothReclaim(terms, lock);

    vm.warp(terms.counterpartySide.reclaimRelease);
    vm.prank(EXECUTOR);
    harness.selectSameChainBothReclaim(terms, lock);

    assertEq(uint8(harness.sameState(terms, lock)), uint8(SameChainState.ReclaimPending));
    assertEq(partyToken.balanceOf(address(harness)), 10 ether);
    assertEq(counterpartyToken.balanceOf(address(harness)), 20 ether);
    assertEq(partyToken.balanceOf(PARTY_RECLAIMER), 0);
    assertEq(counterpartyToken.balanceOf(COUNTERPARTY_RECLAIMER), 0);
  }

  function test_validCrossChainClaimHasNoPermanentDelay() public {
    (ProtocolTerms memory terms, bytes32 lock) = _crossTerms(true);
    _fundAndSeedCross(terms, true, lock);

    harness.claimCrossChain(terms, true, lock, SECRET);
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

  function _crossTerms(bool partyLocal) internal view returns (ProtocolTerms memory terms, bytes32 lock) {
    uint256 partyChain = partyLocal ? block.chainid : block.chainid + 1;
    uint256 counterpartyChain = partyLocal ? block.chainid + 1 : block.chainid;
    terms.partySide = _side(partyChain, partyToken, 10 ether, PARTY_RECIPIENT, PARTY_RECLAIMER, 110, 200, 400, 1);
    terms.counterpartySide = _side(
      counterpartyChain, counterpartyToken, 20 ether, COUNTERPARTY_RECIPIENT, COUNTERPARTY_RECLAIMER, 120, 220, 400, 2
    );
    terms.counterpartySide.commitLock =
      ProtocolHashing.commitLock(ProtocolHashing.gateContextId(terms), bytes32(uint256(7)));
    lock = ProtocolHashing.settlementLock(ProtocolHashing.tradeId(terms), SECRET);
  }

  function _sameTerms() internal view returns (ProtocolTerms memory terms, bytes32 lock) {
    terms.partySide = _side(block.chainid, partyToken, 10 ether, PARTY_RECIPIENT, PARTY_RECLAIMER, 110, 200, 300, 1);
    terms.counterpartySide = _side(
      block.chainid, counterpartyToken, 20 ether, COUNTERPARTY_RECIPIENT, COUNTERPARTY_RECLAIMER, 120, 210, 310, 2
    );
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
