/**
 * Gas multiplier and prepareTx unit tests (pure — no chain).
 *
 * Covers: the default 1.2x multiplier, clamping to [1.0, 2.0], non-finite
 * fallback, exact 3-decimal bigint math (no float round-trip drift),
 * explicit-gas bypass of estimation and the multiplier, and selective fee
 * forwarding.
 */
import type {PublicClient} from 'viem'
import {describe, expect, it} from 'vitest'
import {QuipSwapError} from '../../src/errors.js'
import {
  applyGasMultiplier,
  buildFeeOverrides,
  DEFAULT_GAS_MULTIPLIER,
  MAX_GAS_MULTIPLIER,
  MIN_GAS_MULTIPLIER,
  preflightBalanceCheck,
  prepareTx,
  resolveGasMultiplier,
} from '../../src/gas.js'

describe('resolveGasMultiplier', () => {
  it('defaults to 1.2', () => {
    expect(DEFAULT_GAS_MULTIPLIER).toBe(1.2)
    expect(resolveGasMultiplier()).toBe(1.2)
    expect(resolveGasMultiplier({})).toBe(1.2)
  })

  it('clamps below the floor: 0.5 -> 1.0', () => {
    expect(MIN_GAS_MULTIPLIER).toBe(1.0)
    expect(resolveGasMultiplier({gasMultiplier: 0.5})).toBe(1.0)
  })

  it('clamps above the ceiling: 5 -> 2.0', () => {
    expect(MAX_GAS_MULTIPLIER).toBe(2.0)
    expect(resolveGasMultiplier({gasMultiplier: 5})).toBe(2.0)
  })

  it('non-finite values fall back to the MIN (no buffer)', () => {
    expect(resolveGasMultiplier({gasMultiplier: Number.NaN})).toBe(1.0)
    expect(resolveGasMultiplier({gasMultiplier: Number.POSITIVE_INFINITY})).toBe(1.0)
    expect(resolveGasMultiplier({gasMultiplier: Number.NEGATIVE_INFINITY})).toBe(1.0)
  })
})

describe('applyGasMultiplier', () => {
  it('default 1.2 multiplier: 100_000n -> 120_000n', () => {
    expect(applyGasMultiplier(100_000n)).toBe(120_000n)
  })

  it('honors exactly 3 decimal places: 1.137 on 1_000_000n -> 1_137_000n', () => {
    expect(applyGasMultiplier(1_000_000n, {gasMultiplier: 1.137})).toBe(1_137_000n)
  })

  it('is exact for large estimates — no float round-trip drift', () => {
    // 10^30 cannot survive a float multiplication losslessly (floats carry
    // 53 bits of mantissa); the scaled-bigint path must be exact
    const huge = 10n ** 30n
    expect(applyGasMultiplier(huge, {gasMultiplier: 1.2})).toBe((huge * 1200n) / 1000n)
    const odd = 10n ** 18n + 1n
    expect(applyGasMultiplier(odd, {gasMultiplier: 1.137})).toBe((odd * 1137n) / 1000n)
  })

  it('clamped multipliers feed the math: 0.5 acts as 1.0 (identity)', () => {
    expect(applyGasMultiplier(123_456n, {gasMultiplier: 0.5})).toBe(123_456n)
  })
})

describe('buildFeeOverrides', () => {
  it('forwards ONLY explicitly-set fee fields (never undefined passthrough)', () => {
    expect(buildFeeOverrides({})).toEqual({})
    expect(buildFeeOverrides({maxFeePerGas: 5n})).toEqual({maxFeePerGas: 5n})
    expect(buildFeeOverrides({maxFeePerGas: 5n, maxPriorityFeePerGas: 1n})).toEqual({
      maxFeePerGas: 5n,
      maxPriorityFeePerGas: 1n,
    })
    expect(buildFeeOverrides({gasPrice: 7n})).toEqual({gasPrice: 7n})
    // crucially: no `undefined`-valued keys that would clobber viem's
    // automatic fee pricing
    expect(Object.keys(buildFeeOverrides({maxFeePerGas: 5n}))).toEqual(['maxFeePerGas'])
  })
})

describe('preflightBalanceCheck', () => {
  const ACCOUNT = '0x7770000000000000000000000000000000000777' as const

  it('is a no-op for required <= 0n — getBalance is never read', async () => {
    const publicClient = {
      getBalance: async () => {
        throw new Error('getBalance must not be called for value-less calls')
      },
    } as unknown as PublicClient
    await expect(preflightBalanceCheck(publicClient, ACCOUNT, 0n)).resolves.toBeUndefined()
  })

  it('throws BALANCE_TOO_LOW with {required, balance} when the value is not covered', async () => {
    const publicClient = {getBalance: async () => 99n} as unknown as PublicClient
    try {
      await preflightBalanceCheck(publicClient, ACCOUNT, 100n)
      expect.unreachable()
    } catch (error) {
      expect(error).toBeInstanceOf(QuipSwapError)
      expect((error as QuipSwapError).code).toBe('BALANCE_TOO_LOW')
      expect((error as QuipSwapError).details).toEqual({required: 100n, balance: 99n})
    }
  })

  it('passes when the balance exactly covers the value', async () => {
    const publicClient = {getBalance: async () => 100n} as unknown as PublicClient
    await expect(preflightBalanceCheck(publicClient, ACCOUNT, 100n)).resolves.toBeUndefined()
  })
})

describe('prepareTx explicit-gas bypass', () => {
  const contractParams = {
    address: '0x9990000000000000000000000000000000000999',
    abi: [],
    functionName: 'claim',
    args: [],
    account: '0x7770000000000000000000000000000000000777',
  } as const

  it('opts.gas is used verbatim — estimation and multiplier are skipped entirely', async () => {
    // a mock that fails loudly if estimation is attempted proves the bypass
    const publicClient = {
      estimateContractGas: async () => {
        throw new Error('estimateContractGas must not be called when opts.gas is set')
      },
      getBalance: async () => 10n ** 24n,
      estimateFeesPerGas: async () => ({maxFeePerGas: 2n, maxPriorityFeePerGas: 1n}),
    } as unknown as PublicClient

    const prepared = await prepareTx({
      publicClient,
      contractParams,
      totalValue: 0n,
      opts: {gas: 777_777n, gasMultiplier: 2.0},
    })
    expect(prepared.gas).toBe(777_777n) // verbatim, NOT 2x-multiplied
  })

  it('nonce is forwarded only when pinned', async () => {
    const publicClient = {
      estimateContractGas: async () => 100_000n,
      getBalance: async () => 10n ** 24n,
      estimateFeesPerGas: async () => ({maxFeePerGas: 2n, maxPriorityFeePerGas: 1n}),
    } as unknown as PublicClient

    const withoutNonce = await prepareTx({publicClient, contractParams, totalValue: 0n})
    expect('nonce' in withoutNonce).toBe(false)
    const withNonce = await prepareTx({publicClient, contractParams, totalValue: 0n, opts: {nonce: 42}})
    expect(withNonce.nonce).toBe(42)
  })
})
