/**
 * Gas estimation, safety-buffered gas limits, fee overrides, and the
 * balance preflight shared by every write method.
 *
 * Why a buffer at all: unused gas is refunded, so over-providing the gas
 * LIMIT costs nothing at execution. Its purpose is preventing out-of-gas
 * failures from state drift between estimation and inclusion — which
 * matters in this protocol because writes happen inside closing time
 * windows, and an OOG'd claim near a window boundary may be unrecoverable.
 *
 * `prepareTx` replaces the previous `simulateContract` step: viem's
 * `estimateContractGas` executes the call node-side, so contract reverts
 * still surface BEFORE submission (decoded into `CONTRACT_REVERT` with
 * `contractErrorName`), and the returned estimate feeds the buffered gas
 * limit. The balance preflight runs FIRST and checks the bare call value
 * only — gas funding is deliberately not preflighted.
 */
import {BaseError, ContractFunctionRevertedError} from 'viem'
import type {Abi, Address, PublicClient} from 'viem'
import {QuipSwapError, wrapContractError} from './errors.js'

/** Default gas-limit safety multiplier: a 20% margin over the node's estimate. */
export const DEFAULT_GAS_MULTIPLIER = 1.2
/** Multiplier floor; anything below 1.0 risks out-of-gas by construction. */
export const MIN_GAS_MULTIPLIER = 1.0
/** Multiplier ceiling; caps the damage of a misconfigured value. */
export const MAX_GAS_MULTIPLIER = 2.0

/**
 * Per-transaction options accepted by every write method (`commit`,
 * `claim`, `reclaim`, and all `admin.*` writes). All fields optional;
 * everything unset falls back to viem's automatic behavior.
 */
export interface TxOptions {
  /**
   * Explicit gas limit. When set, gas estimation AND the multiplier are
   * skipped entirely — the value is used verbatim.
   */
  readonly gas?: bigint
  /**
   * Gas-limit safety multiplier: `gas = floor(estimate * multiplier)`,
   * computed with bigint-safe 3-decimal math (never a bigint×float
   * multiplication). Defaults to {@link DEFAULT_GAS_MULTIPLIER}; clamped
   * to [{@link MIN_GAS_MULTIPLIER}, {@link MAX_GAS_MULTIPLIER}];
   * non-finite values fall back to the MIN (no buffer).
   */
  readonly gasMultiplier?: number
  /** EIP-1559 total fee ceiling per gas, in wei (exclusive with `gasPrice`). */
  readonly maxFeePerGas?: bigint
  /** EIP-1559 priority tip per gas, in wei (exclusive with `gasPrice`). */
  readonly maxPriorityFeePerGas?: bigint
  /** Legacy gas price, in wei, for non-EIP-1559 chains (exclusive with the two fields above). */
  readonly gasPrice?: bigint
  /** Pin the transaction nonce; by default viem fetches the next nonce. */
  readonly nonce?: number
  /**
   * Skips the stage-1 BALANCE preflight ONLY (the bare-call-value check
   * that runs before gas estimation; see {@link preflightBalanceCheck}).
   * The protocol preflights (windows, pairing, quip-wallet gate, chain id,
   * lock state) ALWAYS run — they are correctness checks, not robustness
   * checks.
   */
  readonly skipPreflightChecks?: boolean
}

/**
 * Resolves the effective gas multiplier from {@link TxOptions}.
 *
 * Rules (deterministic, inspectable by tests and callers):
 * - unset → {@link DEFAULT_GAS_MULTIPLIER}
 * - non-finite (`NaN`, `±Infinity`) → {@link MIN_GAS_MULTIPLIER} (no buffer)
 * - otherwise clamped into [{@link MIN_GAS_MULTIPLIER}, {@link MAX_GAS_MULTIPLIER}]
 *
 * @param opts - The caller's transaction options (only `gasMultiplier` is read).
 * @returns The clamped multiplier that {@link applyGasMultiplier} will use.
 */
export function resolveGasMultiplier(opts: TxOptions = {}): number {
  const requested = opts.gasMultiplier ?? DEFAULT_GAS_MULTIPLIER
  if (!Number.isFinite(requested)) return MIN_GAS_MULTIPLIER
  return Math.min(MAX_GAS_MULTIPLIER, Math.max(MIN_GAS_MULTIPLIER, requested))
}

/**
 * Applies the resolved safety multiplier to a gas estimate.
 *
 * Bigint-safe and deterministic: the multiplier is rounded to exactly
 * 3 decimal places by integer scaling — a bigint is never multiplied by a
 * float, so large estimates cannot pick up float round-trip drift:
 *
 * ```ts
 * const scaled = Math.round(multiplier * 1000)
 * gas = (estimate * BigInt(scaled)) / 1000n
 * ```
 *
 * @param estimate - The node's gas estimate (from `estimateContractGas`).
 * @param opts - Transaction options; see {@link resolveGasMultiplier}.
 * @returns The buffered gas limit, `floor(estimate * multiplier)`.
 */
export function applyGasMultiplier(estimate: bigint, opts: TxOptions = {}): bigint {
  const scaled = Math.round(resolveGasMultiplier(opts) * 1000)
  return (estimate * BigInt(scaled)) / 1000n
}

/**
 * The fee fields forwarded to `writeContract` — containing ONLY the fields
 * the caller explicitly set, so viem's automatic fee pricing keeps working
 * for everything unset. `undefined` fee fields are never passed through.
 */
export interface FeeOverrides {
  readonly maxFeePerGas?: bigint
  readonly maxPriorityFeePerGas?: bigint
  readonly gasPrice?: bigint
}

/**
 * Builds the {@link FeeOverrides} object from caller options.
 *
 * @param opts - Transaction options.
 * @returns An object with only the explicitly-set fee fields present.
 */
export function buildFeeOverrides(opts: TxOptions = {}): FeeOverrides {
  return {
    ...(opts.maxFeePerGas !== undefined ? {maxFeePerGas: opts.maxFeePerGas} : {}),
    ...(opts.maxPriorityFeePerGas !== undefined ? {maxPriorityFeePerGas: opts.maxPriorityFeePerGas} : {}),
    ...(opts.gasPrice !== undefined ? {gasPrice: opts.gasPrice} : {}),
  }
}

/** The contract call being prepared (the exact params `estimateContractGas` receives). */
export interface PrepareTxContractParams {
  readonly address: Address
  readonly abi: Abi
  readonly functionName: string
  readonly args?: readonly unknown[]
  /** Native value attached to the call (payable functions only). */
  readonly value?: bigint
  /** The sender address — estimation and the balance preflight both use it. */
  readonly account: Address
}

/** Arguments for {@link prepareTx}. */
export interface PrepareTxArgs {
  readonly publicClient: PublicClient
  readonly contractParams: PrepareTxContractParams
  /**
   * The total native value the sender must pay for the call itself, in wei
   * — for commit exactly `totalNative(party) + commitmentFee`; `0n` for
   * claim/reclaim/admin. The balance preflight checks this bare value only
   * (gas funding is deliberately not preflighted — see
   * {@link preflightBalanceCheck}); value-less calls skip the check.
   */
  readonly totalValue: bigint
  readonly opts?: TxOptions
}

/** The prepared transaction fields, ready to spread into `writeContract`. */
export interface PreparedTx {
  /** The gas limit to submit with (buffered unless `opts.gas` was set). */
  readonly gas: bigint
  /** Only the caller's explicitly-set fee fields (see {@link FeeOverrides}). */
  readonly fees: FeeOverrides
  /** Present only when the caller pinned a nonce. */
  readonly nonce?: number
}

/** True when the error chain contains a decodable contract revert. */
function isContractRevert(error: unknown): boolean {
  return error instanceof BaseError && error.walk(e => e instanceof ContractFunctionRevertedError) !== null
}

/**
 * Throws `BALANCE_TOO_LOW` if the account's balance is below `required`.
 *
 * No-op when `required <= 0n` — value-less calls (claim/reclaim/admin)
 * have no balance preflight; their send-time funds failures are mapped to
 * `BALANCE_TOO_LOW` in `submitWrite` (see client.ts). Only the bare call
 * value is checked: gas funding is deliberately NOT preflighted (it is the
 * wallet application's concern in the WalletConnect flow).
 *
 * @param publicClient - The Viem public client to read the balance through.
 * @param account - The sender whose balance is checked.
 * @param required - The native value (wei) the call itself must carry.
 * @throws QuipSwapError `BALANCE_TOO_LOW` (with `{required, balance}` in
 *   details) when the balance cannot cover `required`.
 */
export async function preflightBalanceCheck(
  publicClient: PublicClient,
  account: Address,
  required: bigint,
): Promise<void> {
  if (required <= 0n) return
  const balance = await publicClient.getBalance({address: account})
  if (balance < required) {
    throw new QuipSwapError({
      code: 'BALANCE_TOO_LOW',
      message: `Sender ${account} holds ${balance} wei but the call requires ${required} wei of value`,
      details: {required, balance},
    })
  }
}

/**
 * Prepares a write: balance preflight, then gas estimation (or an explicit
 * limit) with the safety multiplier.
 *
 * Stage order:
 * 1. **Balance preflight** (unless `opts.skipPreflightChecks`) — BEFORE
 *    estimation, bare `totalValue` only ({@link preflightBalanceCheck}).
 *    Running it first fixes a masking bug by construction: any sender
 *    reaching estimation already covers the value, and viem attaches no
 *    gas price to `eth_estimateGas`, so the node cannot fail estimation on
 *    funds — insufficient funds can no longer masquerade as
 *    `GAS_ESTIMATION_FAILED`.
 * 2. **Gas** — explicit `opts.gas` is used verbatim (no estimation, no
 *    multiplier). Otherwise `publicClient.estimateContractGas` runs the
 *    call node-side, so a contract revert surfaces HERE, decoded into a
 *    `CONTRACT_REVERT` error with `contractErrorName` — this stage is the
 *    pre-submission revert check that replaced `simulateContract` — and
 *    the estimate is buffered by {@link applyGasMultiplier}.
 *
 * @param args - See {@link PrepareTxArgs}.
 * @returns The {@link PreparedTx} to spread into `writeContract`.
 * @throws QuipSwapError `BALANCE_TOO_LOW` (with `{required, balance}` in
 *   details) when the sender cannot cover the call value;
 *   `CONTRACT_REVERT` (with `contractErrorName`) when the call would
 *   revert; `GAS_ESTIMATION_FAILED` when estimation fails for a non-revert
 *   reason (network error, bad params).
 * @example
 * ```ts
 * const prepared = await prepareTx({publicClient, contractParams, totalValue: 0n, opts})
 * await walletClient.writeContract({...contractParams, gas: prepared.gas, ...prepared.fees})
 * ```
 */
export async function prepareTx(args: PrepareTxArgs): Promise<PreparedTx> {
  const {publicClient, contractParams, totalValue, opts = {}} = args

  // Stage 1: balance — BEFORE estimation, bare totalValue only. This is
  // the one stage skipPreflightChecks disables. Running it first fixes a
  // masking bug by construction: any sender reaching estimation already
  // covers the value, and viem attaches no gas price to eth_estimateGas,
  // so the node cannot fail estimation on funds — insufficient funds can
  // no longer masquerade as GAS_ESTIMATION_FAILED.
  if (opts.skipPreflightChecks !== true) {
    await preflightBalanceCheck(publicClient, contractParams.account, totalValue)
  }

  // Stage 2: gas — explicit opts.gas is used verbatim (no estimation, no
  // multiplier); otherwise estimate (contract reverts surface here,
  // decoded — this is the pre-submission revert check) and buffer.
  let gas: bigint
  if (opts.gas !== undefined) {
    gas = opts.gas
  } else {
    let estimate: bigint
    try {
      estimate = await publicClient.estimateContractGas({
        address: contractParams.address,
        abi: contractParams.abi,
        functionName: contractParams.functionName,
        args: (contractParams.args ?? []) as unknown[],
        account: contractParams.account,
        ...(contractParams.value !== undefined ? {value: contractParams.value} : {}),
        // dynamic functionName + optional payable value cannot satisfy viem's
        // conditional parameter types statically; the runtime shape is
        // exercised by the mocked-client and Anvil integration suites
      } as unknown as Parameters<PublicClient['estimateContractGas']>[0])
    } catch (error) {
      if (isContractRevert(error)) {
        // the call would revert on-chain — same signal simulateContract gave
        throw wrapContractError(error, `Estimating gas for ${contractParams.functionName}`)
      }
      throw new QuipSwapError({
        code: 'GAS_ESTIMATION_FAILED',
        message:
          `Gas estimation for ${contractParams.functionName} failed for a non-revert reason ` +
          '(network error or invalid request); see cause',
        cause: error,
      })
    }
    gas = applyGasMultiplier(estimate, opts)
  }

  return {gas, fees: buildFeeOverrides(opts), ...(opts.nonce !== undefined ? {nonce: opts.nonce} : {})}
}
