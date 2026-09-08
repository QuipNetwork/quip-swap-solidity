import {BASE_SEPOLIA_CHAIN_ID, OP_SEPOLIA_CHAIN_ID} from './prototypeTiming.js'
import type {RetryPolicy} from './workflows/trustedCrossChain.js'

export interface PrototypeChainOperatingProfile {
  chainId: bigint
  requiredConfirmations: bigint
  rpcEndpointCount: number
}

export interface PrototypeOperatingProfile {
  chains: readonly PrototypeChainOperatingProfile[]
  pollIntervalMs: number
  staleHeadTimeoutMs: number
  reclaimPollIntervalMs: number
  executorMinimumBalanceWei: bigint
  finalClaimExecutorCount: number
  feeMultipliersBps: readonly bigint[]
}

const CONFIRMATIONS = 12n

export const PROTOTYPE_OPERATING_PROFILE: PrototypeOperatingProfile = Object.freeze({
  chains: Object.freeze([
    Object.freeze({
      chainId: BASE_SEPOLIA_CHAIN_ID,
      requiredConfirmations: CONFIRMATIONS,
      rpcEndpointCount: 2
    }),
    Object.freeze({
      chainId: OP_SEPOLIA_CHAIN_ID,
      requiredConfirmations: CONFIRMATIONS,
      rpcEndpointCount: 2
    }),
  ]),
  pollIntervalMs: 2_000,
  staleHeadTimeoutMs: 30_000,
  reclaimPollIntervalMs: 15_000,
  executorMinimumBalanceWei: 10_000_000_000_000_000n,
  finalClaimExecutorCount: 2,
  feeMultipliersBps: Object.freeze([10_000n, 12_000n, 14_400n]),
})

export function prototypeConfirmations(
  chainId: bigint): bigint {
  const chain = PROTOTYPE_OPERATING_PROFILE.chains.find(candidate => candidate.chainId === chainId)

  if (chain === undefined)
    throw new Error(`unsupported prototype chain: ${chainId}`)

  return chain.requiredConfirmations
}

/** Multipliers are basis points applied by the transaction submitter to its current fee quote. */
export const PROTOTYPE_RETRY_POLICY: RetryPolicy = Object.freeze({
  attempts: PROTOTYPE_OPERATING_PROFILE.feeMultipliersBps.length,
  feeBump: (
    attempt: number): bigint => {
    const multiplier = PROTOTYPE_OPERATING_PROFILE.feeMultipliersBps[attempt]

    if (multiplier === undefined)
      throw new Error(`unsupported prototype retry attempt: ${attempt}`)

    return multiplier
  },
})
