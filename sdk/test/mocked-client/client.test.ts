/**
 * Mocked-Viem-client orchestration tests.
 *
 * These tests verify the SDK client's ORCHESTRATION only: which contract
 * function is selected, the exact arguments and msg.value, the read-before-
 * write ordering (fee and vaultIdOf), simulate-before-write, and that every
 * preflight rejection happens BEFORE any transaction is submitted.
 *
 * They deliberately do NOT prove ABI-encoding equivalence with Solidity —
 * `test/integration/differential.test.ts` does that against the deployed
 * harnesses.
 *
 * The mock clients are plain objects with a single test-only cast
 * (`as unknown as PublicClient`) — the minimum needed to satisfy Viem's
 * client types in a mock.
 */
import type {Address, PublicClient, WalletClient} from 'viem'
import {beforeEach, describe, expect, it} from 'vitest'
import {createOmnibusClient} from '../../src/client.js'
import type {OmnibusClient} from '../../src/client.js'
import {QuipSwapError} from '../../src/errors.js'
import {digestTermsCanonically, generateLock} from '../../src/hashing.js'
import {
  aliceTerms,
  AT_PROPOSER_CLAIM,
  AT_PROPOSER_COMMIT,
  AT_PROPOSER_RECLAIM,
  bobTerms,
  CHAIN_A,
  CHAIN_B,
  FOUNDRY_LOCK,
  FOUNDRY_SECRET,
} from '../helpers/fixtures.js'

const OMNIBUS: Address = '0x9990000000000000000000000000000000000999'
const FACTORY: Address = '0x8880000000000000000000000000000000000888'
const SENDER: Address = '0x7770000000000000000000000000000000000777'
const TX_HASH = `0x${'ab'.repeat(32)}` as const

const alice = aliceTerms(CHAIN_A) // proposer (local on chain A)
const bob = bobTerms(CHAIN_A) // taker, same chain

/** A recorded call log shared by the mock public and wallet clients. */
interface CallLog {
  /** Ordered operation names, e.g. 'read:commitmentFee', 'simulate:commit', 'write'. */
  readonly sequence: string[]
  /** Captured simulateContract arguments. */
  readonly simulations: Record<string, unknown>[]
  /** Captured writeContract requests. */
  readonly writes: unknown[]
}

interface MockSetup {
  readonly log: CallLog
  readonly client: OmnibusClient
}

/** Builds a mocked client pair around configurable chain state. */
function setup(
  options: {
    chainId?: bigint
    timestamp?: bigint
    fee?: bigint
    vaultId?: `0x${string}`
    termsHash?: `0x${string}`
    posted?: boolean
    withWallet?: boolean
  } = {},
): MockSetup {
  const {
    chainId = CHAIN_A,
    timestamp = AT_PROPOSER_COMMIT,
    fee = 25n,
    vaultId = `0x${'11'.repeat(32)}` as const,
    posted = true,
    withWallet = true,
  } = options
  const termsHash = options.termsHash ?? digestTermsCanonically(alice, bob)

  const log: CallLog = {sequence: [], simulations: [], writes: []}

  const publicClient = {
    getChainId: async () => Number(chainId),
    getBlock: async () => ({timestamp}),
    readContract: async (args: {address: Address; functionName: string}) => {
      log.sequence.push(`read:${args.functionName}`)
      switch (args.functionName) {
        case 'QUIP_FACTORY':
          return FACTORY
        case 'vaultIdOf':
          return vaultId
        case 'commitmentFee':
          return fee
        case 'termsHash':
          return termsHash
        case 'posted':
          return posted
        default:
          throw new Error(`unexpected read: ${args.functionName}`)
      }
    },
    simulateContract: async (args: Record<string, unknown>) => {
      log.sequence.push(`simulate:${String(args['functionName'])}`)
      log.simulations.push(args)
      // tag the returned request so we can prove the SIMULATED request is
      // what gets written, not a re-built one
      return {request: {...args, __simulated: true}}
    },
  } as unknown as PublicClient

  const walletClient = {
    account: {address: SENDER, type: 'json-rpc'},
    writeContract: async (request: unknown) => {
      log.sequence.push('write')
      log.writes.push(request)
      return TX_HASH
    },
  } as unknown as WalletClient

  const client = createOmnibusClient({
    address: OMNIBUS,
    publicClient,
    ...(withWallet ? {walletClient} : {}),
  })
  return {log, client}
}

async function codeOf(promise: Promise<unknown>): Promise<string> {
  try {
    await promise
  } catch (error) {
    if (error instanceof QuipSwapError) return error.code
    throw error
  }
  throw new Error('expected the promise to reject with a QuipSwapError')
}

/** The 7-field tuple shape the ABI expects for Terms. */
function expectAbiTerms(actual: unknown, expected: typeof alice): void {
  expect(actual).toEqual({
    chainId: expected.chainId,
    reclaimRecipient: expected.reclaimRecipient,
    recipient: expected.recipient,
    commitmentDeadline: expected.commitmentDeadline,
    claimDeadline: expected.claimDeadline,
    reclaimRelease: expected.reclaimRelease,
    assets: expected.assets.map(a => ({assetType: a.assetType, target: a.target, id: a.id, amount: a.amount})),
  })
}

describe('commit orchestration', () => {
  let mocks: MockSetup

  beforeEach(() => {
    mocks = setup()
  })

  it('selects the commit function with 7-field Terms tuples and exact msg.value', async () => {
    const hash = await mocks.client.commit({lock: FOUNDRY_LOCK, party: alice, counterparty: bob})
    expect(hash).toBe(TX_HASH)

    const sim = mocks.log.simulations[0] as {
      functionName: string
      args: [unknown, unknown, unknown]
      value: bigint
      address: Address
      account: Address
    }
    expect(sim.functionName).toBe('commit')
    expect(sim.address).toBe(OMNIBUS)
    expect(sim.args[0]).toBe(FOUNDRY_LOCK)
    expectAbiTerms(sim.args[1], alice)
    expectAbiTerms(sim.args[2], bob)
    // exact value: totalNative(alice) = 1 ether + fee 25 wei — never more, never less
    expect(sim.value).toBe(10n ** 18n + 25n)
  })

  it('reads commitmentFee and vaultIdOf BEFORE simulating, and simulates BEFORE writing', async () => {
    await mocks.client.commit({lock: FOUNDRY_LOCK, party: alice, counterparty: bob})
    const seq = mocks.log.sequence
    expect(seq.indexOf('read:vaultIdOf')).toBeLessThan(seq.indexOf('simulate:commit'))
    expect(seq.indexOf('read:commitmentFee')).toBeLessThan(seq.indexOf('simulate:commit'))
    expect(seq.indexOf('simulate:commit')).toBeLessThan(seq.indexOf('write'))
  })

  it('passes the SIMULATED request into writeContract', async () => {
    await mocks.client.commit({lock: FOUNDRY_LOCK, party: alice, counterparty: bob})
    expect((mocks.log.writes[0] as {__simulated: boolean}).__simulated).toBe(true)
  })

  it('rejects a missing wallet client with a clear error', async () => {
    const readOnly = setup({withWallet: false})
    expect(await codeOf(readOnly.client.commit({lock: FOUNDRY_LOCK, party: alice, counterparty: bob}))).toBe(
      'MISSING_WALLET_CLIENT',
    )
    expect(readOnly.log.writes).toHaveLength(0)
  })

  it('rejects a non-QuipWallet sender BEFORE submission', async () => {
    const gated = setup({vaultId: `0x${'00'.repeat(32)}`})
    expect(await codeOf(gated.client.commit({lock: FOUNDRY_LOCK, party: alice, counterparty: bob}))).toBe(
      'NOT_QUIP_WALLET',
    )
    expect(gated.log.sequence).not.toContain('simulate:commit')
    expect(gated.log.writes).toHaveLength(0)
  })

  it('rejects a chain mismatch on the PARTY side before submission', async () => {
    // commit must be sent on the party's chain; connected chain is B here
    const wrongChain = setup({chainId: CHAIN_B})
    expect(await codeOf(wrongChain.client.commit({lock: FOUNDRY_LOCK, party: alice, counterparty: bob}))).toBe(
      'CHAIN_ID_MISMATCH',
    )
    expect(wrongChain.log.writes).toHaveLength(0)
  })

  it('allows a REMOTE counterparty chain (cross-chain commit)', async () => {
    const crossBob = bobTerms(CHAIN_B)
    await expect(mocks.client.commit({lock: FOUNDRY_LOCK, party: alice, counterparty: crossBob})).resolves.toBe(
      TX_HASH,
    )
  })

  it('rejects a commit outside the sender window before submission', async () => {
    // proposer trying to commit AT its deadline (upper bound exclusive)
    const late = setup({timestamp: alice.commitmentDeadline})
    expect(await codeOf(late.client.commit({lock: FOUNDRY_LOCK, party: alice, counterparty: bob}))).toBe(
      'WINDOW_VIOLATED',
    )
    expect(late.log.writes).toHaveLength(0)
  })

  it('explains a taker commit attempted before the window opens', async () => {
    // taker (bob) committing during the proposer's window — too early
    try {
      await mocks.client.commit({lock: FOUNDRY_LOCK, party: bob, counterparty: alice})
      expect.unreachable()
    } catch (error) {
      expect(error).toBeInstanceOf(QuipSwapError)
      expect((error as QuipSwapError).code).toBe('WINDOW_VIOLATED')
      expect((error as QuipSwapError).message).toContain('has not opened yet')
    }
  })
})

describe('claim orchestration', () => {
  it('selects the claim function with the secret and 7-field tuples', async () => {
    const mocks = setup({timestamp: AT_PROPOSER_CLAIM})
    await mocks.client.claim({secret: FOUNDRY_SECRET, party: alice, counterparty: bob})
    const sim = mocks.log.simulations[0] as {functionName: string; args: [unknown, unknown, unknown]; value?: bigint}
    expect(sim.functionName).toBe('claim')
    expect(sim.args[0]).toBe(FOUNDRY_SECRET)
    expectAbiTerms(sim.args[1], alice)
    expectAbiTerms(sim.args[2], bob)
    expect(sim.value).toBeUndefined() // claim is not payable
  })

  it('derives the lock from the secret for on-chain state verification', async () => {
    const mocks = setup({timestamp: AT_PROPOSER_CLAIM})
    await mocks.client.claim({secret: FOUNDRY_SECRET, party: alice, counterparty: bob})
    // termsHash + posted were read (verifyOnChainState defaults to true)
    expect(mocks.log.sequence).toContain('read:termsHash')
    expect(mocks.log.sequence).toContain('read:posted')
    expect(generateLock(FOUNDRY_SECRET)).toBe(FOUNDRY_LOCK)
  })

  it('rejects when the COUNTERPARTY leg is not local (claim settles the local counterparty leg)', async () => {
    const mocks = setup({timestamp: AT_PROPOSER_CLAIM})
    const remoteBob = bobTerms(CHAIN_B)
    expect(await codeOf(mocks.client.claim({secret: FOUNDRY_SECRET, party: alice, counterparty: remoteBob}))).toBe(
      'CHAIN_ID_MISMATCH',
    )
    expect(mocks.log.writes).toHaveLength(0)
  })

  it('allows a REMOTE party chain (cross-chain claim of the local counterparty leg)', async () => {
    const mocks = setup({timestamp: AT_PROPOSER_CLAIM, termsHash: digestTermsCanonically(aliceTerms(CHAIN_B), bob)})
    const remoteAlice = aliceTerms(CHAIN_B)
    await expect(mocks.client.claim({secret: FOUNDRY_SECRET, party: remoteAlice, counterparty: bob})).resolves.toBe(
      TX_HASH,
    )
  })

  it('rejects an invalid secret before any RPC interaction', async () => {
    const mocks = setup()
    expect(await codeOf(mocks.client.claim({secret: '0x12' as never, party: alice, counterparty: bob}))).toBe(
      'INVALID_HEX32',
    )
    expect(mocks.log.sequence).toHaveLength(0)
  })

  it('rejects a claim outside the claimant window before submission', async () => {
    const mocks = setup({timestamp: AT_PROPOSER_COMMIT}) // before the claim window opens
    expect(await codeOf(mocks.client.claim({secret: FOUNDRY_SECRET, party: alice, counterparty: bob}))).toBe(
      'WINDOW_VIOLATED',
    )
    expect(mocks.log.writes).toHaveLength(0)
  })

  it('rejects when the on-chain termsHash mismatches (preflight TermsMismatch)', async () => {
    const mocks = setup({timestamp: AT_PROPOSER_CLAIM, termsHash: `0x${'99'.repeat(32)}`})
    expect(await codeOf(mocks.client.claim({secret: FOUNDRY_SECRET, party: alice, counterparty: bob}))).toBe(
      'TERMS_NOT_ON_CHAIN',
    )
    expect(mocks.log.writes).toHaveLength(0)
  })
})

describe('reclaim orchestration', () => {
  it('selects the reclaim function and validates the release window', async () => {
    const mocks = setup({timestamp: AT_PROPOSER_RECLAIM})
    await mocks.client.reclaim({lock: FOUNDRY_LOCK, party: alice, counterparty: bob})
    const sim = mocks.log.simulations[0] as {functionName: string; args: [unknown, unknown, unknown]}
    expect(sim.functionName).toBe('reclaim')
    expect(sim.args[0]).toBe(FOUNDRY_LOCK)
    expectAbiTerms(sim.args[1], alice)
    expectAbiTerms(sim.args[2], bob)
  })

  it('rejects before the reclaimRelease', async () => {
    const mocks = setup({timestamp: AT_PROPOSER_CLAIM})
    expect(await codeOf(mocks.client.reclaim({lock: FOUNDRY_LOCK, party: alice, counterparty: bob}))).toBe(
      'WINDOW_VIOLATED',
    )
    expect(mocks.log.writes).toHaveLength(0)
  })

  it('rejects a chain mismatch on the PARTY side (the reclaimed leg must be local)', async () => {
    const mocks = setup({timestamp: AT_PROPOSER_RECLAIM, chainId: CHAIN_B})
    expect(await codeOf(mocks.client.reclaim({lock: FOUNDRY_LOCK, party: alice, counterparty: bob}))).toBe(
      'CHAIN_ID_MISMATCH',
    )
    expect(mocks.log.writes).toHaveLength(0)
  })
})

describe('reads', () => {
  it('isQuipWallet resolves QUIP_FACTORY then vaultIdOf', async () => {
    const mocks = setup()
    await expect(mocks.client.isQuipWallet(SENDER)).resolves.toBe(true)
    expect(mocks.log.sequence).toEqual(['read:QUIP_FACTORY', 'read:vaultIdOf'])
  })

  it('isQuipWallet returns false for a zero vaultId', async () => {
    const mocks = setup({vaultId: `0x${'00'.repeat(32)}`})
    await expect(mocks.client.isQuipWallet(SENDER)).resolves.toBe(false)
  })
})
