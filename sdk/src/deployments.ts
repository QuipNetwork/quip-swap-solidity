/**
 * Typed deployment registry for verified Omnibus deployments.
 *
 * The built-in registry is intentionally EMPTY: no verified production or
 * testnet deployment of the active two-argument-constructor Omnibus
 * (`constructor(address initialOwner, address quipFactory)`) is known to
 * this SDK, and addresses are never invented.
 *
 * Deterministic (CreateX) address derivation is deliberately NOT
 * implemented. The repository's deployment scripts
 * (`script/DeployOmnibus.s.sol`, `script/DeployTestnet.s.sol`) are STALE:
 * they encode constructor args as `abi.encode(OMNIBUS_OWNER)` — one
 * argument — while the active constructor takes two. Any init-code hash or
 * CreateX address derived from those scripts as written is wrong for the
 * active contract. Until the deployer, guarded salt, init-code hash, and
 * BOTH constructor arguments (owner and the real QuipFactory address) are
 * verified, applications must supply addresses explicitly.
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
 * Built-in verified deployments, keyed by chain id.
 *
 * Currently EMPTY by design — see the module doc. Populate only with
 * addresses verified against the active two-argument constructor.
 */
export const knownDeployments: ReadonlyMap<bigint, OmnibusDeployment> = new Map()

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
