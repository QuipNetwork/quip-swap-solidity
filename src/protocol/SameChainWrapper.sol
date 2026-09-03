// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {AssetCustody, HTLCFunding} from '../assets/AssetHandling.sol';
import {AssetSupport} from '../assets/AssetHandling.sol';
import {IAssetSupportRegistry} from '../interfaces/IAssetSupportRegistry.sol';
import {ICommitAuthorizationReceiver} from '../interfaces/ICommitAuthorizationReceiver.sol';
import {ISwapHTLC} from '../interfaces/ISwapHTLC.sol';
import {CommitAuthorization} from './CommitValidation.sol';
import {ProgressionGate} from './CommitValidation.sol';
import {CommitmentFees} from './CommitmentFees.sol';
import {HTLCDeployer} from './HTLCDeployer.sol';
import {ProtocolHashing} from './ProtocolHashing.sol';
import {
  ProtocolTerms,
  SameChainState,
  SideTag,
  SideTerms,
  VerifiedCommitAuthorization,
  WrapperMode
} from './ProtocolTypes.sol';
import {Asset} from './ProtocolTypes.sol';
import {Settlement} from './Settlement.sol';
import {SameChainStateMachine} from './StateMachines.sol';
import {ERC1155Holder} from '@openzeppelin-contracts-5.6.0-rc.1/token/ERC1155/utils/ERC1155Holder.sol';
import {ERC721Holder} from '@openzeppelin-contracts-5.6.0-rc.1/token/ERC721/utils/ERC721Holder.sol';
import {ReentrancyGuard} from '@openzeppelin-contracts-5.6.0-rc.1/utils/ReentrancyGuard.sol';

/// @title SameChainWrapper
/// @notice Escrows two local legs and settles a selected outcome through resumable side execution.
/// @dev Commits must arrive from the authorization boundary named by the terms. Claims and
///      reclaims are permissionless because terms fix every payout recipient. Wallet-mode
///      provenance is not factory-checked here; the signed principal address is the trust boundary.
contract SameChainWrapper is
  ICommitAuthorizationReceiver,
  CommitmentFees,
  ERC721Holder,
  ERC1155Holder,
  ReentrancyGuard
{
  using AssetCustody for AssetCustody.Layout;
  using HTLCFunding for SideTerms;
  using AssetSupport for SideTerms;
  using SameChainStateMachine for SameChainStateMachine.Layout;
  using Settlement for SameChainStateMachine.Layout;

  error ZeroConfiguration();
  error InvalidWrapperMode();
  error InvalidLocalChain();
  error CommitWindowClosed();
  error HTLCAlreadyExists();
  error AtomicSettlementDisabled();

  event Committed(bytes32 indexed tradeId, bytes32 indexed lock, SideTag indexed side, address principal);
  event HTLCCreated(bytes32 indexed tradeId, bytes32 indexed lock, SideTag indexed side, address htlc);
  event ClaimSelected(bytes32 indexed tradeId, bytes32 indexed lock);
  event ReclaimSelected(bytes32 indexed tradeId, bytes32 indexed lock, uint8 expectedSides);
  event SettlementBatchExecuted(
    bytes32 indexed tradeId, bytes32 indexed lock, SideTag indexed side, uint256 nextAssetIndex, bool complete
  );
  event SideReleased(bytes32 indexed tradeId, bytes32 indexed lock, SideTag indexed side);
  event Claimed(bytes32 indexed tradeId, bytes32 indexed lock);
  event Reclaimed(bytes32 indexed tradeId, bytes32 indexed lock);

  /// @notice Gateway trusted to authenticate RegisteredDirect commit signatures.
  address public immutable DIRECT_AUTHORIZATION;
  /// @notice Admission allowlist consulted only when new assets enter custody.
  IAssetSupportRegistry public immutable ASSET_SUPPORT;
  /// @notice Non-upgradeable implementation cloned once for every committed side.
  address public immutable HTLC_IMPLEMENTATION;

  SameChainStateMachine.Layout private states;
  AssetCustody.Layout private custody;
  mapping(bytes32 recordKey => address htlc) private htlcs;

  /// @notice Configures the immutable direct authorization gateway and asset allowlist.
  constructor(
    address directAuthorization,
    IAssetSupportRegistry assetSupport,
    address htlcImplementation,
    address initialOwner
  ) CommitmentFees(initialOwner) {
    if (directAuthorization == address(0) || address(assetSupport) == address(0) || htlcImplementation.code.length == 0)
    {
      revert ZeroConfiguration();
    }
    DIRECT_AUTHORIZATION = directAuthorization;
    ASSET_SUPPORT = assetSupport;
    HTLC_IMPLEMENTATION = htlcImplementation;
  }

  /// @notice Validates authorization and funding, then records the next ordered local commit.
  /// @dev The party must commit first. Same-chain commits carry no Bob-commit progression secret.
  function receiveAuthorizedCommit(
    ProtocolTerms calldata terms,
    bool party,
    bytes32 lock,
    bytes32 bobCommitSecret,
    VerifiedCommitAuthorization calldata evidence,
    bytes calldata
  ) external payable nonReentrant {
    // Copy calldata once, then validate the complete same-chain term set.
    ProtocolTerms memory validatedTerms = terms;
    _validate(validatedTerms);
    // Select the funded leg; both terms must name this deployment chain.
    SideTerms memory side = party ? validatedTerms.partySide : validatedTerms.counterpartySide;
    if (side.chainId != block.chainid) revert InvalidLocalChain();
    // Reject token contracts that have not passed the custody compatibility policy.
    side.requireSupported(ASSET_SUPPORT);
    // Bind gateway evidence to the exact trade, wrapper, leg, state, and fresh action nonce.
    bytes32 trade = CommitAuthorization.validate(
      validatedTerms, party, DIRECT_AUTHORIZATION, address(this), lock, msg.sender, evidence, block.timestamp
    );
    // Same-chain execution must not carry the cross-chain progression secret.
    ProgressionGate.validate(validatedTerms, bobCommitSecret);
    // Treat the commitment deadline as an exclusive upper bound.
    if (block.timestamp >= side.commitmentDeadline) revert CommitWindowClosed();
    // The wrapper retains the live fee and forwards only terms-declared escrow.
    _requireCommitValue(side.nativeAmount());

    // Enforce party-first ordering through the joint state machine before external calls.
    if (party) states.commitParty(trade, lock);
    else states.commitCounterparty(trade, lock);
    SideTag tag = ProtocolHashing.sideTag(party);
    bytes32 htlcKey = HTLCDeployer.recordKey(trade, lock, tag);
    if (htlcs[htlcKey] != address(0)) revert HTLCAlreadyExists();

    // Deploy and initialize one deterministic custody clone, forwarding native value directly.
    address htlc = HTLCDeployer.deploy(HTLC_IMPLEMENTATION, trade, lock, tag);
    ISwapHTLC(htlc).initialize{value: side.nativeAmount()}(trade, lock, tag, side);
    // The wrapper remains the allowance spender but tokens move principal -> HTLC without pooling.
    side.transferNonNative(htlc);
    ISwapHTLC(htlc).confirmFunding(side);
    htlcs[htlcKey] = htlc;
    // Accrue only after every custody operation succeeds, using the validated snapshot.
    _accrueCommitmentFee(msg.value - side.nativeAmount());

    emit Committed(trade, lock, ProtocolHashing.sideTag(party), side.principal);
    emit HTLCCreated(trade, lock, tag, htlc);
  }

  /// @notice Permissionlessly and irreversibly selects claim without executing a payout.
  /// @dev Settlement does not consult either side's commit-only delegation policy.
  function selectClaim(ProtocolTerms calldata terms, bytes32 lock, bytes32 secret) external {
    bytes32 trade = states.selectSameChainClaim(terms, lock, secret, block.timestamp);
    emit ClaimSelected(trade, lock);
  }

  /// @notice Permissionlessly and irreversibly selects the applicable reclaim without a payout.
  /// @dev Settlement does not consult either side's commit-only delegation policy.
  function selectReclaim(ProtocolTerms calldata terms, bytes32 lock) external {
    bytes32 trade = ProtocolHashing.tradeId(terms);
    SameChainState current = states.state(trade, lock);
    if (current == SameChainState.PartyCommitted) {
      trade = states.selectSameChainPartyReclaim(terms, lock, block.timestamp);
    } else {
      trade = states.selectSameChainBothReclaim(terms, lock, block.timestamp);
    }
    (uint8 expectedSides,) = states.settlementProgress(trade, lock);
    emit ReclaimSelected(trade, lock, expectedSides);
  }

  /// @notice Releases one required HTLC side for an already selected outcome.
  /// @dev Any caller may execute. The selected outcome and terms fix the recipient, while
  ///      `maxAssets` bounds this call's progress through the selected HTLC.
  function executeSettlement(
    ProtocolTerms calldata terms,
    bytes32 lock,
    bool party,
    uint256 maxAssets
  ) external nonReentrant {
    bytes32 trade = ProtocolHashing.tradeId(terms);
    SideTag side = ProtocolHashing.sideTag(party);
    Settlement.SameChainBatchResult memory result =
      states.executeSelectedSameChainHTLC(_htlc(trade, lock, side), terms, party, lock, maxAssets);
    emit SettlementBatchExecuted(result.trade, lock, side, result.nextAssetIndex, result.sideComplete);
    if (result.sideComplete) emit SideReleased(result.trade, lock, side);
    if (result.terminal) {
      if (result.outcome == SameChainState.ClaimPending) emit Claimed(result.trade, lock);
      else emit Reclaimed(result.trade, lock);
    }
  }

  /// @notice Disabled legacy atomic claim entry point.
  function claim(ProtocolTerms calldata, bytes32, bytes32) external pure {
    revert AtomicSettlementDisabled();
  }

  /// @notice Disabled legacy atomic party-reclaim entry point.
  function reclaimParty(ProtocolTerms calldata, bytes32) external pure {
    revert AtomicSettlementDisabled();
  }

  /// @notice Disabled legacy atomic dual-reclaim entry point.
  function reclaimBoth(ProtocolTerms calldata, bytes32) external pure {
    revert AtomicSettlementDisabled();
  }

  /// @notice Returns the joint state for these exact terms and settlement lock.
  function state(ProtocolTerms calldata terms, bytes32 lock) external view returns (SameChainState) {
    return states.state(ProtocolHashing.tradeId(terms), lock);
  }

  /// @notice Returns the required and completed side bitmaps for a selected settlement.
  function settlementProgress(
    ProtocolTerms calldata terms,
    bytes32 lock
  ) external view returns (uint8 expectedSides, uint8 completedSides) {
    return states.settlementProgress(ProtocolHashing.tradeId(terms), lock);
  }

  /// @notice Returns the deployed custody contract for one exact side, or zero before commit.
  function htlcOf(ProtocolTerms calldata terms, bool party, bytes32 lock) external view returns (address) {
    bytes32 trade = ProtocolHashing.tradeId(terms);
    return htlcs[HTLCDeployer.recordKey(trade, lock, ProtocolHashing.sideTag(party))];
  }

  /// @notice Predicts the deterministic custody address for one exact side.
  function predictHTLC(ProtocolTerms calldata terms, bool party, bytes32 lock) external view returns (address) {
    return HTLCDeployer.predict(
      HTLC_IMPLEMENTATION, address(this), ProtocolHashing.tradeId(terms), lock, ProtocolHashing.sideTag(party)
    );
  }

  /// @notice Returns aggregate custody reserved for one asset identity.
  function reserved(Asset calldata asset) external view returns (uint256) {
    return custody.reservedAmount(asset);
  }

  function _htlc(bytes32 trade, bytes32 lock, SideTag tag) private view returns (address) {
    return htlcs[HTLCDeployer.recordKey(trade, lock, tag)];
  }

  function _validate(ProtocolTerms memory terms) private pure {
    if (ProtocolHashing.mode(terms) != WrapperMode.SameChain) revert InvalidWrapperMode();
    ProtocolHashing.validateTerms(terms);
  }
}
