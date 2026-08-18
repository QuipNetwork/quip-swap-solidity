// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {IAssetSupportRegistry} from '../interfaces/IAssetSupportRegistry.sol';
import {ICommitAuthorizationReceiver} from '../interfaces/ICommitAuthorizationReceiver.sol';
import {AssetCustody} from './AssetHandling.sol';
import {AssetSupport} from './AssetHandling.sol';
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

contract SameChainWrapper is ICommitAuthorizationReceiver, ERC721Holder, ERC1155Holder, ReentrancyGuard {
  using AssetCustody for AssetCustody.Layout;
  using AssetSupport for SideTerms;
  using CommitAuthorization for CommitAuthorization.Layout;
  using SameChainStateMachine for SameChainStateMachine.Layout;
  using Settlement for SameChainStateMachine.Layout;

  error ZeroConfiguration();
  error InvalidWrapperMode();
  error InvalidLocalChain();
  error CommitWindowClosed();

  event Committed(bytes32 indexed tradeId, bytes32 indexed lock, SideTag indexed side, address principal);
  event Claimed(bytes32 indexed tradeId, bytes32 indexed lock);
  event Reclaimed(bytes32 indexed tradeId, bytes32 indexed lock);

  address public immutable DIRECT_AUTHORIZATION;
  IAssetSupportRegistry public immutable ASSET_SUPPORT;

  CommitAuthorization.Layout private authorizations;
  SameChainStateMachine.Layout private states;
  AssetCustody.Layout private custody;

  constructor(address directAuthorization, IAssetSupportRegistry assetSupport) {
    if (directAuthorization == address(0) || address(assetSupport) == address(0)) {
      revert ZeroConfiguration();
    }
    DIRECT_AUTHORIZATION = directAuthorization;
    ASSET_SUPPORT = assetSupport;
  }

  function receiveAuthorizedCommit(
    ProtocolTerms calldata terms,
    bool party,
    bytes32 lock,
    bytes32 bobCommitSecret,
    VerifiedCommitAuthorization calldata evidence,
    bytes calldata
  ) external payable nonReentrant {
    _validate(terms);
    SideTerms memory side = party ? terms.partySide : terms.counterpartySide;
    if (side.chainId != block.chainid) revert InvalidLocalChain();
    side.requireSupported(ASSET_SUPPORT);
    CommitAuthorization.PreparedAuthorization memory prepared = authorizations.validate(
      terms, party, DIRECT_AUTHORIZATION, address(this), lock, msg.sender, evidence, block.timestamp
    );
    ProgressionGate.validate(terms, party, bobCommitSecret);
    if (block.timestamp >= side.commitmentDeadline) revert CommitWindowClosed();

    bytes32 trade = ProtocolHashing.tradeId(terms);
    bytes32 partyAssets = ProtocolHashing.assetHash(terms.partySide);
    bytes32 counterpartyAssets = ProtocolHashing.assetHash(terms.counterpartySide);
    if (party) states.commitParty(trade, lock, trade, partyAssets, counterpartyAssets);
    else states.commitCounterparty(trade, lock, trade, partyAssets, counterpartyAssets);
    custody.collect(side, msg.value);
    authorizations.consume(prepared);
    emit Committed(trade, lock, ProtocolHashing.sideTag(party), side.principal);
  }

  function claim(ProtocolTerms calldata terms, bytes32 lock, bytes32 secret) external nonReentrant {
    states.claimSameChain(custody, terms, lock, secret, block.timestamp);
    emit Claimed(ProtocolHashing.tradeId(terms), lock);
  }

  function reclaimParty(ProtocolTerms calldata terms, bytes32 lock) external nonReentrant {
    states.reclaimSameChainParty(custody, terms, lock, block.timestamp);
    emit Reclaimed(ProtocolHashing.tradeId(terms), lock);
  }

  function reclaimBoth(ProtocolTerms calldata terms, bytes32 lock) external nonReentrant {
    states.reclaimSameChainBoth(custody, terms, lock, block.timestamp);
    emit Reclaimed(ProtocolHashing.tradeId(terms), lock);
  }

  function state(ProtocolTerms calldata terms, bytes32 lock) external view returns (SameChainState) {
    return states.record(ProtocolHashing.tradeId(terms), lock).state;
  }

  function reserved(Asset calldata asset) external view returns (uint256) {
    return custody.reservedAmount(asset);
  }

  function _validate(ProtocolTerms memory terms) private pure {
    if (ProtocolHashing.mode(terms) != WrapperMode.SameChain) revert InvalidWrapperMode();
    ProtocolHashing.validateTerms(terms);
  }
}
