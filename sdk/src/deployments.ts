/**
 * Typed deployment registry for verified Omnibus deployments.
 *
 * Omnibus is deployed via CREATE3 through the canonical CreateX factory
 * (`script/DeployOmnibus.s.sol`, pre-deployed at the same address on
 * essentially every EVM chain). The salt is CreateX-permissioned to the ops
 * EOA, so the address derives only from (CreateX, deployer EOA, salt) — not
 * chain-specific — and a single deployment has the SAME address on every
 * chain. The registry therefore ships ONE canonical address
 * ({@link OMNIBUS_CREATE3_ADDRESS}) gated to the chain ids where it has been
 * VERIFIED-deployed, plus the existing per-chain override.
 *
 * The address DATA is the single source of truth in `address.json` (imported
 * below). `script/VerifyOmnibus.s.sol` (run `make verify-omnibus`) asserts
 * `address.json` matches the address predicted from (CreateX, deployer EOA,
 * salt) — pure offline math, not an on-chain semantic check. A chain id is added to that
 * file's `chains` array ONLY after the deployed contract is confirmed on-chain
 * for it. This module derives its constants from that JSON; activating a
 * deployment is a data-only edit.
 *
 * Derivation is deterministic, but the SDK ships a VERIFIED constant rather
 * than deriving the address at runtime: a CREATE3 address ignores init code,
 * so the contract actually sitting at the computed address must be confirmed
 * to be the correct two-argument-constructor Omnibus
 * (`constructor(address initialOwner, address walletFactory)`) before it is
 * trusted. A derived-but-unverified address is never returned.
 *
 * Until the canonical address is filled in and chains are enabled, the
 * registry is empty and `resolveDeployment` throws `UNKNOWN_DEPLOYMENT` for
 * every chain without an override — exactly as before. Addresses are never
 * invented or guessed.
 */
import {isAddress, zeroAddress} from 'viem'
import type {Address} from 'viem'
import addressData from './address.json'
import {QuipSwapError} from './errors.js'

/** A verified Omnibus deployment on one chain. */
export interface OmnibusDeployment {
  /** The chain id the deployment lives on. */
  readonly chainId: bigint
  /** The Omnibus singleton address on that chain. */
  readonly omnibusAddress: Address
}

/**
 * The canonical CREATE3 Omnibus address, sourced from `address.json`.
 *
 * CREATE3 (via the canonical CreateX factory) derives the address from
 * (CreateX, deployer EOA, salt) — all chain-independent — so a single Omnibus
 * deployed via `script/DeployOmnibus.s.sol` has the SAME address on every
 * chain.
 *
 * Sourced from `address.json`, gated to that file's verified `chains`. To
 * enable a NEW chain: run `make verify-omnibus` (offline: confirms the
 * address matches the predicted (CreateX, deployer EOA, salt) address), confirm on-chain
 * that the correct Omnibus sits there (CREATE3 addresses ignore init code,
 * so semantic verification is mandatory), then add the chain id to `chains`.
 * No code change required.
 */
export const OMNIBUS_CREATE3_ADDRESS = addressData.omnibusAddress as Address

/**
 * Chain ids on which {@link OMNIBUS_CREATE3_ADDRESS} is verified-deployed,
 * sourced from `address.json`'s `chains` array. A chain id is added ONLY
 * after `make verify-omnibus` passes on it; on any chain not listed here,
 * {@link resolveDeployment} throws unless an override is supplied.
 */
const VERIFIED_DEPLOYMENT_CHAINS: ReadonlySet<bigint> = new Set<bigint>(
  addressData.chains.map(chainId => BigInt(chainId)),
)

/**
 * Built-in verified deployments, keyed by chain id. Derived from
 * {@link OMNIBUS_CREATE3_ADDRESS} + {@link VERIFIED_DEPLOYMENT_CHAINS} so
 * there is a single source of truth.
 */
export const knownDeployments: ReadonlyMap<bigint, OmnibusDeployment> = new Map(
  [...VERIFIED_DEPLOYMENT_CHAINS].map(chainId => [chainId, {chainId, omnibusAddress: OMNIBUS_CREATE3_ADDRESS}]),
)

/**
 * Resolves the Omnibus address for a chain.
 *
 * Resolution order: an explicit `override` wins; otherwise the built-in
 * {@link knownDeployments} registry is consulted.
 *
 * @param chainId - The target chain id.
 * @param override - Optional application-supplied deployment for this chain.
 * @returns The resolved deployment.
 * @throws QuipSwapError `UNKNOWN_DEPLOYMENT` when no verified deployment
 *   exists and no override was provided, or when the override is malformed
 *   or names a different chain.
 * @example
 * ```ts
 * const {omnibusAddress} = resolveDeployment(8453n, {
 *   chainId: 8453n,
 *   omnibusAddress: '0x...', // your verified deployment
 * })
 * ```
 */
export function resolveDeployment(chainId: bigint, override?: OmnibusDeployment): OmnibusDeployment {
  if (override !== undefined) {
    if (!isAddress(override.omnibusAddress, {strict: false}) || override.omnibusAddress.toLowerCase() === zeroAddress) {
      throw new QuipSwapError({
        code: 'UNKNOWN_DEPLOYMENT',
        message: `Deployment override for chain ${chainId} has an invalid omnibusAddress`,
        details: {override},
      })
    }
    if (override.chainId !== chainId) {
      throw new QuipSwapError({
        code: 'UNKNOWN_DEPLOYMENT',
        message: `Deployment override names chain ${override.chainId} but chain ${chainId} was requested`,
        details: {override, chainId},
      })
    }
    return override
  }
  const known = knownDeployments.get(chainId)
  if (known === undefined) {
    throw new QuipSwapError({
      code: 'UNKNOWN_DEPLOYMENT',
      message:
        `No verified Omnibus deployment is known for chain ${chainId} and no override was provided. ` +
        'Supply {chainId, omnibusAddress} explicitly. Addresses are never guessed: a CREATE3 address ignores ' +
        'init code, so a deployment must be verified on-chain before it is trusted (run `make verify-omnibus`).',
      details: {chainId},
    })
  }
  return known
}
