/**
 * Typed deployment registry for Omnibus deployments.
 *
 * Omnibus is deployed via CREATE3 through the canonical CreateX factory
 * (`script/DeployOmnibus.s.sol`, pre-deployed at the same address on
 * essentially every EVM chain). An address derives from (CreateX, the ops
 * deployer EOA, salt) — never from constructor args — so two chains deployed
 * under the same salt VERSION share an address, and a chain that needs a
 * redeploy takes a new version without disturbing the others.
 *
 * That last part is why this is a per-chain table rather than one constant.
 * Testnets churn and mainnet does not; a single canonical address across all
 * chains cannot survive the first testnet-only redeploy.
 *
 * The DATA is the single source of truth in `deployments.json` (imported
 * below), shared with the Solidity tooling via `script/Deployments.sol` so the
 * two cannot disagree. ONE ROW PER CHAIN, overwritten in place on redeploy;
 * history lives in git.
 *
 * `script/VerifyOmnibus.s.sol` (run `make verify-omnibus`) recomputes every
 * row's address from its own `version` label and asserts it matches — pure
 * offline math, no RPC. The same assertion runs in CI as
 * `Constants_predictOmnibus.test_predictOmnibus_matchesRegistry`.
 *
 * WHAT THE REGISTRY DOES NOT PROMISE. A row is arithmetic plus an operator's
 * word that the deploy landed; it is not an on-chain semantic check. A CREATE3
 * address ignores init code, so the address alone says nothing about WHICH
 * Omnibus is there — which is exactly how two testnet rows ended up pointing at
 * an Omnibus wired to the wrong WalletFactory. `walletFactory` is recorded per
 * row for that reason: it is baked in at construction, invisible from the
 * address, and unchangeable afterwards. Check it against the chain before
 * trusting a deployment for the wallet commit route.
 */
import {isAddress, zeroAddress} from 'viem'
import type {Address} from 'viem'
import registry from './deployments.json'
import {QuipSwapError} from './errors.js'

/** A recorded Omnibus deployment on one chain. */
export interface OmnibusDeployment {
  /** The chain id the deployment lives on. */
  readonly chainId: bigint
  /** The Omnibus singleton address on that chain. */
  readonly omnibusAddress: Address
  /**
   * The salt version label the deployment was made under. Present on every
   * registry row; optional only so a caller-supplied override need not invent
   * one.
   */
  readonly version?: string
  /**
   * The quip WalletFactory proxy baked into this Omnibus's immutables. Present
   * on every registry row. The wallet commit route calls `vaultIdOf` on it, so
   * a deployment wired to the wrong factory rejects otherwise-valid wallets
   * with `NotQuipWallet` — and cannot be repaired without a redeploy.
   */
  readonly walletFactory?: Address
}

/**
 * Built-in deployments, keyed by chain id, derived from `deployments.json`.
 *
 * To add or move a chain: deploy, then edit that file. No code change here.
 */
export const knownDeployments: ReadonlyMap<bigint, OmnibusDeployment> = new Map(
  registry.deployments.map(row => [
    BigInt(row.chainId),
    {
      chainId: BigInt(row.chainId),
      omnibusAddress: row.omnibus as Address,
      version: row.version,
      walletFactory: row.walletFactory as Address,
    },
  ]),
)

/**
 * Resolves the Omnibus deployment for a chain.
 *
 * Resolution order: an explicit `override` wins; otherwise the built-in
 * {@link knownDeployments} registry is consulted.
 *
 * @param chainId - The target chain id.
 * @param override - Optional application-supplied deployment for this chain.
 * @returns The resolved deployment.
 * @throws QuipSwapError `UNKNOWN_DEPLOYMENT` when no deployment is recorded and
 *   no override was provided, or when the override is malformed or names a
 *   different chain.
 * @example
 * ```ts
 * const {omnibusAddress, walletFactory} = resolveDeployment(8453n)
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
        `No Omnibus deployment is recorded for chain ${chainId} and no override was provided. ` +
        'Supply {chainId, omnibusAddress} explicitly. Addresses are never guessed: a CREATE3 address ignores ' +
        'init code, so a deployment must be confirmed on-chain before it is trusted (run `make verify-omnibus`).',
      details: {chainId, knownChains: [...knownDeployments.keys()]},
    })
  }
  return known
}
