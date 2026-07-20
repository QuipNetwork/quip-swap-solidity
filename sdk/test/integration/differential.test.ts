/**
 * Solidity/TypeScript DIFFERENTIAL tests.
 *
 * The deployed Solidity harnesses are the ORACLE: every TypeScript value is
 * compared against the corresponding harness function's output on a live
 * Anvil node. Nothing here computes an "expected" value with the function
 * under test.
 *
 * Comparison targets (TypeScript == harness):
 * - digestTerms             == TermsLibHarness.exposed_digestTerms
 * - digestTermsCanonically  == TermsLibHarness.exposed_digestTermsCanonically
 * - generateLock            == OmnibusHarness.exposed_generateLock
 * - totalNative             == TermsLibHarness.exposed_totalNative
 * - validateTermPairing     == TermsLibHarness.exposed_validateTermPairing
 *                              (accept/reject parity across vectors)
 * - enforceWithin           == TermsLibHarness.exposed_enforceWithin
 *                              (boundary parity: lower, upper-1, upper)
 * - computeCommitDigest     == Omnibus.commitDigest (the deployed contract
 *                              itself is the oracle for the commit digest)
 *
 * Run via `bun run test:integration` (the runner starts Anvil and sets
 * QUIP_SDK_RPC_URL / QUIP_SDK_CHAIN_ID).
 */
import {keccak256} from 'viem'
import type {Abi, Address, Hex} from 'viem'
import {beforeAll, describe, expect, it} from 'vitest'
import {totalNative} from '../../src/assets.js'
import {buildKeyedSigner, computeCommitDigest} from '../../src/commitAuth.js'
import {omnibusAbi} from '../../src/generated/omnibusAbi.js'
import {digestTerms, digestTermsCanonically, generateLock} from '../../src/hashing.js'
import {validateTermPairing} from '../../src/terms.js'
import {AssetType} from '../../src/types.js'
import {ZERO_BYTES32, evmToBytes32} from '../../src/universalAddress.js'
import type {Asset, Hex32, Terms} from '../../src/types.js'
import {enforceWithin} from '../../src/windows.js'
import {connectChain, deployFixture, loadArtifact} from '../helpers/chain.js'
import type {ChainContext, Fixture} from '../helpers/chain.js'
import {SOLANA_MAINNET_CHAIN_ID} from '../../src/chains.js'
import {aliceTerms, bobTerms, CHAIN_A, CHAIN_B, SOLANA_MINT, SOLANA_PUBKEY, withOptimistic, withOverrides} from '../helpers/fixtures.js'

const RPC_URL = process.env['QUIP_SDK_RPC_URL']
const CHAIN_ID = Number(process.env['QUIP_SDK_CHAIN_ID'] ?? '31337')

if (RPC_URL === undefined) {
  throw new Error('QUIP_SDK_RPC_URL is not set — run this suite via `bun run test:integration`')
}

let ctx: ChainContext
let fixture: Fixture
let termsLibHarnessAbi: Abi
let omnibusHarnessAbi: Abi

beforeAll(async () => {
  ctx = connectChain(RPC_URL, CHAIN_ID)
  fixture = await deployFixture(ctx)
  termsLibHarnessAbi = loadArtifact('TermsLibHarness.sol', 'TermsLibHarness').abi
  omnibusHarnessAbi = loadArtifact('OmnibusHarness.sol', 'OmnibusHarness').abi
})

/** Calls a view function on a harness, returning the raw result. */
async function callHarness<T>(address: Address, abi: Abi, functionName: string, args: readonly unknown[]): Promise<T> {
  return (await ctx.publicClient.readContract({address, abi, functionName, args: args as unknown[]})) as T
}

/** Terms in the tuple-object shape viem encodes for the harness ABI. */
function abiTerms(terms: Terms) {
  return {
    chainId: terms.chainId,
    reclaimRecipient: terms.reclaimRecipient,
    recipient: terms.recipient,
    commitmentDeadline: terms.commitmentDeadline,
    claimDeadline: terms.claimDeadline,
    reclaimRelease: terms.reclaimRelease,
    optimistic: terms.optimistic,
    assets: terms.assets.map(a => ({assetType: a.assetType, target: a.target, id: a.id, amount: a.amount})),
  }
}

// ---------------------------------------------------------------------------
// deterministic vector construction
// ---------------------------------------------------------------------------

/**
 * A tiny deterministic PRNG (splitmix64 over bigint) with a FIXED seed so
 * the generated-vector loop reproduces identically on every run.
 */
function seededRng(seed: bigint): () => bigint {
  const MASK = (1n << 64n) - 1n
  let state = seed & MASK
  return () => {
    state = (state + 0x9e3779b97f4a7c15n) & MASK
    let z = state
    z = ((z ^ (z >> 30n)) * 0xbf58476d1ce4e5b9n) & MASK
    z = ((z ^ (z >> 27n)) * 0x94d049bb133111ebn) & MASK
    return z ^ (z >> 31n)
  }
}

/** Random value in [1, max] (never zero — keeps assets/terms hashable everywhere). */
function rndIn(rng: () => bigint, max: bigint): bigint {
  return (rng() % max) + 1n
}

function rndUniversal(rng: () => bigint): Hex32 {
  // compose 160 bits from three 64-bit draws; force non-zero via low byte;
  // every fourth draw sets foreign upper bits (a Solana-style pubkey) so the
  // oracle comparison covers the range unreachable before the widening
  const raw = ((rng() << 96n) ^ (rng() << 48n) ^ rng()) & ((1n << 160n) - 1n)
  const foreign = rng() % 4n === 0n ? (((rng() << 200n) | (1n << 255n)) & ((1n << 256n) - 1n)) : 0n
  return `0x${((raw | 1n) | foreign).toString(16).padStart(64, '0')}` as Hex32
}

/** Random non-zero EVM address (for fields that stay address-typed, e.g. verifiers). */
function rndEvmAddress(rng: () => bigint): Address {
  const raw = ((rng() << 96n) ^ (rng() << 48n) ^ rng()) & ((1n << 160n) - 1n)
  return `0x${(raw | 1n).toString(16).padStart(40, '0')}` as Address
}

function rndAsset(rng: () => bigint): Asset {
  const kind = Number(rng() % 4n) as AssetType
  switch (kind) {
    case AssetType.Native:
      return {assetType: kind, target: ZERO_BYTES32, id: 0n, amount: rndIn(rng, 10n ** 24n)}
    case AssetType.ERC20:
      return {assetType: kind, target: rndUniversal(rng), id: 0n, amount: rndIn(rng, 10n ** 24n)}
    case AssetType.ERC721:
      // amounts OTHER THAN 1 included on purpose: digests must be sensitive
      // to the amount, which is exactly why the SDK canonicalizes to 1n
      return {assetType: kind, target: rndUniversal(rng), id: rng() % 1000n, amount: rndIn(rng, 5n)}
    default:
      return {assetType: AssetType.ERC1155, target: rndUniversal(rng), id: rng() % 1000n, amount: rndIn(rng, 10n ** 6n)}
  }
}

function rndTerms(rng: () => bigint): Terms {
  const commitment = rndIn(rng, 10n ** 12n)
  const assetCount = Number(rng() % 3n) + 1
  return {
    chainId: rndIn(rng, 10n ** 6n),
    reclaimRecipient: rndUniversal(rng),
    recipient: rndUniversal(rng),
    commitmentDeadline: commitment,
    claimDeadline: commitment + rndIn(rng, 10n ** 6n),
    reclaimRelease: commitment + 10n ** 6n + rndIn(rng, 10n ** 6n),
    // randomized so digest parity covers both flag values
    optimistic: rng() % 2n === 0n,
    assets: Array.from({length: assetCount}, () => rndAsset(rng)),
  }
}

const TOKEN: Address = '0x1000000000000000000000000000000000000001'
const OTHER_TOKEN: Address = '0x2000000000000000000000000000000000000002'

/** Hand-picked vectors covering every required category. */
function fixedVectors(): Terms[] {
  const base = aliceTerms(CHAIN_A)
  return [
    // single assets of each type
    withOverrides(base, {assets: [{assetType: AssetType.Native, target: ZERO_BYTES32, id: 0n, amount: 1n}]}),
    withOverrides(base, {assets: [{assetType: AssetType.ERC20, target: evmToBytes32(TOKEN), id: 0n, amount: 12_345n}]}),
    withOverrides(base, {assets: [{assetType: AssetType.ERC721, target: evmToBytes32(TOKEN), id: 42n, amount: 1n}]}),
    // ERC-721 with amount != 1 — proves digest sensitivity, justifying SDK canonicalization
    withOverrides(base, {assets: [{assetType: AssetType.ERC721, target: evmToBytes32(TOKEN), id: 42n, amount: 7n}]}),
    withOverrides(base, {assets: [{assetType: AssetType.ERC1155, target: evmToBytes32(TOKEN), id: 9n, amount: 100n}]}),
    // token id zero (valid for 721 and 1155)
    withOverrides(base, {assets: [{assetType: AssetType.ERC721, target: evmToBytes32(TOKEN), id: 0n, amount: 1n}]}),
    withOverrides(base, {assets: [{assetType: AssetType.ERC1155, target: evmToBytes32(TOKEN), id: 0n, amount: 5n}]}),
    // multiple assets, then the same pair reordered
    withOverrides(base, {
      assets: [
        {assetType: AssetType.Native, target: ZERO_BYTES32, id: 0n, amount: 5n},
        {assetType: AssetType.ERC20, target: evmToBytes32(OTHER_TOKEN), id: 0n, amount: 77n},
      ],
    }),
    withOverrides(base, {
      assets: [
        {assetType: AssetType.ERC20, target: evmToBytes32(OTHER_TOKEN), id: 0n, amount: 77n},
        {assetType: AssetType.Native, target: ZERO_BYTES32, id: 0n, amount: 5n},
      ],
    }),
    // different recipients
    withOverrides(base, {recipient: evmToBytes32('0x00000000000000000000000000000000000000fe')}),
    withOverrides(base, {reclaimRecipient: evmToBytes32('0x00000000000000000000000000000000000000fd')}),
    // different chain ids (incl. cross-chain id)
    withOverrides(base, {chainId: CHAIN_B}),
    withOverrides(base, {chainId: 1n}),
    // a different timestamp schedule
    withOverrides(base, {commitmentDeadline: 10n, claimDeadline: 20n, reclaimRelease: 30n}),
    // Solana-styled leg: foreign (high-bit) mint + reclaimRecipient — the
    // bytes32 range unreachable before the widening
    withOverrides(base, {
      chainId: SOLANA_MAINNET_CHAIN_ID,
      reclaimRecipient: SOLANA_PUBKEY,
      assets: [{assetType: AssetType.ERC20, target: SOLANA_MINT, id: 0n, amount: 1_000_000_000n}],
    }),
    bobTerms(CHAIN_A),
  ]
}

// ---------------------------------------------------------------------------
// digest parity
// ---------------------------------------------------------------------------

describe('digestTerms parity (oracle: TermsLibHarness.exposed_digestTerms)', () => {
  it('matches on every fixed vector', async () => {
    for (const terms of fixedVectors()) {
      const onChain = await callHarness<Hex32>(fixture.termsLibHarness, termsLibHarnessAbi, 'exposed_digestTerms', [
        abiTerms(terms),
      ])
      expect(digestTerms(terms)).toBe(onChain)
    }
  })

  it('matches on 40 deterministic generated vectors (fixed seed)', async () => {
    const rng = seededRng(0xdead_beefn)
    for (let i = 0; i < 40; i++) {
      const terms = rndTerms(rng)
      const onChain = await callHarness<Hex32>(fixture.termsLibHarness, termsLibHarnessAbi, 'exposed_digestTerms', [
        abiTerms(terms),
      ])
      expect(digestTerms(terms), `vector ${i}`).toBe(onChain)
    }
  })

  it('the optimistic flag is digest-relevant and position-parity holds for both values', async () => {
    // two terms identical except the flag: the SDK and the harness must agree
    // on BOTH digests, and the two digests must differ from each other
    const plain = aliceTerms(CHAIN_A)
    const flagged = withOptimistic(plain)
    const onChainPlain = await callHarness<Hex32>(fixture.termsLibHarness, termsLibHarnessAbi, 'exposed_digestTerms', [
      abiTerms(plain),
    ])
    const onChainFlagged = await callHarness<Hex32>(
      fixture.termsLibHarness,
      termsLibHarnessAbi,
      'exposed_digestTerms',
      [abiTerms(flagged)],
    )
    expect(digestTerms(plain)).toBe(onChainPlain)
    expect(digestTerms(flagged)).toBe(onChainFlagged)
    expect(onChainPlain).not.toBe(onChainFlagged)
  })
})

describe('digestTermsCanonically parity (oracle: exposed_digestTermsCanonically)', () => {
  it('matches in both argument orders on fixed pairs', async () => {
    const vectors = fixedVectors()
    for (let i = 0; i + 1 < vectors.length; i += 2) {
      const a = vectors[i] as Terms
      const b = vectors[i + 1] as Terms
      const onChain = await callHarness<Hex32>(
        fixture.termsLibHarness,
        termsLibHarnessAbi,
        'exposed_digestTermsCanonically',
        [abiTerms(a), abiTerms(b)],
      )
      expect(digestTermsCanonically(a, b)).toBe(onChain)
      expect(digestTermsCanonically(b, a)).toBe(onChain)
    }
  })

  it('matches near the canonical-ordering boundary and on generated pairs', async () => {
    // identical sides: partyDigest == counterpartyDigest, the exact boundary
    // of the smaller-digest-first comparison
    const same = aliceTerms(CHAIN_A)
    const boundary = await callHarness<Hex32>(
      fixture.termsLibHarness,
      termsLibHarnessAbi,
      'exposed_digestTermsCanonically',
      [abiTerms(same), abiTerms(same)],
    )
    expect(digestTermsCanonically(same, same)).toBe(boundary)

    const rng = seededRng(0xc0ffeen)
    for (let i = 0; i < 20; i++) {
      const a = rndTerms(rng)
      const b = rndTerms(rng)
      const onChain = await callHarness<Hex32>(
        fixture.termsLibHarness,
        termsLibHarnessAbi,
        'exposed_digestTermsCanonically',
        [abiTerms(a), abiTerms(b)],
      )
      expect(digestTermsCanonically(a, b), `pair ${i}`).toBe(onChain)
    }
  })
})

describe('generateLock parity (oracle: OmnibusHarness.exposed_generateLock)', () => {
  it('matches on edge and generated secrets', async () => {
    const rng = seededRng(0x5eedn)
    const secrets: Hex32[] = [
      `0x${'00'.repeat(32)}`,
      `0x${'ff'.repeat(32)}`,
      `0x${'01'.repeat(32)}`,
      ...Array.from({length: 20}, () => {
        const raw = ((rng() << 192n) ^ (rng() << 128n) ^ (rng() << 64n) ^ rng()) & ((1n << 256n) - 1n)
        return `0x${raw.toString(16).padStart(64, '0')}` as Hex32
      }),
    ]
    for (const secret of secrets) {
      const onChain = await callHarness<Hex32>(fixture.omnibusHarness, omnibusHarnessAbi, 'exposed_generateLock', [
        secret,
      ])
      expect(generateLock(secret)).toBe(onChain)
    }
  })
})

// ---------------------------------------------------------------------------
// commit digest parity
// ---------------------------------------------------------------------------

describe('computeCommitDigest parity (oracle: Omnibus.commitDigest)', () => {
  /** The deployed contract's digest for the given inputs. */
  async function oracleDigest(lock: Hex32, party: Terms, counterparty: Terms, signer: Hex): Promise<Hex32> {
    return (await ctx.publicClient.readContract({
      address: fixture.omnibus,
      abi: omnibusAbi,
      functionName: 'commitDigest',
      args: [lock, abiTerms(party), abiTerms(counterparty), keccak256(signer)],
    })) as Hex32
  }

  it('matches across varied terms pairs with keyed (>20-byte) signer blobs', async () => {
    const rng = seededRng(0xd16e57n)
    // the on-chain digest binds block.chainid, so the LOCAL (party) side
    // must carry the connected chain's id — exactly the commit invariant
    const localize = (terms: Terms): Terms => withOverrides(terms, {chainId: BigInt(CHAIN_ID)})

    // keyed ERC-7913 signer blobs (verifier ‖ key) of differing key lengths
    // built with buildKeyedSigner — the only shape the contract accepts
    const signers: Hex[] = [
      buildKeyedSigner(rndEvmAddress(rng), `0x01`), // 21-byte keyed blob (minimum valid)
      buildKeyedSigner(rndEvmAddress(rng), keccak256(`0x01`)), // 52-byte keyed blob
      buildKeyedSigner(rndEvmAddress(rng), `0xdeadbeef`), // 24-byte keyed blob
    ]

    // fixed pairs plus deterministic generated pairs (same PRNG pattern as
    // the other differential loops)
    const pairs: [Terms, Terms][] = [
      [localize(aliceTerms(CHAIN_A)), bobTerms(CHAIN_A)],
      [localize(bobTerms(CHAIN_A)), aliceTerms(CHAIN_B)], // cross-chain counterparty
      ...Array.from({length: 8}, (): [Terms, Terms] => [localize(rndTerms(rng)), rndTerms(rng)]),
    ]

    let vector = 0
    for (const [party, counterparty] of pairs) {
      const signer = signers[vector % signers.length] as Hex
      const lock = keccak256(`0x${(++vector).toString(16).padStart(64, '0')}`) as Hex32
      const local = computeCommitDigest({lock, party, counterparty, signer, omnibusAddress: fixture.omnibus})
      expect(local, `vector ${vector} (signer ${signer})`).toBe(await oracleDigest(lock, party, counterparty, signer))
    }
  })

  it('keyed blobs sharing a verifier but differing in key produce DIFFERENT digests (both in parity)', async () => {
    const party = withOverrides(aliceTerms(CHAIN_A), {chainId: BigInt(CHAIN_ID)})
    const counterparty = bobTerms(CHAIN_A)
    const lock = keccak256('0x51') as Hex32
    const verifier = '0x1000000000000000000000000000000000000001' as Address
    const keyedA = buildKeyedSigner(verifier, keccak256('0x52'))
    const keyedB = buildKeyedSigner(verifier, keccak256('0x53'))

    const localA = computeCommitDigest({lock, party, counterparty, signer: keyedA, omnibusAddress: fixture.omnibus})
    const localB = computeCommitDigest({lock, party, counterparty, signer: keyedB, omnibusAddress: fixture.omnibus})
    expect(localA).not.toBe(localB) // the WHOLE blob, not just the verifier, is bound
    expect(localA).toBe(await oracleDigest(lock, party, counterparty, keyedA))
    expect(localB).toBe(await oracleDigest(lock, party, counterparty, keyedB))
  })
})

// ---------------------------------------------------------------------------
// totalNative parity
// ---------------------------------------------------------------------------

describe('totalNative parity (oracle: exposed_totalNative)', () => {
  it('matches on fixed and generated vectors', async () => {
    const rng = seededRng(0x707a1n)
    const vectors = [...fixedVectors(), ...Array.from({length: 20}, () => rndTerms(rng))]
    for (const terms of vectors) {
      const onChain = await callHarness<bigint>(fixture.termsLibHarness, termsLibHarnessAbi, 'exposed_totalNative', [
        abiTerms(terms),
      ])
      expect(totalNative(terms)).toBe(onChain)
    }
  })
})

// ---------------------------------------------------------------------------
// pairing accept/reject parity
// ---------------------------------------------------------------------------

describe('validateTermPairing parity (oracle: exposed_validateTermPairing)', () => {
  /** True iff the harness call does NOT revert. */
  async function oracleAccepts(a: Terms, b: Terms): Promise<boolean> {
    try {
      await callHarness(fixture.termsLibHarness, termsLibHarnessAbi, 'exposed_validateTermPairing', [
        abiTerms(a),
        abiTerms(b),
      ])
      return true
    } catch {
      return false
    }
  }

  /** True iff the SDK validator does NOT throw. */
  function sdkAccepts(a: Terms, b: Terms): boolean {
    try {
      validateTermPairing(a, b)
      return true
    } catch {
      return false
    }
  }

  it('agrees on valid interleavings (both directions) and known-bad schedules', async () => {
    const alice = aliceTerms(CHAIN_A)
    const bob = bobTerms(CHAIN_A)
    const cases: [Terms, Terms][] = [
      [alice, bob],
      [bob, alice],
      // equal commitment deadlines
      [alice, withOverrides(bob, {commitmentDeadline: alice.commitmentDeadline})],
      // sequential, not interleaved
      [
        withOverrides(alice, {commitmentDeadline: 100n, claimDeadline: 200n, reclaimRelease: 300n}),
        withOverrides(bob, {commitmentDeadline: 400n, claimDeadline: 500n, reclaimRelease: 600n}),
      ],
      // taker claim before proposer claim (broken interleave)
      [alice, withOverrides(bob, {claimDeadline: alice.claimDeadline - 1n})],
    ]
    for (const [a, b] of cases) {
      expect(sdkAccepts(a, b)).toBe(await oracleAccepts(a, b))
    }
  })

  it('agrees on optimistic pairings: both-set accepted, mismatched rejected (OptimismMismatch)', async () => {
    const alice = aliceTerms(CHAIN_A)
    const bob = bobTerms(CHAIN_A)
    const cases: [Terms, Terms][] = [
      [withOptimistic(alice), withOptimistic(bob)], // bilateral opt-in — accepted
      [withOptimistic(alice), bob], // mismatch — rejected
      [alice, withOptimistic(bob)], // mismatch, reversed — rejected
    ]
    for (const [a, b] of cases) {
      expect(sdkAccepts(a, b)).toBe(await oracleAccepts(a, b))
    }
    // pin the outcomes themselves (not just agreement)
    expect(sdkAccepts(withOptimistic(alice), withOptimistic(bob))).toBe(true)
    expect(sdkAccepts(withOptimistic(alice), bob)).toBe(false)
  })

  it('agrees across 40 deterministic generated schedule pairs (fixed seed)', async () => {
    const rng = seededRng(0x9a1219n)
    let accepted = 0
    for (let i = 0; i < 40; i++) {
      // half the vectors: perturb a VALID interleaving so both outcomes occur
      const offset = rng() % 1000n
      const alice = withOverrides(aliceTerms(CHAIN_A), {
        commitmentDeadline: 1000n + offset,
        claimDeadline: 3000n + offset,
        reclaimRelease: 5000n + offset,
      })
      const perturb = i % 2 === 0 ? 0n : (rng() % 5000n) - 2500n
      const bob = withOverrides(bobTerms(CHAIN_A), {
        commitmentDeadline: 2000n + offset + perturb,
        claimDeadline: 4000n + offset,
        reclaimRelease: 6000n + offset,
      })
      const sdk = sdkAccepts(alice, bob)
      expect(sdk, `pair ${i}`).toBe(await oracleAccepts(alice, bob))
      if (sdk) accepted++
    }
    // sanity: the loop must exercise BOTH outcomes or the parity test is vacuous
    expect(accepted).toBeGreaterThan(0)
    expect(accepted).toBeLessThan(40)
  })
})

// ---------------------------------------------------------------------------
// window math boundary parity
// ---------------------------------------------------------------------------

describe('enforceWithin parity (oracle: exposed_enforceWithin)', () => {
  async function oracleAccepts(lower: bigint, upper: bigint, ts: bigint): Promise<boolean> {
    try {
      await callHarness(fixture.termsLibHarness, termsLibHarnessAbi, 'exposed_enforceWithin', [lower, upper, ts])
      return true
    } catch {
      return false
    }
  }

  function sdkAccepts(lower: bigint, upper: bigint, ts: bigint): boolean {
    try {
      enforceWithin(lower, upper, ts)
      return true
    } catch {
      return false
    }
  }

  it('agrees at lower, upper-1, and upper for fixed and generated windows', async () => {
    const MAX = (1n << 256n) - 1n
    const windows: [bigint, bigint][] = [
      [0n, 1000n],
      [1000n, 2000n],
      [5000n, MAX],
      [200n, 200n], // degenerate: InvalidRange on both sides
      [201n, 200n], // degenerate reversed
    ]
    const rng = seededRng(0x717e5n)
    for (let i = 0; i < 10; i++) {
      const lower = rng() % 10n ** 9n
      windows.push([lower, lower + (rng() % 10n ** 6n)])
    }
    for (const [lower, upper] of windows) {
      // the three boundary probes per window: lower (inclusive), upper-1
      // (last accepted instant), upper (EXCLUSIVE — must reject)
      const probes = [lower, upper - 1n, upper, lower === 0n ? 0n : lower - 1n].filter(p => p >= 0n && p <= MAX)
      for (const ts of probes) {
        expect(sdkAccepts(lower, upper, ts), `[${lower}, ${upper}) at ${ts}`).toBe(
          await oracleAccepts(lower, upper, ts),
        )
      }
    }
  })
})
