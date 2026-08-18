import {WrapperMode} from './protocol.js'
import type {TimingPolicy} from './protocol.js'

export const BASE_SEPOLIA_CHAIN_ID = 84_532n
export const OP_SEPOLIA_CHAIN_ID = 11_155_420n
export const PROTOTYPE_FINAL_CLAIM_DELAY = 30n * 60n

function policy(partyChainId: bigint, counterpartyChainId: bigint): TimingPolicy {
  return {
    policyVersion: 1n,
    mode: WrapperMode.CrossChain,
    partyChainId,
    counterpartyChainId,
    partyToCounterpartyDelay: PROTOTYPE_FINAL_CLAIM_DELAY,
    counterpartyToPartyDelay: PROTOTYPE_FINAL_CLAIM_DELAY,
  }
}

export const BASE_SEPOLIA_TO_OP_SEPOLIA_POLICY = policy(BASE_SEPOLIA_CHAIN_ID, OP_SEPOLIA_CHAIN_ID)
export const OP_SEPOLIA_TO_BASE_SEPOLIA_POLICY = policy(OP_SEPOLIA_CHAIN_ID, BASE_SEPOLIA_CHAIN_ID)