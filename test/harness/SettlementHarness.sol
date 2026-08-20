// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {AssetCustody} from '../../src/assets/AssetHandling.sol';
import {ProtocolHashing} from '../../src/protocol/ProtocolHashing.sol';
import {CrossChainLegState, ProtocolTerms, SameChainState} from '../../src/protocol/ProtocolTypes.sol';
import {Settlement} from '../../src/protocol/Settlement.sol';
import {CrossChainStateMachine} from '../../src/protocol/StateMachines.sol';
import {SameChainStateMachine} from '../../src/protocol/StateMachines.sol';
import {ERC1155Holder} from '@openzeppelin-contracts-5.6.0-rc.1/token/ERC1155/utils/ERC1155Holder.sol';
import {ERC721Holder} from '@openzeppelin-contracts-5.6.0-rc.1/token/ERC721/utils/ERC721Holder.sol';

contract SettlementHarness is ERC721Holder, ERC1155Holder {
  using AssetCustody for AssetCustody.Layout;
  using CrossChainStateMachine for CrossChainStateMachine.Layout;
  using SameChainStateMachine for SameChainStateMachine.Layout;
  using Settlement for CrossChainStateMachine.Layout;
  using Settlement for SameChainStateMachine.Layout;

  AssetCustody.Layout private custody;
  CrossChainStateMachine.Layout private crossChain;
  SameChainStateMachine.Layout private sameChain;

  receive() external payable {}

  function seedCrossChain(ProtocolTerms calldata terms, bool party, bytes32 lock) external payable {
    bytes32 trade = ProtocolHashing.tradeId(terms);
    crossChain.commit(trade, lock, ProtocolHashing.sideTag(party));
    custody.collect(party ? terms.partySide : terms.counterpartySide, msg.value);
  }

  function claimCrossChain(ProtocolTerms calldata terms, bool party, bytes32 lock, bytes32 secret) external {
    crossChain.claimCrossChain(custody, terms, party, lock, secret, block.timestamp);
  }

  function reclaimCrossChain(ProtocolTerms calldata terms, bool party, bytes32 lock) external {
    crossChain.reclaimCrossChain(custody, terms, party, lock, block.timestamp);
  }

  function crossState(
    ProtocolTerms calldata terms,
    bool party,
    bytes32 lock
  ) external view returns (CrossChainLegState) {
    return crossChain.state(ProtocolHashing.tradeId(terms), lock, ProtocolHashing.sideTag(party));
  }

  function seedSameChainParty(ProtocolTerms calldata terms, bytes32 lock) external payable {
    bytes32 trade = ProtocolHashing.tradeId(terms);
    sameChain.commitParty(trade, lock);
    custody.collect(terms.partySide, msg.value);
  }

  function seedSameChainCounterparty(ProtocolTerms calldata terms, bytes32 lock) external payable {
    bytes32 trade = ProtocolHashing.tradeId(terms);
    sameChain.commitCounterparty(trade, lock);
    custody.collect(terms.counterpartySide, msg.value);
  }

  function claimSameChain(ProtocolTerms calldata terms, bytes32 lock, bytes32 secret) external {
    sameChain.claimSameChain(custody, terms, lock, secret, block.timestamp);
  }

  function reclaimSameChainParty(ProtocolTerms calldata terms, bytes32 lock) external {
    sameChain.reclaimSameChainParty(custody, terms, lock, block.timestamp);
  }

  function reclaimSameChainBoth(ProtocolTerms calldata terms, bytes32 lock) external {
    sameChain.reclaimSameChainBoth(custody, terms, lock, block.timestamp);
  }

  function sameState(ProtocolTerms calldata terms, bytes32 lock) external view returns (SameChainState) {
    return sameChain.state(ProtocolHashing.tradeId(terms), lock);
  }
}
