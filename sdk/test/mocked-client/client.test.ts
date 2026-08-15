/**
 * Mocked-Viem-client orchestration tests.
 *
 * These tests verify the SDK client's ORCHESTRATION only: which contract
 * function is selected, the exact arguments and msg.value, the read-before-
 * write ordering (fee, lock state), estimate-before-write with the buffered
 * gas limit, and that every preflight rejection happens BEFORE any
 * transaction is submitted.
 *
 * They deliberately do NOT prove ABI-encoding equivalence with Solidity —
 * `test/integration/differential.test.ts` does that against the deployed
 * harnesses.
 *
 * The mock clients are plain objects with a single test-only cast
 * (`as unknown as PublicClient`) — the minimum needed to satisfy Viem's
 * client types in a mock.
 */
import {ContractFunctionRevertedError, InsufficientFundsError, encodeErrorResult} from 'viem'
import type {Address, PublicClient, WalletClient} from 'viem'
import {beforeEach, describe, expect, it} from 'vitest'
import {createOmnibusClient} from '../../src/client.js'
import type {OmnibusClient} from '../../src/client.js'
import {buildKeyedSigner} from '../../src/legacy.js'
import type {CommitAuth} from '../../src/legacy.js'
import {QuipSwapError} from '../../src/errors.js'
import {omnibusAbi} from '../../src/generated/omnibusAbi.js'
import {digestTerms, digestTermsCanonically, generateLock} from '../../src/hashing.js'
import {LockState} from '../../src/types.js'
import {claimLog} from '../helpers/logs.js'
import {
  aliceTerms,
  AT_PROPOSER_CLAIM,
  AT_PROPOSER_COMMIT,
  AT_PROPOSER_RECLAIM,
  AT_TAKER_COMMIT,
  bobTerms,
  CHAIN_A,
  CHAIN_B,
  FOUNDRY_LOCK,
  FOUNDRY_SECRET,
} from '../helpers/fixtures.js'

const OMNIBUS: Address = '0x9990000000000000000000000000000000000999'
const IMPOSTOR: Address = '0x0000000000000000000000000000000000000bad'
const VERIFIER: Address = '0x8880000000000000000000000000000000000888'
const SENDER: Address = '0x7770000000000000000000000000000000000777'
const TX_HASH = `0x${'ab'.repeat(32)}` as const
const COMMIT_DIGEST = `0x${'d1'.repeat(32)}` as const
const GAS_ESTIMATE = 100_000n
const BUFFERED_GAS = 120_000n // estimate * default 1.2 multiplier

const alice = aliceTerms(CHAIN_A) // proposer (local on chain A)
const bob = bobTerms(CHAIN_A) // taker, same chain
/** Keyed ERC-7913 auth for the mocked wallet's sending account (non-empty signature = keyed route). */
const AUTH: CommitAuth = {signer: buildKeyedSigner(VERIFIER, SENDER), signature: '0x656e76656c6f7065'}
/** Wallet-route auth: the EMPTY signature makes the sender's factory membership the authorization. */
const WALLET_AUTH: CommitAuth = {signer: buildKeyedSigner(VERIFIER, SENDER), signature: '0x'}
/** The mocked Omnibus's baked WalletFactory address. */
const FACTORY: Address = '0x6660000000000000000000000000000000000666'

/** A recorded call log shared by the mock public and wallet clients. */
interface CallLog {
  /** Ordered operation names, e.g. 'read:commitmentFee', 'estimate:commit', 'write'. */
  readonly sequence: string[]
  /** Captured estimateContractGas arguments. */
  readonly estimations: Record<string, unknown>[]
  /** Captured writeContract requests. */
  readonly writes: Record<string, unknown>[]
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
    verifierIsActive?: boolean
    senderIsQuipWallet?: boolean
    termsHash?: `0x${string}`
    posted?: boolean
    lockState?: LockState
    balance?: bigint
    withWallet?: boolean
    estimateError?: unknown
    writeError?: unknown
  } = {},
): MockSetup {
  const {
    chainId = CHAIN_A,
    timestamp = AT_PROPOSER_COMMIT,
    fee = 25n,
    verifierIsActive = true,
    senderIsQuipWallet = false,
    posted = true,
    lockState = LockState.Committed,
    balance = 10n ** 24n,
    withWallet = true,
  } = options
  const termsHash = options.termsHash ?? digestTermsCanonically(alice, bob)

  const log: CallLog = {sequence: [], estimations: [], writes: []}

  const publicClient = {
    getChainId: async () => Number(chainId),
    getBlock: async () => ({timestamp}),
    getBalance: async () => {
      log.sequence.push('read:balance')
      return balance
    },
    // NOTE: no estimateFeesPerGas mock — prepareTx must never need fee data
    // (the balance preflight checks the bare call value only); an attempt to
    // call it fails loudly here
    readContract: async (args: {address: Address; functionName: string}) => {
      log.sequence.push(`read:${args.functionName}`)
      switch (args.functionName) {
        case 'verifierActive':
          return verifierIsActive
        case 'WALLET_FACTORY':
          return FACTORY
        case 'vaultIdOf':
          // the wallet-route membership read, dispatched to FACTORY
          return senderIsQuipWallet ? `0x${'11'.repeat(32)}` : `0x${'00'.repeat(32)}`
        case 'commitDigest':
          return COMMIT_DIGEST
        case 'commitmentFee':
          return fee
        case 'lockState':
          return lockState
        case 'termsHash':
          return termsHash
        case 'posted':
          return posted
        default:
          throw new Error(`unexpected read: ${args.functionName}`)
      }
    },
    estimateContractGas: async (args: Record<string, unknown>) => {
      log.sequence.push(`estimate:${String(args['functionName'])}`)
      log.estimations.push(args)
      if (options.estimateError !== undefined) throw options.estimateError
      return GAS_ESTIMATE
    },
  } as unknown as PublicClient

  const walletClient = {
    account: {address: SENDER, type: 'json-rpc'},
    writeContract: async (request: Record<string, unknown>) => {
      log.sequence.push('write')
      if (options.writeError !== undefined) throw options.writeError
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
    // a fresh lock for a first commit is Unused
    mocks = setup({lockState: LockState.Unused})
  })

  it('selects the commit function with 7-field Terms tuples and exact msg.value', async () => {
    const hash = await mocks.client.commit({lock: FOUNDRY_LOCK, party: alice, counterparty: bob, auth: AUTH})
    expect(hash).toBe(TX_HASH)

    const est = mocks.log.estimations[0] as {
      functionName: string
      args: [unknown, unknown, unknown, unknown]
      value: bigint
      address: Address
      account: Address
    }
    expect(est.functionName).toBe('commit')
    expect(est.address).toBe(OMNIBUS)
    expect(est.args[0]).toBe(FOUNDRY_LOCK)
    expectAbiTerms(est.args[1], alice)
    expectAbiTerms(est.args[2], bob)
    // the CommitAuth struct rides along as the fourth argument, exactly as given
    expect(est.args[3]).toEqual({
      signer: buildKeyedSigner(VERIFIER, SENDER),
      signature: '0x656e76656c6f7065',
    })
    // exact value: totalNative(alice) = 1 ether + fee 25 wei — never more, never less
    expect(est.value).toBe(10n ** 18n + 25n)
    // the write carries the same function/args/value
    const write = mocks.log.writes[0] as {functionName: string; value: bigint}
    expect(write.functionName).toBe('commit')
    expect(write.value).toBe(10n ** 18n + 25n)
  })

  it('reads commitmentFee and lock state BEFORE estimating, and estimates BEFORE writing', async () => {
    await mocks.client.commit({lock: FOUNDRY_LOCK, party: alice, counterparty: bob, auth: AUTH})
    const seq = mocks.log.sequence
    expect(seq.indexOf('read:lockState')).toBeLessThan(seq.indexOf('estimate:commit'))
    expect(seq.indexOf('read:commitmentFee')).toBeLessThan(seq.indexOf('estimate:commit'))
    expect(seq.indexOf('estimate:commit')).toBeLessThan(seq.indexOf('write'))
  })

  it('keyed commits never consult the wallet factory', async () => {
    await mocks.client.commit({lock: FOUNDRY_LOCK, party: alice, counterparty: bob, auth: AUTH})
    expect(mocks.log.sequence).not.toContain('read:WALLET_FACTORY')
    expect(mocks.log.sequence).not.toContain('read:vaultIdOf')
  })

  it('wallet route: an empty signature from a non-wallet sender rejects NOT_QUIP_WALLET before estimation', async () => {
    expect(
      await codeOf(mocks.client.commit({lock: FOUNDRY_LOCK, party: alice, counterparty: bob, auth: WALLET_AUTH})),
    ).toBe('NOT_QUIP_WALLET')
    // membership WAS read; nothing was estimated or written
    expect(mocks.log.sequence).toContain('read:WALLET_FACTORY')
    expect(mocks.log.sequence).toContain('read:vaultIdOf')
    expect(mocks.log.sequence).not.toContain('estimate:commit')
    expect(mocks.log.writes).toHaveLength(0)
  })

  it('wallet route: a registered wallet sender passes preflight and the empty signature rides through', async () => {
    const registered = setup({lockState: LockState.Unused, senderIsQuipWallet: true})
    const hash = await registered.client.commit({lock: FOUNDRY_LOCK, party: alice, counterparty: bob, auth: WALLET_AUTH})
    expect(hash).toBe(TX_HASH)
    const est = registered.log.estimations[0] as {args: [unknown, unknown, unknown, unknown]}
    expect(est.args[3]).toEqual({signer: buildKeyedSigner(VERIFIER, SENDER), signature: '0x'})
  })

  it('getWalletFactory returns the baked factory and isQuipWallet reflects vaultIdOf', async () => {
    expect(await mocks.client.getWalletFactory()).toBe(FACTORY)
    expect(await mocks.client.isQuipWallet(SENDER)).toBe(false)
    expect(await setup({senderIsQuipWallet: true}).client.isQuipWallet(SENDER)).toBe(true)
  })

  it('rejects a malformed auth.signer with MALFORMED_SIGNER BEFORE any write', async () => {
    // shorter than 20 bytes — the contract would revert MalformedSigner;
    // the SDK preflight catches it before estimation or submission
    const malformed = setup({lockState: LockState.Unused})
    expect(
      await codeOf(
        malformed.client.commit({
          lock: FOUNDRY_LOCK,
          party: alice,
          counterparty: bob,
          auth: {signer: '0x1234', signature: '0x'},
        }),
      ),
    ).toBe('MALFORMED_SIGNER')
    expect(malformed.log.sequence).not.toContain('estimate:commit')
    expect(malformed.log.writes).toHaveLength(0)
  })

  it('passes the BUFFERED gas (estimate x 1.2) into writeContract', async () => {
    await mocks.client.commit({lock: FOUNDRY_LOCK, party: alice, counterparty: bob, auth: AUTH})
    expect((mocks.log.writes[0] as {gas: bigint}).gas).toBe(BUFFERED_GAS)
  })

  it('estimateContractGas receives the exact contract params (function, args, value, account)', async () => {
    await mocks.client.commit({lock: FOUNDRY_LOCK, party: alice, counterparty: bob, auth: AUTH})
    const est = mocks.log.estimations[0] as Record<string, unknown>
    expect(est['functionName']).toBe('commit')
    expect(est['account']).toBe(SENDER)
    expect(est['value']).toBe(10n ** 18n + 25n)
    expect((est['args'] as unknown[])[0]).toBe(FOUNDRY_LOCK)
  })

  it('rejects a missing wallet client with a clear error', async () => {
    const readOnly = setup({withWallet: false})
    expect(await codeOf(readOnly.client.commit({lock: FOUNDRY_LOCK, party: alice, counterparty: bob, auth: AUTH}))).toBe(
      'MISSING_WALLET_CLIENT',
    )
    expect(readOnly.log.writes).toHaveLength(0)
  })

  it('rejects a chain mismatch on the PARTY side before submission', async () => {
    // commit must be sent on the party's chain; connected chain is B here
    const wrongChain = setup({chainId: CHAIN_B})
    expect(await codeOf(wrongChain.client.commit({lock: FOUNDRY_LOCK, party: alice, counterparty: bob, auth: AUTH}))).toBe(
      'CHAIN_ID_MISMATCH',
    )
    expect(wrongChain.log.writes).toHaveLength(0)
  })

  it('allows a REMOTE counterparty chain (cross-chain commit)', async () => {
    const crossBob = bobTerms(CHAIN_B)
    await expect(mocks.client.commit({lock: FOUNDRY_LOCK, party: alice, counterparty: crossBob, auth: AUTH})).resolves.toBe(
      TX_HASH,
    )
  })

  it('rejects a commit outside the sender window before submission', async () => {
    // proposer trying to commit AT its deadline (upper bound exclusive)
    const late = setup({timestamp: alice.commitmentDeadline})
    expect(await codeOf(late.client.commit({lock: FOUNDRY_LOCK, party: alice, counterparty: bob, auth: AUTH}))).toBe(
      'WINDOW_VIOLATED',
    )
    expect(late.log.writes).toHaveLength(0)
  })

  it('explains a taker commit attempted before the window opens', async () => {
    // taker (bob) committing during the proposer's window — too early
    try {
      await mocks.client.commit({lock: FOUNDRY_LOCK, party: bob, counterparty: alice, auth: AUTH})
      expect.unreachable()
    } catch (error) {
      expect(error).toBeInstanceOf(QuipSwapError)
      expect((error as QuipSwapError).code).toBe('WINDOW_VIOLATED')
      expect((error as QuipSwapError).message).toContain('has not opened yet')
    }
  })
})

describe('commit lock-state preflight', () => {
  it('Spent and Committed locks reject with INVALID_LOCK_STATE before estimation', async () => {
    for (const state of [LockState.Spent, LockState.Committed]) {
      const mocks = setup({lockState: state})
      expect(await codeOf(mocks.client.commit({lock: FOUNDRY_LOCK, party: alice, counterparty: bob, auth: AUTH}))).toBe(
        'INVALID_LOCK_STATE',
      )
      expect(mocks.log.sequence).not.toContain('estimate:commit')
      expect(mocks.log.writes).toHaveLength(0)
    }
  })

  it('a Free lock with this side already posted rejects TERMS_ALREADY_POSTED', async () => {
    // the second same-chain commit must post the OTHER side; bob (taker)
    // re-posting bob's own already-posted side is the contract's
    // TermsAlreadyPosted case
    const mocks = setup({lockState: LockState.Free, posted: true, timestamp: AT_TAKER_COMMIT})
    expect(await codeOf(mocks.client.commit({lock: FOUNDRY_LOCK, party: bob, counterparty: alice, auth: AUTH}))).toBe(
      'TERMS_ALREADY_POSTED',
    )
    expect(mocks.log.writes).toHaveLength(0)
  })

  it('a Free lock with a mismatched termsHash rejects TERMS_NOT_ON_CHAIN', async () => {
    const mocks = setup({
      lockState: LockState.Free,
      posted: false,
      timestamp: AT_TAKER_COMMIT,
      termsHash: `0x${'99'.repeat(32)}`,
    })
    expect(await codeOf(mocks.client.commit({lock: FOUNDRY_LOCK, party: bob, counterparty: alice, auth: AUTH}))).toBe(
      'TERMS_NOT_ON_CHAIN',
    )
    expect(mocks.log.writes).toHaveLength(0)
  })

  it('a Free lock with matching termsHash and an un-posted side proceeds', async () => {
    const mocks = setup({lockState: LockState.Free, posted: false, timestamp: AT_TAKER_COMMIT})
    await expect(mocks.client.commit({lock: FOUNDRY_LOCK, party: bob, counterparty: alice, auth: AUTH})).resolves.toBe(TX_HASH)
  })

  it('verifyOnChainState: false skips the lock reads and falls through to estimation', async () => {
    const mocks = setup({lockState: LockState.Spent}) // would reject if read
    await expect(
      mocks.client.commit({lock: FOUNDRY_LOCK, party: alice, counterparty: bob, auth: AUTH, verifyOnChainState: false}),
    ).resolves.toBe(TX_HASH)
    expect(mocks.log.sequence).not.toContain('read:lockState')
  })
})

describe('claim orchestration', () => {
  it('selects the claim function with the secret and 7-field tuples', async () => {
    const mocks = setup({timestamp: AT_PROPOSER_CLAIM})
    await mocks.client.claim({secret: FOUNDRY_SECRET, party: alice, counterparty: bob})
    const est = mocks.log.estimations[0] as {functionName: string; args: [unknown, unknown, unknown]; value?: bigint}
    expect(est.functionName).toBe('claim')
    expect(est.args[0]).toBe(FOUNDRY_SECRET)
    expectAbiTerms(est.args[1], alice)
    expectAbiTerms(est.args[2], bob)
    expect(est.value).toBeUndefined() // claim is not payable
  })

  it('derives the lock from the secret and verifies lockState + termsHash + posted in one batch', async () => {
    const mocks = setup({timestamp: AT_PROPOSER_CLAIM})
    await mocks.client.claim({secret: FOUNDRY_SECRET, party: alice, counterparty: bob})
    expect(mocks.log.sequence).toContain('read:lockState')
    expect(mocks.log.sequence).toContain('read:termsHash')
    expect(mocks.log.sequence).toContain('read:posted')
    expect(generateLock(FOUNDRY_SECRET)).toBe(FOUNDRY_LOCK)
  })

  it.each([
    [LockState.Unused, 'nothing has been committed'],
    [LockState.Free, 'counterparty has not committed'],
    [LockState.Spent, 'already claimed or reclaimed'],
  ])('rejects a non-Committed lock (state %s) with INVALID_LOCK_STATE and a per-state cause', async (state, cause) => {
    const mocks = setup({timestamp: AT_PROPOSER_CLAIM, lockState: state as LockState})
    try {
      await mocks.client.claim({secret: FOUNDRY_SECRET, party: alice, counterparty: bob})
      expect.unreachable()
    } catch (error) {
      expect(error).toBeInstanceOf(QuipSwapError)
      expect((error as QuipSwapError).code).toBe('INVALID_LOCK_STATE')
      expect((error as QuipSwapError).message).toContain(cause)
      expect((error as QuipSwapError).details).toMatchObject({lockState: state, required: 'Committed'})
    }
    expect(mocks.log.sequence).not.toContain('estimate:claim')
    expect(mocks.log.writes).toHaveLength(0)
  })

  it('verifyOnChainState: false skips the lock reads and falls through to estimation', async () => {
    const mocks = setup({timestamp: AT_PROPOSER_CLAIM, lockState: LockState.Spent})
    await expect(
      mocks.client.claim({secret: FOUNDRY_SECRET, party: alice, counterparty: bob, verifyOnChainState: false}),
    ).resolves.toBe(TX_HASH)
    expect(mocks.log.sequence).not.toContain('read:lockState')
    expect(mocks.log.sequence).toContain('estimate:claim')
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
    const est = mocks.log.estimations[0] as {functionName: string; args: [unknown, unknown, unknown]}
    expect(est.functionName).toBe('reclaim')
    expect(est.args[0]).toBe(FOUNDRY_LOCK)
    expectAbiTerms(est.args[1], alice)
    expectAbiTerms(est.args[2], bob)
  })

  it('accepts Free and Committed locks; rejects Unused and Spent with INVALID_LOCK_STATE', async () => {
    for (const state of [LockState.Free, LockState.Committed]) {
      const ok = setup({timestamp: AT_PROPOSER_RECLAIM, lockState: state})
      await expect(ok.client.reclaim({lock: FOUNDRY_LOCK, party: alice, counterparty: bob})).resolves.toBe(TX_HASH)
    }
    for (const state of [LockState.Unused, LockState.Spent]) {
      const bad = setup({timestamp: AT_PROPOSER_RECLAIM, lockState: state})
      try {
        await bad.client.reclaim({lock: FOUNDRY_LOCK, party: alice, counterparty: bob})
        expect.unreachable()
      } catch (error) {
        expect((error as QuipSwapError).code).toBe('INVALID_LOCK_STATE')
        expect((error as QuipSwapError).details).toMatchObject({lockState: state, required: 'Free or Committed'})
      }
      expect(bad.log.writes).toHaveLength(0)
    }
  })

  it('verifyOnChainState: false skips the lock reads', async () => {
    const mocks = setup({timestamp: AT_PROPOSER_RECLAIM, lockState: LockState.Spent})
    await expect(
      mocks.client.reclaim({lock: FOUNDRY_LOCK, party: alice, counterparty: bob, verifyOnChainState: false}),
    ).resolves.toBe(TX_HASH)
    expect(mocks.log.sequence).not.toContain('read:lockState')
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

describe('gas estimation and balance preflight', () => {
  it('a contract revert during estimation produces a decoded CONTRACT_REVERT, not a generic failure', async () => {
    // a real viem revert error carrying decodable Omnibus error data
    const revert = new ContractFunctionRevertedError({
      abi: omnibusAbi,
      functionName: 'claim',
      data: encodeErrorResult({abi: omnibusAbi, errorName: 'InvalidLockState'}),
    })
    const mocks = setup({timestamp: AT_PROPOSER_CLAIM, estimateError: revert})
    try {
      await mocks.client.claim({secret: FOUNDRY_SECRET, party: alice, counterparty: bob})
      expect.unreachable()
    } catch (error) {
      expect(error).toBeInstanceOf(QuipSwapError)
      expect((error as QuipSwapError).code).toBe('CONTRACT_REVERT')
      expect((error as QuipSwapError).contractErrorName).toBe('InvalidLockState')
    }
    expect(mocks.log.writes).toHaveLength(0)
  })

  it('a contract revert during commit estimation surfaces as CONTRACT_REVERT with the name', async () => {
    // a revert that the SDK does NOT preflight (exact-value mismatch) must
    // still decode cleanly from the estimation path — signature VALIDITY is
    // deliberately left to the contract, so use a non-signature error
    const revert = new ContractFunctionRevertedError({
      abi: omnibusAbi,
      functionName: 'commit',
      data: encodeErrorResult({abi: omnibusAbi, errorName: 'IncorrectNativeAmountReceived'}),
    })
    const mocks = setup({lockState: LockState.Unused, estimateError: revert})
    try {
      await mocks.client.commit({lock: FOUNDRY_LOCK, party: alice, counterparty: bob, auth: AUTH})
      expect.unreachable()
    } catch (error) {
      expect(error).toBeInstanceOf(QuipSwapError)
      expect((error as QuipSwapError).code).toBe('CONTRACT_REVERT')
      expect((error as QuipSwapError).contractErrorName).toBe('IncorrectNativeAmountReceived')
    }
    expect(mocks.log.writes).toHaveLength(0)
  })

  it('a non-revert estimation failure produces GAS_ESTIMATION_FAILED with the cause preserved', async () => {
    const network = new Error('connection refused')
    const mocks = setup({timestamp: AT_PROPOSER_CLAIM, estimateError: network})
    try {
      await mocks.client.claim({secret: FOUNDRY_SECRET, party: alice, counterparty: bob})
      expect.unreachable()
    } catch (error) {
      expect((error as QuipSwapError).code).toBe('GAS_ESTIMATION_FAILED')
      expect((error as QuipSwapError).cause).toBe(network)
    }
    expect(mocks.log.writes).toHaveLength(0)
  })

  it('a sender underfunded for the call VALUE is rejected BALANCE_TOO_LOW and estimation is NEVER attempted', async () => {
    // commit carries value (1 ether native + 25 wei fee); a zero-balance
    // sender fails the stage-1 preflight BEFORE eth_estimateGas, so
    // insufficient funds can no longer masquerade as GAS_ESTIMATION_FAILED
    const mocks = setup({lockState: LockState.Unused, balance: 0n})
    try {
      await mocks.client.commit({lock: FOUNDRY_LOCK, party: alice, counterparty: bob, auth: AUTH})
      expect.unreachable()
    } catch (error) {
      expect((error as QuipSwapError).code).toBe('BALANCE_TOO_LOW')
      expect((error as QuipSwapError).details).toMatchObject({balance: 0n, required: 10n ** 18n + 25n})
    }
    expect(mocks.log.sequence).not.toContain('estimate:commit')
    expect(mocks.log.writes).toHaveLength(0)
  })

  it('value-less calls (claim) have NO balance preflight — getBalance is never read', async () => {
    // claim carries no value; gas funding is deliberately not preflighted
    const mocks = setup({timestamp: AT_PROPOSER_CLAIM, balance: 0n})
    await expect(mocks.client.claim({secret: FOUNDRY_SECRET, party: alice, counterparty: bob})).resolves.toBe(TX_HASH)
    expect(mocks.log.sequence).not.toContain('read:balance')
  })

  it('a send-time InsufficientFundsError surfaces as BALANCE_TOO_LOW, not CONTRACT_REVERT', async () => {
    // value-less calls skip the preflight, so a gas-unfunded sender fails
    // at SEND time; submitWrite maps viem's InsufficientFundsError
    const mocks = setup({timestamp: AT_PROPOSER_CLAIM, writeError: new InsufficientFundsError()})
    try {
      await mocks.client.claim({secret: FOUNDRY_SECRET, party: alice, counterparty: bob})
      expect.unreachable()
    } catch (error) {
      expect((error as QuipSwapError).code).toBe('BALANCE_TOO_LOW')
      expect((error as QuipSwapError).message).toContain('fund the account')
    }
  })

  it('skipPreflightChecks skips ONLY the balance check — protocol preflights still run', async () => {
    // the value-underfunded commit would fail the preflight, but the option waives it
    const skipped = setup({lockState: LockState.Unused, balance: 0n})
    await expect(
      skipped.client.commit({lock: FOUNDRY_LOCK, party: alice, counterparty: bob, auth: AUTH}, {skipPreflightChecks: true}),
    ).resolves.toBe(TX_HASH)
    expect(skipped.log.sequence).not.toContain('read:balance')

    // ...but the same option does NOT waive a protocol preflight (window)
    const wrongWindow = setup({timestamp: AT_PROPOSER_COMMIT, balance: 0n})
    expect(
      await codeOf(
        wrongWindow.client.claim(
          {secret: FOUNDRY_SECRET, party: alice, counterparty: bob},
          {skipPreflightChecks: true},
        ),
      ),
    ).toBe('WINDOW_VIOLATED')
  })

  it('explicit opts.gas bypasses estimation; caller fee fields are forwarded selectively', async () => {
    const mocks = setup({timestamp: AT_PROPOSER_CLAIM})
    await mocks.client.claim(
      {secret: FOUNDRY_SECRET, party: alice, counterparty: bob},
      {gas: 555_555n, maxFeePerGas: 9n},
    )
    expect(mocks.log.sequence).not.toContain('estimate:claim')
    const write = mocks.log.writes[0] as Record<string, unknown>
    expect(write['gas']).toBe(555_555n) // verbatim, no multiplier
    expect(write['maxFeePerGas']).toBe(9n)
    expect('maxPriorityFeePerGas' in write).toBe(false) // unset fields never forwarded
    expect('gasPrice' in write).toBe(false)
  })
})

describe('reads', () => {
  it('isVerifierActive reads verifierActive and returns its value', async () => {
    const active = setup({verifierIsActive: true})
    await expect(active.client.isVerifierActive(VERIFIER)).resolves.toBe(true)
    expect(active.log.sequence).toEqual(['read:verifierActive'])

    const inactive = setup({verifierIsActive: false})
    await expect(inactive.client.isVerifierActive(VERIFIER)).resolves.toBe(false)
  })

  it('getCommitDigest reads the commitDigest view with the 7-field tuples and signerHash', async () => {
    const mocks = setup()
    const signerHash = `0x${'5e'.repeat(32)}` as const
    await expect(mocks.client.getCommitDigest(FOUNDRY_LOCK, alice, bob, signerHash)).resolves.toBe(COMMIT_DIGEST)
    expect(mocks.log.sequence).toEqual(['read:commitDigest'])
  })

  it('getCommitDigest rejects a malformed signerHash before any RPC interaction', () => {
    const mocks = setup()
    // the guard throws synchronously, before a promise (or any read) exists
    try {
      mocks.client.getCommitDigest(FOUNDRY_LOCK, alice, bob, '0x12' as never)
      expect.unreachable()
    } catch (error) {
      expect(error).toBeInstanceOf(QuipSwapError)
      expect((error as QuipSwapError).code).toBe('INVALID_HEX32')
    }
    expect(mocks.log.sequence).toHaveLength(0)
  })
})

describe('admin.setVerifierActivity orchestration', () => {
  it('selects setVerifierActivity with (verifier, active) and no value, estimating before writing', async () => {
    const mocks = setup()
    await expect(mocks.client.admin.setVerifierActivity(VERIFIER, true)).resolves.toBe(TX_HASH)
    const est = mocks.log.estimations[0] as {functionName: string; args: [unknown, unknown]; value?: bigint}
    expect(est.functionName).toBe('setVerifierActivity')
    expect(est.args).toEqual([VERIFIER, true])
    expect(est.value).toBeUndefined() // not payable
    const seq = mocks.log.sequence
    expect(seq.indexOf('estimate:setVerifierActivity')).toBeLessThan(seq.indexOf('write'))
    const write = mocks.log.writes[0] as {functionName: string; args: [unknown, unknown]; gas: bigint}
    expect(write.functionName).toBe('setVerifierActivity')
    expect(write.args).toEqual([VERIFIER, true])
    expect(write.gas).toBe(BUFFERED_GAS)
  })

  it('rejects without a wallet client, before any RPC interaction', async () => {
    const readOnly = setup({withWallet: false})
    expect(await codeOf(readOnly.client.admin.setVerifierActivity(VERIFIER, false))).toBe('MISSING_WALLET_CLIENT')
    expect(readOnly.log.writes).toHaveLength(0)
  })
})

describe('client.waitForReceipt (uses client.address for scoping)', () => {
  it('decodes only events from the client Omnibus address, dropping a same-shaped impostor log', async () => {
    // a receipt with the genuine Omnibus claim and an impostor claim (same
    // ABI shape, different emitter) in the same transaction
    const logs = [
      claimLog({address: OMNIBUS, lock: FOUNDRY_LOCK, secret: FOUNDRY_SECRET, recipient: SENDER}),
      claimLog({address: IMPOSTOR, lock: FOUNDRY_LOCK, secret: FOUNDRY_SECRET, recipient: SENDER}),
    ]
    const publicClient = {
      // waitForReceipt must NOT require the caller to pass an address — the
      // client supplies its own OMNIBUS address for filtering
      waitForTransactionReceipt: async () => ({status: 'success', logs, transactionHash: TX_HASH}),
    } as unknown as PublicClient
    const client = createOmnibusClient({address: OMNIBUS, publicClient})

    const result = await client.waitForReceipt(TX_HASH)
    expect(result.claims).toHaveLength(1)
    expect(result.claims[0]?.secret).toBe(FOUNDRY_SECRET)
  })
})
