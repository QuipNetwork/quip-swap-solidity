/**
 * Unit tests for commit authorization helpers: keyed signer blobs,
 * blob-shape validation, and the local commit digest (the on-chain parity
 * proof lives in the integration differential suite; these tests pin the
 * pure-function behavior and encoding shape).
 */
import {describe, expect, it} from 'vitest'
import {concatHex, encodeAbiParameters, keccak256, size, toBytes} from 'viem'
import {
  COMMIT_DIGEST_TAG,
  assertSignerBlob,
  buildKeyedSigner,
  computeCommitDigest,
  computeDomainSeparator,
  digestTerms,
} from '../../src/index.js'
import {QuipSwapError} from '../../src/errors.js'
import {aliceTerms, bobTerms} from '../helpers/fixtures.js'

function makeTermsPair() {
  return {party: aliceTerms(1n), counterparty: bobTerms(1n)}
}

const VERIFIER = '0x00000000000000000000000000000000000a11ce' as const
const ACCOUNT = '0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266' as const
const KEY32 = keccak256(toBytes('key-commitment'))
const LOCK = keccak256(toBytes('lock'))

function expectCode(fn: () => unknown, code: string): void {
  try {
    fn()
    expect.unreachable('expected a QuipSwapError')
  } catch (error) {
    expect(error).toBeInstanceOf(QuipSwapError)
    expect((error as QuipSwapError).code).toBe(code)
  }
}

describe('COMMIT_DIGEST_TAG', () => {
  it('is keccak256 of the protocol tag (no version suffix)', () => {
    expect(COMMIT_DIGEST_TAG).toBe(keccak256(toBytes('QUIP:Omnibus:commit')))
  })
})

describe('computeDomainSeparator', () => {
  it('binds tag, chainId, and address', () => {
    const sep = computeDomainSeparator(84532n, ACCOUNT)
    expect(sep).toBe(
      keccak256(
        encodeAbiParameters(
          [{type: 'bytes32'}, {type: 'uint256'}, {type: 'address'}],
          [COMMIT_DIGEST_TAG, 84532n, ACCOUNT],
        ),
      ),
    )
    expect(computeDomainSeparator(1n, ACCOUNT)).not.toBe(sep)
    expect(computeDomainSeparator(84532n, VERIFIER)).not.toBe(sep)
  })
})

describe('buildKeyedSigner', () => {
  it('concatenates verifier ‖ key (52 bytes for a 32-byte key)', () => {
    const signer = buildKeyedSigner(VERIFIER, KEY32)
    expect(signer).toBe(concatHex([VERIFIER, KEY32]))
    expect(size(signer)).toBe(52)
  })

  it('rejects a non-address verifier', () => {
    expectCode(() => buildKeyedSigner('0x1234' as never, KEY32), 'MALFORMED_SIGNER')
  })

  it('rejects an empty key (the blob must exceed 20 bytes)', () => {
    expectCode(() => buildKeyedSigner(VERIFIER, '0x'), 'MALFORMED_SIGNER')
  })
})

describe('assertSignerBlob', () => {
  it('accepts keyed blobs longer than 20 bytes', () => {
    expect(() => assertSignerBlob(`0x${'11'.repeat(21)}`)).not.toThrow()
    expect(() => assertSignerBlob(buildKeyedSigner(VERIFIER, KEY32))).not.toThrow()
  })

  it('rejects blobs of 20 bytes or fewer (contract: MalformedSigner)', () => {
    expectCode(() => assertSignerBlob('0x'), 'MALFORMED_SIGNER')
    expectCode(() => assertSignerBlob('0x01'), 'MALFORMED_SIGNER')
    expectCode(() => assertSignerBlob(`0x${'11'.repeat(19)}`), 'MALFORMED_SIGNER')
    expectCode(() => assertSignerBlob(ACCOUNT), 'MALFORMED_SIGNER') // a bare address is malformed
  })
})

describe('computeCommitDigest', () => {
  it('mirrors the Solidity encoding field-for-field (abi.encode, not packed)', () => {
    const {party, counterparty} = makeTermsPair()
    const signer = buildKeyedSigner(VERIFIER, KEY32)
    const digest = computeCommitDigest({lock: LOCK, party, counterparty, signer, omnibusAddress: ACCOUNT})

    // the domain is re-derived here INDEPENDENTLY of computeDomainSeparator
    // so this test still catches drift in either helper
    const domain = keccak256(
      encodeAbiParameters(
        [{type: 'bytes32'}, {type: 'uint256'}, {type: 'address'}],
        [COMMIT_DIGEST_TAG, party.chainId, ACCOUNT],
      ),
    )
    const expected = keccak256(
      encodeAbiParameters(
        [{type: 'bytes32'}, {type: 'bytes32'}, {type: 'bytes32'}, {type: 'bytes32'}, {type: 'bytes32'}],
        [domain, LOCK, digestTerms(party), digestTerms(counterparty), keccak256(signer)],
      ),
    )
    expect(digest).toBe(expected)
  })

  it('changes when any ingredient changes (context binding)', () => {
    const {party, counterparty} = makeTermsPair()
    const signer = buildKeyedSigner(VERIFIER, KEY32)
    const base = computeCommitDigest({lock: LOCK, party, counterparty, signer, omnibusAddress: ACCOUNT})

    const otherLock = keccak256(toBytes('other lock'))
    expect(computeCommitDigest({lock: otherLock, party, counterparty, signer, omnibusAddress: ACCOUNT})).not.toBe(base)
    // swapped sides mark the OTHER side as committing
    expect(
      computeCommitDigest({lock: LOCK, party: counterparty, counterparty: party, signer, omnibusAddress: ACCOUNT}),
    ).not.toBe(base)
    // a different declared identity
    expect(
      computeCommitDigest({
        lock: LOCK,
        party,
        counterparty,
        signer: buildKeyedSigner(VERIFIER, keccak256(toBytes('other key'))),
        omnibusAddress: ACCOUNT,
      }),
    ).not.toBe(base)
    // a different contract instance
    expect(computeCommitDigest({lock: LOCK, party, counterparty, signer, omnibusAddress: VERIFIER})).not.toBe(base)
  })

  it('rejects a malformed signer blob before hashing', () => {
    const {party, counterparty} = makeTermsPair()
    expectCode(
      () => computeCommitDigest({lock: LOCK, party, counterparty, signer: '0x0102', omnibusAddress: ACCOUNT}),
      'MALFORMED_SIGNER',
    )
  })
})
