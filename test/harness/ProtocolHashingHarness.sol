// SPDX-License-Identifier: UNLICENSE
pragma solidity 0.8.33;

import {ProtocolHashing} from '../../src/protocol/ProtocolHashing.sol';
import {ExpectedSourceState, ProtocolTerms, WrapperMode} from '../../src/protocol/ProtocolTypes.sol';

contract ProtocolHashingHarness {
  function exposedMode(ProtocolTerms calldata terms) external pure returns (WrapperMode) {
    return ProtocolHashing.mode(terms);
  }

  function exposedGateTerms(ProtocolTerms calldata terms) external pure returns (ProtocolTerms memory) {
    return ProtocolHashing.gateTerms(terms);
  }

  function exposedGateContextId(ProtocolTerms calldata terms) external pure returns (bytes32) {
    return ProtocolHashing.gateContextId(terms);
  }

  function exposedCommitLock(bytes32 contextId, bytes32 secret) external pure returns (bytes32) {
    return ProtocolHashing.commitLock(contextId, secret);
  }

  function exposedTradeId(ProtocolTerms calldata terms) external pure returns (bytes32) {
    return ProtocolHashing.tradeId(terms);
  }

  function exposedSettlementLock(bytes32 trade, bytes32 secret) external pure returns (bytes32) {
    return ProtocolHashing.settlementLock(trade, secret);
  }

  function exposedAssetHash(ProtocolTerms calldata terms, bool party) external pure returns (bytes32) {
    return ProtocolHashing.assetHash(party ? terms.partySide : terms.counterpartySide);
  }

  function exposedCommitPayloadHash(
    ProtocolTerms calldata terms,
    bool party,
    address verifier,
    address swapAddress,
    bytes32 lock,
    ExpectedSourceState sourceState,
    bytes32 actionNonce,
    uint256 expiry
  ) external pure returns (bytes32) {
    return ProtocolHashing.commitPayloadHash(
      terms, party, verifier, swapAddress, lock, sourceState, actionNonce, expiry
    );
  }

  function exposedValidateTerms(ProtocolTerms calldata terms) external pure {
    ProtocolHashing.validateTerms(terms);
  }

  function exposedAuthorizationNonceKey(
    uint256 chainId,
    address verifier,
    address principal,
    uint256 keyVersion,
    bytes32 nonce
  ) external pure returns (bytes memory) {
    return ProtocolHashing.encodeAuthorizationNonceKey(chainId, verifier, principal, keyVersion, nonce);
  }

  function exposedRegistryNonceKey(
    uint256 chainId,
    address registry,
    address eoa,
    uint8 keyRole,
    uint256 keyVersion,
    bytes32 nonce
  ) external pure returns (bytes memory) {
    return ProtocolHashing.encodeRegistryNonceKey(chainId, registry, eoa, keyRole, keyVersion, nonce);
  }
}
