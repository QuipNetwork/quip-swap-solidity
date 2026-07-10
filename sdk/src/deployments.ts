/**
 * Typed deployment registry for verified Omnibus deployments.
 *
 * Omnibus is deployed via CREATE3 through the canonical Deployer contract
 * (`script/DeployOmnibus.s.sol`, using solady's `CREATE3.deployDeterministic`).
 * The address derives only from (Deployer contract, salt) — neither
 * chain-specific nor dependent on the broadcasting EOA — so a single
 * deployment has the SAME address on every chain. The registry therefore ships
 * ONE canonical address ({@link OMNIBUS_CREATE3_ADDRESS}) gated to the chain
 * ids where it has been VERIFIED-deployed, plus the existing per-chain override.
 *
 * The address DATA is the single source of truth in `address.json` (imported
 * below). `script/VerifyOmnibus.s.sol` (run `make verify-omnibus`) asserts
 * `address.json` matches the address predicted from (Deployer, salt) — pure
 * offline math, not an on-chain semantic check. A chain id is added to that
 * file's `chains` array ONLY after the deployed contract is confirmed on-chain
 * for it. This module derives its constants from that JSON; activating a
 * deployment is a data-only edit.
 *
 * Derivation is deterministic, but the SDK ships a VERIFIED constant rather
 * than deriving the address at runtime: a CREATE3 address ignores init code,
 * so the contract actually sitting at the computed address must be confirmed
 * to be the correct one-argument-constructor Omnibus
 * (`constructor(address initialOwner)`) before it is
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
 * CREATE3 (via the canonical Deployer contract) derives the address from
 * (Deployer contract, salt) — both chain-independent — so a single Omnibus
 * deployed via `script/DeployOmnibus.s.sol` has the SAME address on every
 * chain.
 *
 * ⚠️ Currently the zero PLACEHOLDER (`address.json`). To activate: set
 * `omnibusAddress` in `address.json` to the real deployed address, run
 * `make verify-omnibus` (offline: confirms it matches the predicted
 * (Deployer, salt) address), confirm on-chain that the correct Omnibus sits
 * there for each target chain (CREATE3 addresses ignore init code, so
 * semantic verification is mandatory), and add those chain ids to `chains`.
 * No code change required.
 */
export const OMNIBUS_CREATE3_ADDRESS = addressData.omnibusAddress as Address

/**
 * Chain ids on which {@link OMNIBUS_CREATE3_ADDRESS} is verified-deployed,
 * sourced from `address.json`'s `chains` array. EMPTY until deployments are
 * confirmed — while empty, {@link resolveDeployment} behaves exactly as the
 * old empty-registry version (throws for every chain without an override).
 * A chain id is added ONLY after `make verify-omnibus` passes on it.
 */
const VERIFIED_DEPLOYMENT_CHAINS: ReadonlySet<bigint> = new Set<bigint>(
  addressData.chains.map(chainId => BigInt(chainId)),
)

/**
 * Built-in verified deployments, keyed by chain id. Derived from
 * {@link OMNIBUS_CREATE3_ADDRESS} + {@link VERIFIED_DEPLOYMENT_CHAINS} so
 * there is a single source of truth. EMPTY until the placeholder address is
 * replaced and chains are enabled (identical behavior to the prior empty
 * registry while empty).
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
