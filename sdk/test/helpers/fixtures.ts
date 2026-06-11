/**
 * Shared test fixtures.
 *
 * The deadline schedule deliberately mirrors `test/Omnibus/Omnibus.t.sol`
 * (Alice = proposer, Bob = taker) so the TypeScript and Foundry suites stay
 * directly comparable:
 *
 * ```text
 * ALICE_COMMIT(1000) < BOB_COMMIT(2000) < ALICE_CLAIM(3000)
 *   < BOB_CLAIM(4000) < ALICE_RECLAIM(5000) < BOB_RECLAIM(6000)
 * anchors: 500 / 1500 / 2500 / 3500 / 5500 / 6500
 * ```
 *
 * NOT exported from the SDK package — test infrastructure only.
 */
import type {Address} from 'viem'
import {nativeAsset} from '../../src/assets.js'
import type {Asset, Hex32, Terms} from '../../src/types.js'

// well-known dummy actors (not real keys; never used for signing in unit tests)
export const ALICE: Address = '0x00000000000000000000000000000000000a11ce'
export const BOB: Address = '0x0000000000000000000000000000000000000b0b'
export const ALICE_RECIPIENT: Address = '0x000000000000000000000000000000000000a1c1'
export const BOB_RECIPIENT: Address = '0x000000000000000000000000000000000000b0b1'

// canonical interleaved schedule (Alice proposes), as in Omnibus.t.sol
export const ALICE_COMMIT_DEADLINE = 1000n
export const BOB_COMMIT_DEADLINE = 2000n
export const ALICE_CLAIM_DEADLINE = 3000n
export const BOB_CLAIM_DEADLINE = 4000n
export const ALICE_RECLAIM_RELEASE = 5000n
export const BOB_RECLAIM_RELEASE = 6000n

// per-action anchors strictly inside each window, as in Omnibus.t.sol
export const AT_PROPOSER_COMMIT = 500n
export const AT_TAKER_COMMIT = 1500n
export const AT_PROPOSER_CLAIM = 2500n
export const AT_TAKER_CLAIM = 3500n
export const AT_PROPOSER_RECLAIM = 5500n
export const AT_TAKER_RECLAIM = 6500n

export const CHAIN_A = 31_337n
export const CHAIN_B = 31_338n

/**
 * Foundry-suite secret/lock pair, derived with Solidity tooling
 * (`cast keccak`), NOT with the SDK's own hashing:
 *   SECRET = keccak256('secret'); LOCK = keccak256(SECRET-bytes)
 */
export const FOUNDRY_SECRET: Hex32 = '0x65462b0520ef7d3df61b9992ed3bea0c56ead753be7c8b3614e0ce01e4cac41b'
export const FOUNDRY_LOCK: Hex32 = '0x2ed293efa90dd457a302c46949588d43099e0897bccde03115db594d0ba62445'

/** Builds Alice's (proposer) terms on `chainId` with the canonical schedule. */
export function aliceTerms(chainId: bigint, assets: readonly Asset[] = [nativeAsset(10n ** 18n)]): Terms {
  return {
    chainId,
    reclaimRecipient: ALICE,
    recipient: ALICE_RECIPIENT,
    commitmentDeadline: ALICE_COMMIT_DEADLINE,
    claimDeadline: ALICE_CLAIM_DEADLINE,
    reclaimRelease: ALICE_RECLAIM_RELEASE,
    assets,
  }
}

/** Builds Bob's (taker) terms on `chainId` with the canonical schedule. */
export function bobTerms(chainId: bigint, assets: readonly Asset[] = [nativeAsset(2n * 10n ** 18n)]): Terms {
  return {
    chainId,
    reclaimRecipient: BOB,
    recipient: BOB_RECIPIENT,
    commitmentDeadline: BOB_COMMIT_DEADLINE,
    claimDeadline: BOB_CLAIM_DEADLINE,
    reclaimRelease: BOB_RECLAIM_RELEASE,
    assets,
  }
}

/** Returns a copy of `terms` with the given overrides (tests never mutate fixtures). */
export function withOverrides(terms: Terms, overrides: Partial<Terms>): Terms {
  return {...terms, ...overrides}
}
