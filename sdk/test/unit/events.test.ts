/**
 * Event-extraction unit tests (pure — no chain).
 *
 * Covers `extractRevealedSecret` / `extractSecretFromClaims`: the secret is
 * returned only when the event's lock matches AND `generateLock(secret)`
 * hashes back to that lock — so a same-shaped fake `Claim(lock, wrongSecret)`
 * is ignored. Address scoping is NOT this function's job (it is proven in
 * receipts.test.ts); these tests confirm a valid claim is decoded regardless
 * of the emitting address.
 */
import {concatHex, getAddress, keccak256, toHex} from 'viem'
import type {Address} from 'viem'
import {describe, expect, it} from 'vitest'
import {
  decodeClaimEvents,
  decodeCommitmentEvents,
  extractRevealedSecret,
  extractSecretFromClaims,
} from '../../src/events.js'
import {generateLock} from '../../src/hashing.js'
import type {Hex32} from '../../src/types.js'
import {aliceTerms, CHAIN_A, FOUNDRY_LOCK, FOUNDRY_SECRET} from '../helpers/fixtures.js'
import {claimLog, commitmentLog} from '../helpers/logs.js'

const OMNIBUS: Address = getAddress('0x0000000000000000000000000000000000000999')
const OTHER: Address = getAddress('0x0000000000000000000000000000000000000bad')
const RECIPIENT: Address = getAddress('0x00000000000000000000000000000000000a0001')
const SENDER: Address = getAddress('0x00000000000000000000000000000000000a11ce')

// a real second pair (secret hashes to its lock) for multi-claim cases
const SECRET_2 = keccak256(toHex('second-secret')) as Hex32
const LOCK_2 = generateLock(SECRET_2)

describe('decodeCommitmentEvents (new event shape)', () => {
  /** Decoded event addresses come back checksummed — normalize the fixture. */
  function checksummedTerms(
    party: ReturnType<typeof aliceTerms>) {
    return {
      ...party,
      reclaimRecipient: getAddress(party.reclaimRecipient),
      recipient: getAddress(party.recipient),
      assets: party.assets.map(a => ({
...a,
        target: getAddress(a.target)
      })),
    }
  }

  it('decodes lock (topic), party + signer (data), and sender (topic)', () => {
    const party = aliceTerms(CHAIN_A)
    // a keyed commit: the signer blob is verifier ‖ key (always > 20 bytes)
    const signer = concatHex([SENDER, '0x7913'])
    const [event] = decodeCommitmentEvents([
      commitmentLog({
        address: OMNIBUS,
        lock: FOUNDRY_LOCK,
        sender: SENDER,
        signer,
        party
      }),
    ])

    if (event === undefined)
      throw new Error('expected one Commitment event')
    expect(event.lock).toBe(FOUNDRY_LOCK)
    expect(event.sender).toBe(SENDER)
    expect(event.signer.toLowerCase()).toBe(signer.toLowerCase())
    expect(event.party).toEqual(checksummedTerms(party))
  })

  it('decodes a commit whose signer identity differs from the sender', () => {
    const party = aliceTerms(CHAIN_A)
    const keyedSigner = concatHex([OTHER, keccak256(toHex('pq-key-commitment'))])
    const [event] = decodeCommitmentEvents([
      commitmentLog({
        address: OMNIBUS,
        lock: FOUNDRY_LOCK,
        sender: SENDER,
        signer: keyedSigner,
        party
      }),
    ])

    if (event === undefined)
      throw new Error('expected one Commitment event')
    expect(event.signer.toLowerCase()).toBe(keyedSigner.toLowerCase())
    expect(event.sender).toBe(SENDER) // funding sender, distinct from the identity
  })
})

describe('extractRevealedSecret', () => {
  it('returns the real secret when lock matches and generateLock(secret) === lock', () => {
    const logs = [claimLog({
      address: OMNIBUS,
      lock: FOUNDRY_LOCK,
      secret: FOUNDRY_SECRET,
      recipient: RECIPIENT
    })]

    expect(extractRevealedSecret(logs, FOUNDRY_LOCK)).toBe(FOUNDRY_SECRET)
  })

  it('returns undefined for a fake Claim with the right lock but a secret that hashes elsewhere', () => {
    // attacker emits Claim(lock = FOUNDRY_LOCK, secret = SECRET_2); SECRET_2
    // hashes to LOCK_2, not FOUNDRY_LOCK, so it must be rejected
    expect(generateLock(SECRET_2)).not.toBe(FOUNDRY_LOCK)

    const fake = [claimLog({
      address: OMNIBUS,
      lock: FOUNDRY_LOCK,
      secret: SECRET_2,
      recipient: RECIPIENT
    })]

    expect(extractRevealedSecret(fake, FOUNDRY_LOCK)).toBeUndefined()
  })

  it('is idempotent for duplicate valid claim logs', () => {
    const one = claimLog({
      address: OMNIBUS,
      lock: FOUNDRY_LOCK,
      secret: FOUNDRY_SECRET,
      recipient: RECIPIENT
    })

    expect(extractRevealedSecret([one, one], FOUNDRY_LOCK)).toBe(FOUNDRY_SECRET)
  })

  it('returns undefined when no Claim for the requested lock is present', () => {
    const logs = [claimLog({
      address: OMNIBUS,
      lock: LOCK_2,
      secret: SECRET_2,
      recipient: RECIPIENT
    })]

    expect(extractRevealedSecret(logs, FOUNDRY_LOCK)).toBeUndefined()
  })

  it('does NOT address-filter: a valid claim from any emitter is still decoded (scoping is the receipt layer)', () => {
    // the function decodes by event shape only; OTHER-address logs are still
    // parsed. Address scoping is enforced upstream (waitForOmnibusReceipt /
    // get*Events), proven in receipts.test.ts — documented here on purpose.
    const logs = [claimLog({
      address: OTHER,
      lock: FOUNDRY_LOCK,
      secret: FOUNDRY_SECRET,
      recipient: RECIPIENT
    })]

    expect(decodeClaimEvents(logs)).toHaveLength(1)
    expect(extractRevealedSecret(logs, FOUNDRY_LOCK)).toBe(FOUNDRY_SECRET)
  })
})

describe('extractSecretFromClaims', () => {
  it('works on already-decoded claim events (the safe, scoped path)', () => {
    const claims = decodeClaimEvents([
      claimLog({
        address: OMNIBUS,
        lock: FOUNDRY_LOCK,
        secret: FOUNDRY_SECRET,
        recipient: RECIPIENT
      }),
    ])

    expect(extractSecretFromClaims(claims, FOUNDRY_LOCK)).toBe(FOUNDRY_SECRET)
  })

  it('rejects a decoded fake whose secret does not open the lock', () => {
    const claims = decodeClaimEvents([
      claimLog({
        address: OMNIBUS,
        lock: FOUNDRY_LOCK,
        secret: SECRET_2,
        recipient: RECIPIENT
      }),
    ])

    expect(extractSecretFromClaims(claims, FOUNDRY_LOCK)).toBeUndefined()
  })

  it('selects the matching lock among several decoded claims', () => {
    const claims = decodeClaimEvents([
      claimLog({
        address: OMNIBUS,
        lock: LOCK_2,
        secret: SECRET_2,
        recipient: RECIPIENT,
        logIndex: 0
      }),
      claimLog({
        address: OMNIBUS,
        lock: FOUNDRY_LOCK,
        secret: FOUNDRY_SECRET,
        recipient: RECIPIENT,
        logIndex: 1
      }),
    ])

    expect(extractSecretFromClaims(claims, FOUNDRY_LOCK)).toBe(FOUNDRY_SECRET)
    expect(extractSecretFromClaims(claims, LOCK_2)).toBe(SECRET_2)
  })
})
