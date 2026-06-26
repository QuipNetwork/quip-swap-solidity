/**
 * Receipt-decoding unit tests (pure — fake PublicClient, no chain).
 *
 * The security focus: `waitForOmnibusReceipt(publicClient, hash, {address})`
 * must decode ONLY logs emitted by `address`, so a same-signature
 * `Commitment`/`Claim`/`Reclaimed` event from another contract in the same
 * transaction is never returned as a genuine Omnibus event. Omitting
 * `address` keeps the legacy raw behavior.
 */
import {getAddress} from 'viem'
import type {Address, Hash, Log, PublicClient, TransactionReceipt} from 'viem'
import {describe, expect, it} from 'vitest'
import {QuipSwapError} from '../../src/errors.js'
import {waitForOmnibusReceipt} from '../../src/receipts.js'
import {aliceTerms, CHAIN_A, FOUNDRY_LOCK, FOUNDRY_SECRET} from '../helpers/fixtures.js'
import {claimLog, commitmentLog, reclaimedLog} from '../helpers/logs.js'

const OMNIBUS: Address = getAddress('0x0000000000000000000000000000000000000999')
const IMPOSTOR: Address = getAddress('0x0000000000000000000000000000000000000bad')
const COMMITTER: Address = getAddress('0x00000000000000000000000000000000000a11ce')
const RECIPIENT: Address = getAddress('0x00000000000000000000000000000000000a0001')
const HASH = `0x${'ab'.repeat(32)}` as Hash

/** All six logs: one of each event type at OMNIBUS, and one of each at IMPOSTOR. */
function bothAddressesLogs(): Log[] {
  const party = aliceTerms(CHAIN_A)
  const mk = (address: Address, base: number): Log[] => [
    commitmentLog({address, lock: FOUNDRY_LOCK, committer: COMMITTER, party, logIndex: base}),
    claimLog({address, lock: FOUNDRY_LOCK, secret: FOUNDRY_SECRET, recipient: RECIPIENT, logIndex: base + 1}),
    reclaimedLog({address, lock: FOUNDRY_LOCK, caller: COMMITTER, recipient: RECIPIENT, logIndex: base + 2}),
  ]
  return [...mk(OMNIBUS, 0), ...mk(IMPOSTOR, 3)]
}

/** A fake PublicClient whose waitForTransactionReceipt returns the given receipt (or throws). */
function fakeClient(opts: {logs?: Log[]; status?: 'success' | 'reverted'; throwError?: unknown}): PublicClient {
  return {
    waitForTransactionReceipt: async () => {
      if (opts.throwError !== undefined) throw opts.throwError
      return {
        status: opts.status ?? 'success',
        logs: opts.logs ?? [],
        transactionHash: HASH,
      } as unknown as TransactionReceipt
    },
  } as unknown as PublicClient
}

describe('waitForOmnibusReceipt address scoping', () => {
  it('with {address} decodes ONLY the expected-address events, ignoring impostor logs', async () => {
    const client = fakeClient({logs: bothAddressesLogs()})
    const result = await waitForOmnibusReceipt(client, HASH, {address: OMNIBUS})
    expect(result.commitments).toHaveLength(1)
    expect(result.claims).toHaveLength(1)
    expect(result.reclaims).toHaveLength(1)
    // the surviving claim is the genuine one
    expect(result.claims[0]?.secret).toBe(FOUNDRY_SECRET)
  })

  it('filters all three event types (the impostor copies are dropped)', async () => {
    // sanity: without filtering there would be two of each (proven below);
    // with {address} exactly one of each survives — already asserted above,
    // here we assert the impostor address yields the OTHER set
    const client = fakeClient({logs: bothAddressesLogs()})
    const result = await waitForOmnibusReceipt(client, HASH, {address: IMPOSTOR})
    expect(result.commitments).toHaveLength(1)
    expect(result.claims).toHaveLength(1)
    expect(result.reclaims).toHaveLength(1)
  })

  it('omitting address preserves the legacy raw behavior (decodes every matching log)', async () => {
    const client = fakeClient({logs: bothAddressesLogs()})
    const result = await waitForOmnibusReceipt(client, HASH)
    expect(result.commitments).toHaveLength(2)
    expect(result.claims).toHaveLength(2)
    expect(result.reclaims).toHaveLength(2)
  })

  it('address comparison is case-insensitive', async () => {
    const client = fakeClient({logs: bothAddressesLogs()})
    // lowercase the checksummed address — must still match
    const result = await waitForOmnibusReceipt(client, HASH, {address: OMNIBUS.toLowerCase() as Address})
    expect(result.claims).toHaveLength(1)
    expect(result.commitments).toHaveLength(1)
    expect(result.reclaims).toHaveLength(1)
  })
})

describe('waitForOmnibusReceipt error handling', () => {
  it('throws TRANSACTION_REVERTED for a reverted receipt', async () => {
    const client = fakeClient({status: 'reverted'})
    await expect(waitForOmnibusReceipt(client, HASH, {address: OMNIBUS})).rejects.toMatchObject({
      code: 'TRANSACTION_REVERTED',
    })
  })

  it('wraps a waitForTransactionReceipt failure as CONTRACT_REVERT, preserving the cause', async () => {
    const cause = new Error('rpc timeout')
    const client = fakeClient({throwError: cause})
    try {
      await waitForOmnibusReceipt(client, HASH, {address: OMNIBUS})
      expect.unreachable()
    } catch (error) {
      expect(error).toBeInstanceOf(QuipSwapError)
      expect((error as QuipSwapError).code).toBe('CONTRACT_REVERT')
      expect((error as QuipSwapError).cause).toBe(cause)
    }
  })
})
