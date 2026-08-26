// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {AssetCustody} from '../assets/AssetHandling.sol';
import {AssetSupport} from '../assets/AssetHandling.sol';
import {IAssetSupportRegistry} from '../interfaces/IAssetSupportRegistry.sol';
import {ICommitAuthorizationReceiver} from '../interfaces/ICommitAuthorizationReceiver.sol';
import {CommitAuthorization} from './CommitValidation.sol';
import {ProgressionGate} from './CommitValidation.sol';
import {HTLCDeployer} from './HTLCDeployer.sol';
import {ProtocolHashing} from './ProtocolHashing.sol';
import {
  CrossChainLegState,
  ProtocolTerms,
  SideTag,
  SideTerms,
  VerifiedCommitAuthorization,
  WrapperMode
} from './ProtocolTypes.sol';
import {Asset} from './ProtocolTypes.sol';
import {Settlement} from './Settlement.sol';
import {CrossChainStateMachine} from './StateMachines.sol';
import {ERC1155Holder} from '@openzeppelin-contracts-5.6.0-rc.1/token/ERC1155/utils/ERC1155Holder.sol';
import {ERC721Holder} from '@openzeppelin-contracts-5.6.0-rc.1/token/ERC721/utils/ERC721Holder.sol';
import {ReentrancyGuard} from '@openzeppelin-contracts-5.6.0-rc.1/utils/ReentrancyGuard.sol';

/// @title CrossChainWrapper
/// @notice Escrows and settles one local leg of a v1.1 cross-chain swap.
/// @dev Commits must arrive atomically from the authorization boundary named by the terms.
///      Claims and reclaims are permissionless because terms fix their recipients. Wallet-mode
///      provenance is not factory-checked here; the signed principal address is the trust boundary.
contract CrossChainWrapper is ICommitAuthorizationReceiver, ERC721Holder, ERC1155Holder, ReentrancyGuard {
  using AssetCustody for AssetCustody.Layout;
  using AssetSupport for SideTerms;
  using CrossChainStateMachine for CrossChainStateMachine.Layout;
  using Settlement for CrossChainStateMachine.Layout;

  error ZeroConfiguration();
  error InvalidWrapperMode();
  error InvalidLocalChain();
  error CommitWindowClosed();

  event Committed(bytes32 indexed tradeId, bytes32 indexed lock, SideTag indexed side, address principal);
  event BobCommitSecretPublished(bytes32 indexed tradeId, bytes32 bobCommitSecret);
  event Claimed(bytes32 indexed tradeId, bytes32 indexed lock, SideTag indexed side);
  event Reclaimed(bytes32 indexed tradeId, bytes32 indexed lock, SideTag indexed side);

  /// @notice Gateway trusted to authenticate RegisteredDirect commit signatures.
  address public immutable DIRECT_AUTHORIZATION;
  /// @notice Admission allowlist consulted only when new assets enter custody.
  IAssetSupportRegistry public immutable ASSET_SUPPORT;
  /// @notice Non-upgradeable implementation cloned once for every committed local leg.
  address public immutable HTLC_IMPLEMENTATION;

  CrossChainStateMachine.Layout private states;
  AssetCustody.Layout private custody;
  mapping(bytes32 recordKey => address htlc) private htlcs;

  /// @notice Configures the immutable direct authorization gateway and asset allowlist.
  constructor(address directAuthorization, IAssetSupportRegistry assetSupport, address htlcImplementation) {
    if (directAuthorization == address(0) || address(assetSupport) == address(0) || htlcImplementation.code.length == 0)
    {
      revert ZeroConfiguration();
    }
    DIRECT_AUTHORIZATION = directAuthorization;
    ASSET_SUPPORT = assetSupport;
    HTLC_IMPLEMENTATION = htlcImplementation;
  }

  /// @notice Validates authorization evidence, the Bob-commit gate, and funding, then escrows one leg.
  /// @dev Both cross-chain commits provide the same preimage; the party-side commit publishes it
  ///      through BobCommitSecretPublished so the counterparty can progress from on-chain data.
  function receiveAuthorizedCommit(
    ProtocolTerms calldata terms,
    bool party,
    bytes32 lock,
    bytes32 bobCommitSecret,
    VerifiedCommitAuthorization calldata evidence,
    bytes calldata
  ) external payable nonReentrant {
    // Copy calldata once, then validate the complete cross-chain term set.
    ProtocolTerms memory validatedTerms = terms;
    _validate(validatedTerms);
    // Select the funded leg and require this deployment to be its named chain.
    SideTerms memory side = party ? validatedTerms.partySide : validatedTerms.counterpartySide;
    if (side.chainId != block.chainid) revert InvalidLocalChain();
    // Reject token contracts that have not passed the custody compatibility policy.
    side.requireSupported(ASSET_SUPPORT);
    // Bind gateway evidence to the exact trade, wrapper, leg, state, and fresh action nonce.
    bytes32 trade = CommitAuthorization.validate(
      validatedTerms, party, DIRECT_AUTHORIZATION, address(this), lock, msg.sender, evidence, block.timestamp
    );
    // Prove knowledge of Bob commit secret before either cross-chain leg can be funded.
    ProgressionGate.validate(validatedTerms, bobCommitSecret);
    // Treat the commitment deadline as an exclusive upper bound.
    if (block.timestamp >= side.commitmentDeadline) revert CommitWindowClosed();

    // Advance state before interacting with any asset contract.
    SideTag tag = ProtocolHashing.sideTag(party);
    states.commit(trade, lock, tag);
    // Pull the exact signed assets and account for the forwarded native value.
    custody.collect(side, msg.value);
    emit Committed(trade, lock, tag, side.principal);
    // Alice party commit is the on-chain publication point for Bob commit secret.
    if (party) emit BobCommitSecretPublished(trade, bobCommitSecret);
  }

  /// @notice Permissionlessly claims the selected local leg to its fixed recipient.
  function claim(ProtocolTerms calldata terms, bool party, bytes32 lock, bytes32 secret) external nonReentrant {
    // Settlement validates the preimage and window, advances state, then releases custody.
    bytes32 trade = states.claimCrossChain(custody, terms, party, lock, secret, block.timestamp);
    emit Claimed(trade, lock, ProtocolHashing.sideTag(party));
  }

  /// @notice Permissionlessly reclaims the selected local leg to its fixed reclaim recipient.
  function reclaim(ProtocolTerms calldata terms, bool party, bytes32 lock) external nonReentrant {
    // Reclaim validates the release time, advances state, then returns custody.
    bytes32 trade = states.reclaimCrossChain(custody, terms, party, lock, block.timestamp);
    emit Reclaimed(trade, lock, ProtocolHashing.sideTag(party));
  }

  /// @notice Returns the state of the selected leg for these exact terms and lock.
  function state(ProtocolTerms calldata terms, bool party, bytes32 lock) external view returns (CrossChainLegState) {
    return states.state(ProtocolHashing.tradeId(terms), lock, ProtocolHashing.sideTag(party));
  }

  /// @notice Returns the deployed custody contract for one exact local leg, or zero before commit.
  function htlcOf(ProtocolTerms calldata terms, bool party, bytes32 lock) external view returns (address) {
    bytes32 trade = ProtocolHashing.tradeId(terms);
    return htlcs[HTLCDeployer.recordKey(trade, lock, ProtocolHashing.sideTag(party))];
  }

  /// @notice Predicts the deterministic custody address for one exact local leg.
  function predictHTLC(ProtocolTerms calldata terms, bool party, bytes32 lock) external view returns (address) {
    return HTLCDeployer.predict(
      HTLC_IMPLEMENTATION, address(this), ProtocolHashing.tradeId(terms), lock, ProtocolHashing.sideTag(party)
    );
  }

  /// @notice Returns aggregate custody reserved for one asset identity.
  function reserved(Asset calldata asset) external view returns (uint256) {
    return custody.reservedAmount(asset);
  }

  function _validate(ProtocolTerms memory terms) private pure {
    if (ProtocolHashing.mode(terms) != WrapperMode.CrossChain) revert InvalidWrapperMode();
    ProtocolHashing.validateTerms(terms);
  }
}
