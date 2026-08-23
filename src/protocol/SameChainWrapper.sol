// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {AssetCustody} from '../assets/AssetHandling.sol';
import {AssetSupport} from '../assets/AssetHandling.sol';
import {IAssetSupportRegistry} from '../interfaces/IAssetSupportRegistry.sol';
import {ICommitAuthorizationReceiver} from '../interfaces/ICommitAuthorizationReceiver.sol';
import {CommitAuthorization} from './CommitValidation.sol';
import {ProgressionGate} from './CommitValidation.sol';
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
/// @notice Escrows two local legs and settles them atomically in a v1.1 same-chain swap.
/// @dev Commits must arrive from the authorization boundary named by the terms. Claims and
///      reclaims are permissionless because terms fix every payout recipient. Wallet-mode
///      provenance is not factory-checked here; the signed principal address is the trust boundary.
contract SameChainWrapper is ICommitAuthorizationReceiver, ERC721Holder, ERC1155Holder, ReentrancyGuard {
  using AssetCustody for AssetCustody.Layout;
  using AssetSupport for SideTerms;
  using SameChainStateMachine for SameChainStateMachine.Layout;
  using Settlement for SameChainStateMachine.Layout;

  error ZeroConfiguration();
  error InvalidWrapperMode();
  error InvalidLocalChain();
  error CommitWindowClosed();

  event Committed(bytes32 indexed tradeId, bytes32 indexed lock, SideTag indexed side, address principal);
  event Claimed(bytes32 indexed tradeId, bytes32 indexed lock);
  event Reclaimed(bytes32 indexed tradeId, bytes32 indexed lock);

  /// @notice Gateway trusted to authenticate RegisteredDirect commit signatures.
  address public immutable DIRECT_AUTHORIZATION;
  /// @notice Admission allowlist consulted only when new assets enter custody.
  IAssetSupportRegistry public immutable ASSET_SUPPORT;

  SameChainStateMachine.Layout private states;
  AssetCustody.Layout private custody;

  /// @notice Configures the immutable direct authorization gateway and asset allowlist.
  constructor(address directAuthorization, IAssetSupportRegistry assetSupport) {
    if (directAuthorization == address(0) || address(assetSupport) == address(0)) {
      revert ZeroConfiguration();
    }
    DIRECT_AUTHORIZATION = directAuthorization;
    ASSET_SUPPORT = assetSupport;
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

    // Enforce party-first ordering through the joint state machine.
    if (party) states.commitParty(trade, lock);
    else states.commitCounterparty(trade, lock);
    // Pull the exact signed assets after the state transition.
    custody.collect(side, msg.value);
    emit Committed(trade, lock, ProtocolHashing.sideTag(party), side.principal);
  }

  /// @notice Permissionlessly claims both escrows atomically to their fixed recipients.
  function claim(ProtocolTerms calldata terms, bytes32 lock, bytes32 secret) external nonReentrant {
    // One state transition and call release both local escrows atomically.
    bytes32 trade = states.claimSameChain(custody, terms, lock, secret, block.timestamp);
    emit Claimed(trade, lock);
  }

  /// @notice Reclaims the party escrow if the counterparty never committed.
  function reclaimParty(ProtocolTerms calldata terms, bytes32 lock) external nonReentrant {
    // This path is reachable only while the joint state is PartyCommitted.
    bytes32 trade = states.reclaimSameChainParty(custody, terms, lock, block.timestamp);
    emit Reclaimed(trade, lock);
  }

  /// @notice Reclaims both committed escrows atomically after both reclaim releases.
  function reclaimBoth(ProtocolTerms calldata terms, bytes32 lock) external nonReentrant {
    // This path requires BothCommitted and both reclaim releases to have opened.
    bytes32 trade = states.reclaimSameChainBoth(custody, terms, lock, block.timestamp);
    emit Reclaimed(trade, lock);
  }

  /// @notice Returns the joint state for these exact terms and settlement lock.
  function state(ProtocolTerms calldata terms, bytes32 lock) external view returns (SameChainState) {
    return states.state(ProtocolHashing.tradeId(terms), lock);
  }

  /// @notice Returns aggregate custody reserved for one asset identity.
  function reserved(Asset calldata asset) external view returns (uint256) {
    return custody.reservedAmount(asset);
  }

  function _validate(ProtocolTerms memory terms) private pure {
    if (ProtocolHashing.mode(terms) != WrapperMode.SameChain) revert InvalidWrapperMode();
    ProtocolHashing.validateTerms(terms);
  }
}
