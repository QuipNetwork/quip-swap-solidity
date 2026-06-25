/**
 * Typed deployment registry for verified Omnibus deployments.
 *
 * Omnibus is deployed via Create3 (`script/DeployOmnibus.s.sol`), whose
 * address derives only from (deployer, guarded salt, CreateX factory) — none
 * of them chain-specific — so a single deployment has the SAME address on
 * every chain. The registry therefore ships ONE canonical address
 * ({@link OMNIBUS_CREATE3_ADDRESS}) gated to the chain ids where it has been
 * VERIFIED-deployed, plus the existing per-chain override.
 *
 * Derivation is deterministic, but the SDK ships a VERIFIED constant rather
 * than deriving the address at runtime: a Create3 address ignores init code,
 * so the contract actually sitting at the computed address must be confirmed
 * to be the correct two-argument-constructor Omnibus
 * (`constructor(address initialOwner, address quipFactory)`) before it is
 * trusted. A derived-but-unverified address is never returned.
 *
 * Until the canonical address is filled in and chains are enabled, the
 * registry is empty and `resolveDeployment` throws `UNKNOWN_DEPLOYMENT` for
 * every chain without an override — exactly as before. Addresses are never
 * invented or guessed.
 */
import {isAddress, zeroAddress} from 'viem'
import type {Address} from 'viem'
import {QuipSwapError} from './errors.js'

/** A verified Omnibus deployment on one chain. */
export interface OmnibusDeployment {
  /** The chain id the deployment lives on. */
  readonly chainId: bigint
  /** The Omnibus singleton address on that chain. */
  readonly omnibusAddress: Address
}

/**
 * The canonical Create3 Omnibus address.
 *
 * Create3 derives the address from (deployer, guarded salt, CreateX
 * factory) — all chain-independent — so a single Omnibus deployed via
 * `script/DeployOmnibus.s.sol` has the SAME address on every chain.
 *
 * ⚠️ PLACEHOLDER — not yet the real deployed address. Compute it with
 * `CREATEX.computeCreate3Address(guardedSalt(deployer, keccak256(
 * 'quip.network.Omnibus.v1')), CREATEX)` for Quip's deployer, VERIFY the
 * contract actually deployed there is the correct two-arg-constructor
 * Omnibus (Create3 addresses ignore init code, so verification is
 * mandatory), then replace this value and enable the chain ids in
 * {@link VERIFIED_DEPLOYMENT_CHAINS}.
 */
export const OMNIBUS_CREATE3_ADDRESS = '0x0000000000000000000000000000000000000000' as Address // PLACEHOLDER

/**
 * Chain ids on which {@link OMNIBUS_CREATE3_ADDRESS} is verified-deployed.
 * EMPTY until deployments are confirmed — while empty, {@link resolveDeployment}
 * behaves exactly as the old empty-registry version (throws for every chain
 * without an override). Add a chain id ONLY after verifying the address on
 * that chain.
 */
const VERIFIED_DEPLOYMENT_CHAINS: ReadonlySet<bigint> = new Set<bigint>([
  // 8453n,   // Base — enable only when verified
  // 42161n,  // Arbitrum — enable only when verified
])

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
        'Supply {chainId, omnibusAddress} explicitly. Addresses are never guessed, and the repository deploy ' +
        'scripts cannot be used for derivation (they stale-encode a one-argument constructor).',
      details: {chainId},
    })
  }
  return known
}
