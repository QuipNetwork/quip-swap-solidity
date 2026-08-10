// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {AssetCustody} from '../../src/AssetCustody.sol';
import {CrossChainStateMachine} from '../../src/CrossChainStateMachine.sol';
import {ProtocolHashing} from '../../src/ProtocolHashing.sol';
import {CrossChainLegState, ProtocolTerms, SameChainState, TimingPolicy} from '../../src/ProtocolTypes.sol';
import {SameChainStateMachine} from '../../src/SameChainStateMachine.sol';
import {Settlement} from '../../src/Settlement.sol';
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
    crossChain.commit(
      trade,
      lock,
      ProtocolHashing.sideTag(party),
      trade,
      ProtocolHashing.assetHash(party ? terms.partySide : terms.counterpartySide)
    );
    custody.collect(party ? terms.partySide : terms.counterpartySide, msg.value);
  }

  function claimCrossChain(
    ProtocolTerms calldata terms,
    TimingPolicy calldata policy,
    bool party,
    bytes32 lock,
    bytes32 secret
  ) external {
    crossChain.claimCrossChain(custody, terms, policy, party, lock, secret, block.timestamp);
  }

  function reclaimCrossChain(
    ProtocolTerms calldata terms,
    TimingPolicy calldata policy,
    bool party,
    bytes32 lock
  ) external {
    crossChain.reclaimCrossChain(custody, terms, policy, party, lock, block.timestamp);
  }

  function crossState(
    ProtocolTerms calldata terms,
    bool party,
    bytes32 lock
  ) external view returns (CrossChainLegState) {
    return crossChain.record(ProtocolHashing.tradeId(terms), lock, ProtocolHashing.sideTag(party)).state;
  }

  function seedSameChainParty(ProtocolTerms calldata terms, bytes32 lock) external payable {
    bytes32 trade = ProtocolHashing.tradeId(terms);
    sameChain.commitParty(
      trade, lock, trade, ProtocolHashing.assetHash(terms.partySide), ProtocolHashing.assetHash(terms.counterpartySide)
    );
    custody.collect(terms.partySide, msg.value);
  }

  function seedSameChainCounterparty(ProtocolTerms calldata terms, bytes32 lock) external payable {
    bytes32 trade = ProtocolHashing.tradeId(terms);
    sameChain.commitCounterparty(
      trade, lock, trade, ProtocolHashing.assetHash(terms.partySide), ProtocolHashing.assetHash(terms.counterpartySide)
    );
    custody.collect(terms.counterpartySide, msg.value);
  }

  function claimSameChain(
    ProtocolTerms calldata terms,
    TimingPolicy calldata policy,
    bytes32 lock,
    bytes32 secret
  ) external {
    sameChain.claimSameChain(custody, terms, policy, lock, secret, block.timestamp);
  }

  function reclaimSameChainParty(ProtocolTerms calldata terms, TimingPolicy calldata policy, bytes32 lock) external {
    sameChain.reclaimSameChainParty(custody, terms, policy, lock, block.timestamp);
  }

  function reclaimSameChainBoth(ProtocolTerms calldata terms, TimingPolicy calldata policy, bytes32 lock) external {
    sameChain.reclaimSameChainBoth(custody, terms, policy, lock, block.timestamp);
  }

  function sameState(ProtocolTerms calldata terms, bytes32 lock) external view returns (SameChainState) {
    return sameChain.record(ProtocolHashing.tradeId(terms), lock).state;
  }
}
