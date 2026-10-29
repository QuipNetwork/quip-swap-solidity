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
 * `deployments.json` is GENERATED from `script/DeployConstants.sol` by
 * `make sync-registry` — chains, labels and the wallet factory are compiled
 * into the deploy scripts, and the address is `predictOmnibus(label)`. It is
 * not hand-edited; `make verify-omnibus` and the CI test
 * `Constants_predictOmnibus.test_predictOmnibus_registryMatchesDeployConstants`
 * both re-derive it and fail on divergence.
 *
 * WHY `deployed` EXISTS. Every other field is derivable, and a CREATE3 address
 * is predictable whether or not anything was ever deployed to it — so a purely
 * derived registry would happily name addresses with no code. `deployed` is set
 * by `make sync-registry` run against a live RPC, and it means more than "has
 * code": sync also checks the live `WALLET_FACTORY` immutable against the one
 * the scripts compile in, because a CREATE3 address ignores init code and so
 * proves nothing about WHAT is deployed at it. That check is why Base Sepolia
 * and OP Sepolia currently read `false` — an Omnibus is live at their address,
 * but wired to a non-canonical WalletFactory, so the wallet commit route
 * rejects otherwise-valid wallets with `NotQuipWallet`. {@link resolveDeployment}
 * refuses to hand out a row like that; {@link registryRows} still exposes it.
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
   * Whether the Omnibus this build describes is live on that chain — code
   * present AND its `WALLET_FACTORY` immutable matching the one the deploy
   * scripts compile in. Absent on caller-supplied overrides, which are trusted
   * by definition.
   */
  readonly deployed?: boolean
  /**
   * The quip WalletFactory proxy baked into this Omnibus's immutables. Present
   * on every registry row. The wallet commit route calls `commitmentOf` on it, so
   * a deployment wired to the wrong factory rejects otherwise-valid wallets
   * with `NotQuipWallet` — and cannot be repaired without a redeploy.
   */
  readonly walletFactory?: Address
}

const toDeployment = (row: (typeof registry.deployments)[number]): OmnibusDeployment => ({
  chainId: BigInt(row.chainId),
  omnibusAddress: row.omnibus as Address,
  version: row.version,
  walletFactory: row.walletFactory as Address,
  deployed: row.deployed,
})

/**
 * EVERY row in the registry, including chains where nothing usable is live.
 *
 * Use this to inspect or report on the deployment landscape. For picking an
 * address to transact against, use {@link resolveDeployment}, which refuses
 * rows that are not live.
 */
export const registryRows: readonly OmnibusDeployment[] = registry.deployments.map(toDeployment)

/**
 * Live deployments, keyed by chain id — the rows with `deployed: true`.
 *
 * To add or move a chain: edit `script/DeployConstants.sol`, deploy, then run
 * `make sync-registry`. No code change here.
 */
export const knownDeployments: ReadonlyMap<bigint, OmnibusDeployment> = new Map(
  registryRows.filter(row => row.deployed).map(row => [row.chainId, row]),
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
    // Distinguish "we have never heard of this chain" from "we know this chain
    // and what is deployed there is not usable" — the second is a far more
    // actionable message, and it is the case that actually bites.
    const recorded = registryRows.find(row => row.chainId === chainId)
    throw new QuipSwapError({
      code: 'UNKNOWN_DEPLOYMENT',
      message:
        recorded === undefined
          ? `No Omnibus deployment is recorded for chain ${chainId} and no override was provided. ` +
            'Supply {chainId, omnibusAddress} explicitly. Addresses are never guessed: a CREATE3 address ignores ' +
            'init code, so a deployment must be confirmed on-chain before it is trusted.'
          : `Chain ${chainId} is recorded (version ${recorded.version}, address ${recorded.omnibusAddress}) but is ` +
            'NOT live: either nothing is deployed there, or the deployed Omnibus does not use the wallet factory ' +
            `this build expects (${recorded.walletFactory}). It needs a redeploy. Pass an explicit override if you ` +
            'intend to use it anyway.',
      details: {chainId, knownChains: [...knownDeployments.keys()], recorded},
    })
  }
  return known
}
