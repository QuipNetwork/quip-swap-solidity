/**
 * Two-chain end-to-end tests: a coordinated hashlocked swap across two
 * INDEPENDENT Anvil chains (31337 / 31338).
 *
 * This is NOT atomic cross-chain execution. Each leg settles on its own
 * chain; the strictly interleaved shared schedule plus the taker's
 * mandatory off-chain commitment check are what bound each side's risk.
 *
 * Parallels the cross-chain branches of `test/Omnibus/scenario/HappyPath.t.sol`
 * and `test/attack/CrossChainFreeOption.t.sol` (the role-assignment guard).
 *
 * Both chains' block timestamps are coordinated against ONE schedule by
 * warping each chain to the same anchor before each step.
 *
 * Run via `bun run test:cross-chain` (the runner starts both nodes and sets
 * QUIP_SDK_CHAIN_A_RPC_URL / QUIP_SDK_CHAIN_B_RPC_URL).
 */
import {getAddress, keccak256, toHex} from 'viem'
import type {Address} from 'viem'
import {beforeAll, describe, expect, it} from 'vitest'
import {erc20Asset, nativeAsset} from '../../src/assets.js'
import {createOmnibusClient} from '../../src/client.js'
import type {OmnibusClient} from '../../src/client.js'
import {QuipSwapError, extractContractErrorName} from '../../src/errors.js'
import {extractRevealedSecret} from '../../src/events.js'
import {omnibusAbi} from '../../src/generated/omnibusAbi.js'
import {generateLock} from '../../src/hashing.js'
import {waitForOmnibusReceipt} from '../../src/receipts.js'
import {LockState} from '../../src/types.js'
import type {Asset, Hex32, Terms} from '../../src/types.js'
import {validateCrossChainSchedule, verifyRemoteCommitment} from '../../src/workflows/crossChain.js'
import {connectChain, deployFixture} from '../helpers/chain.js'
import type {ChainContext, Fixture} from '../helpers/chain.js'
import {erc20MockAbi} from '../helpers/mockAbis.js'

const RPC_A = process.env['QUIP_SDK_CHAIN_A_RPC_URL']
const RPC_B = process.env['QUIP_SDK_CHAIN_B_RPC_URL']
const CHAIN_A_ID = Number(process.env['QUIP_SDK_CHAIN_A_ID'] ?? '31337')
const CHAIN_B_ID = Number(process.env['QUIP_SDK_CHAIN_B_ID'] ?? '31338')

if (RPC_A === undefined || RPC_B === undefined) {
  throw new Error('QUIP_SDK_CHAIN_A/B_RPC_URL not set — run this suite via `bun run test:cross-chain`')
}

const ALICE_RECIPIENT: Address = getAddress('0x00000000000000000000000000000000000a0001')
const BOB_RECIPIENT: Address = getAddress('0x00000000000000000000000000000000000b0002')
const ALICE_RECLAIM: Address = getAddress('0x00000000000000000000000000000000000a0003')
const BOB_RECLAIM: Address = getAddress('0x00000000000000000000000000000000000b0004')

let chainA: ChainContext
let chainB: ChainContext
let fixtureA: Fixture
let fixtureB: Fixture
/** Alice (proposer, secret holder) acts on chain A for commits; on B for her claim. */
let aliceOnA: OmnibusClient
let aliceOnB: OmnibusClient
/** Bob (taker) acts on chain B for commits; on A for his claim. */
let bobOnA: OmnibusClient
let bobOnB: OmnibusClient

let secretCounter = 1000
function nextSecret(): {secret: Hex32; lock: Hex32} {
  const secret = keccak256(toHex(++secretCounter, {size: 32}))
  return {secret, lock: generateLock(secret)}
}

/** One shared schedule across BOTH chains, plus per-action warp anchors. */
interface SharedSchedule {
  readonly anchors: {
    proposerCommit: bigint
    takerCommit: bigint
    proposerClaim: bigint
    takerClaim: bigint
    proposerReclaim: bigint
    takerReclaim: bigint
  }
  aliceTerms(assets: readonly Asset[]): Terms
  bobTerms(assets: readonly Asset[]): Terms
}

/** Builds one schedule from the LATER of the two chains' clocks so warps are always forward. */
async function sharedSchedule(): Promise<SharedSchedule> {
  const [nowA, nowB] = await Promise.all([chainA.now(), chainB.now()])
  const base = (nowA > nowB ? nowA : nowB) + 10n
  return {
    anchors: {
      proposerCommit: base + 500n,
      takerCommit: base + 1500n,
      proposerClaim: base + 2500n,
      takerClaim: base + 3500n,
      proposerReclaim: base + 5500n,
      takerReclaim: base + 6500n,
    },
    aliceTerms: assets => ({
      chainId: BigInt(CHAIN_A_ID), // alice's leg lives on chain A
      reclaimRecipient: ALICE_RECLAIM,
      recipient: ALICE_RECIPIENT,
      commitmentDeadline: base + 1000n,
      claimDeadline: base + 3000n,
      reclaimRelease: base + 5000n,
      assets,
    }),
    bobTerms: assets => ({
      chainId: BigInt(CHAIN_B_ID), // bob's leg lives on chain B
      reclaimRecipient: BOB_RECLAIM,
      recipient: BOB_RECIPIENT,
      commitmentDeadline: base + 2000n,
      claimDeadline: base + 4000n,
      reclaimRelease: base + 6000n,
      assets,
    }),
  }
}

/** Warps BOTH chains to the same instant, keeping the shared schedule coordinated. */
async function warpBoth(timestamp: bigint): Promise<void> {
  await Promise.all([chainA.warpTo(timestamp), chainB.warpTo(timestamp)])
}

beforeAll(async () => {
  chainA = connectChain(RPC_A, CHAIN_A_ID)
  chainB = connectChain(RPC_B, CHAIN_B_ID)
  ;[fixtureA, fixtureB] = await Promise.all([deployFixture(chainA), deployFixture(chainB)])

  aliceOnA = createOmnibusClient({
    address: fixtureA.omnibus,
    publicClient: chainA.publicClient,
    walletClient: chainA.alice.walletClient,
  })
  aliceOnB = createOmnibusClient({
    address: fixtureB.omnibus,
    publicClient: chainB.publicClient,
    walletClient: chainB.alice.walletClient,
  })
  bobOnA = createOmnibusClient({
    address: fixtureA.omnibus,
    publicClient: chainA.publicClient,
    walletClient: chainA.bob.walletClient,
  })
  bobOnB = createOmnibusClient({
    address: fixtureB.omnibus,
    publicClient: chainB.publicClient,
    walletClient: chainB.bob.walletClient,
  })

  // alice's leg asset: ERC-20 on chain A (mint + approve for alice)
  for (const [actor, ctx, fixture] of [
    [chainA.alice, chainA, fixtureA],
    [chainB.bob, chainB, fixtureB],
  ] as const) {
    let hash = await actor.walletClient.writeContract({
      address: fixture.erc20,
      abi: erc20MockAbi,
      functionName: 'mint',
      args: [actor.address, 10n ** 24n],
      chain: ctx.publicClient.chain ?? null,
      account: actor.account,
    })
    await ctx.publicClient.waitForTransactionReceipt({hash})
    hash = await actor.walletClient.writeContract({
      address: fixture.erc20,
      abi: erc20MockAbi,
      functionName: 'approve',
      args: [fixture.omnibus, (1n << 256n) - 1n],
      chain: ctx.publicClient.chain ?? null,
      account: actor.account,
    })
    await ctx.publicClient.waitForTransactionReceipt({hash})
  }
})

describe('cross-chain happy path', () => {
  it('runs the full coordinated flow: commit A, verify, commit B, claim B (reveal), claim A, both Spent', async () => {
    const TOKENS = 50_000n // alice's ERC-20 leg on chain A
    const NATIVE = 77_777n // bob's native leg on chain B
    const {secret, lock} = nextSecret()
    const s = await sharedSchedule()
    const alice = s.aliceTerms([erc20Asset(fixtureA.erc20, TOKENS)])
    const bob = s.bobTerms([nativeAsset(NATIVE)])

    // 0. the SDK validator approves the role assignment and buffers up front
    const schedule = validateCrossChainSchedule({
      proposerTerms: alice,
      takerTerms: bob,
      minimumBufferSeconds: 500n,
    })
    expect(schedule.reactionBufferSeconds).toBe(2000n) // alice.reclaimRelease - alice.claimDeadline

    // 1-2. Alice (proposer, secret holder) commits her leg ON CHAIN A.
    // cross-chain commit: Unused -> Committed directly (no Free state)
    await warpBoth(s.anchors.proposerCommit)
    await waitForOmnibusReceipt(
      chainA.publicClient,
      await aliceOnA.commit({lock, party: alice, counterparty: bob}),
    )
    expect(await aliceOnA.getLockState(lock)).toBe(LockState.Committed)
    expect(await bobOnB.getLockState(lock)).toBe(LockState.Unused) // B untouched

    // 3. Bob's MANDATORY off-chain verification of Alice's remote commitment
    // (the chain B contract cannot do this for him)
    const remote = await verifyRemoteCommitment(bobOnA, lock, alice, bob)
    expect(remote).toMatchObject({committed: true, lockState: LockState.Committed, termsHashMatches: true})

    // ...then Bob commits his leg ON CHAIN B inside the taker window
    await warpBoth(s.anchors.takerCommit)
    await waitForOmnibusReceipt(chainB.publicClient, await bobOnB.commit({lock, party: bob, counterparty: alice}))
    expect(await bobOnB.getLockState(lock)).toBe(LockState.Committed)

    // 4. Alice claims Bob's leg ON CHAIN B in the proposer-claim window —
    // this transaction publicly REVEALS the secret on chain B
    await warpBoth(s.anchors.proposerClaim)
    const aliceRecipientNativeBefore = await chainB.publicClient.getBalance({address: ALICE_RECIPIENT})
    const claimB = await waitForOmnibusReceipt(
      chainB.publicClient,
      await aliceOnB.claim({secret, party: alice, counterparty: bob}),
    )
    expect(await bobOnB.getLockState(lock)).toBe(LockState.Spent)
    // bob's native (counterparty leg) went to ALICE's recipient on chain B
    expect(await chainB.publicClient.getBalance({address: ALICE_RECIPIENT})).toBe(
      aliceRecipientNativeBefore + NATIVE,
    )

    // 5. Bob (or a relayer) extracts the revealed secret from the chain B
    // Claim event — equal to the original by construction
    const revealed = extractRevealedSecret(claimB.receipt.logs, lock)
    expect(revealed).toBe(secret)

    // duplicate Claim-event processing is idempotent: feeding the same logs
    // twice (duplicated array) yields the same single secret
    const duplicated = [...claimB.receipt.logs, ...claimB.receipt.logs]
    expect(extractRevealedSecret(duplicated, lock)).toBe(secret)

    // 6. Bob claims Alice's leg ON CHAIN A in the taker-claim window
    if (revealed === undefined) throw new Error('secret must have been revealed')
    await warpBoth(s.anchors.takerClaim)
    const bobRecipientTokensBefore = await chainA.publicClient.readContract({
      address: fixtureA.erc20,
      abi: erc20MockAbi,
      functionName: 'balanceOf',
      args: [BOB_RECIPIENT],
    })
    await waitForOmnibusReceipt(
      chainA.publicClient,
      await bobOnA.claim({secret: revealed, party: bob, counterparty: alice}),
    )

    // 7. both locks Spent; final balances verified on both chains
    expect(await aliceOnA.getLockState(lock)).toBe(LockState.Spent)
    expect(await bobOnB.getLockState(lock)).toBe(LockState.Spent)
    expect(
      await chainA.publicClient.readContract({
        address: fixtureA.erc20,
        abi: erc20MockAbi,
        functionName: 'balanceOf',
        args: [BOB_RECIPIENT],
      }),
    ).toBe(bobRecipientTokensBefore + TOKENS)
  })
})

describe('cross-chain validator guards', () => {
  it('rejects the secret holder assigned as taker (free-option mis-assignment)', async () => {
    const s = await sharedSchedule()
    const alice = s.aliceTerms([erc20Asset(fixtureA.erc20, 1n)])
    const bob = s.bobTerms([nativeAsset(1n)])
    try {
      // claiming bob's (later) leg holds the secret here — exactly the
      // configuration CrossChainFreeOption.t.sol attacks
      validateCrossChainSchedule({proposerTerms: bob, takerTerms: alice, minimumBufferSeconds: 1n})
      expect.unreachable()
    } catch (error) {
      expect((error as QuipSwapError).code).toBe('SECRET_HOLDER_NOT_PROPOSER')
    }
  })

  it('rejects a non-interleaved schedule in the SDK AND the contract rejects it on-chain', async () => {
    const {lock} = nextSecret()
    const s = await sharedSchedule()
    const alice = s.aliceTerms([erc20Asset(fixtureA.erc20, 10n)])
    // bob entirely after alice — sequential, no interleave
    const bob: Terms = {
      ...s.bobTerms([nativeAsset(10n)]),
      commitmentDeadline: alice.reclaimRelease + 1000n,
      claimDeadline: alice.reclaimRelease + 2000n,
      reclaimRelease: alice.reclaimRelease + 3000n,
    }
    try {
      validateCrossChainSchedule({proposerTerms: alice, takerTerms: bob, minimumBufferSeconds: 1n})
      expect.unreachable()
    } catch (error) {
      expect((error as QuipSwapError).code).toBe('DISORDERED_DEADLINES')
    }
    // the contract agrees on chain A (raw call bypassing SDK preflight)
    await warpBoth(s.anchors.proposerCommit)
    try {
      await chainA.publicClient.simulateContract({
        address: fixtureA.omnibus,
        abi: omnibusAbi,
        functionName: 'commit',
        args: [
          lock,
          {...alice, assets: alice.assets.map(a => ({...a}))},
          {...bob, assets: bob.assets.map(a => ({...a}))},
        ],
        value: 0n,
        account: chainA.alice.account,
      })
      expect.unreachable()
    } catch (error) {
      expect(extractContractErrorName(error)).toBe('DisordedDeadlines')
    }
  })

  it('rejects an insufficient buffer', async () => {
    const s = await sharedSchedule()
    const alice = s.aliceTerms([erc20Asset(fixtureA.erc20, 1n)])
    const bob = s.bobTerms([nativeAsset(1n)])
    try {
      // every adjacent gap is 1000s; demand more
      validateCrossChainSchedule({proposerTerms: alice, takerTerms: bob, minimumBufferSeconds: 1001n})
      expect.unreachable()
    } catch (error) {
      expect((error as QuipSwapError).code).toBe('INSUFFICIENT_BUFFER')
    }
  })
})

describe('cross-chain unhappy path', () => {
  it('one-leg reclaim: the proposer committed but the taker never did; reclaim after reclaimRelease', async () => {
    const TOKENS = 12_321n
    const {lock} = nextSecret()
    const s = await sharedSchedule()
    const alice = s.aliceTerms([erc20Asset(fixtureA.erc20, TOKENS)])
    const bob = s.bobTerms([nativeAsset(10n)])

    await warpBoth(s.anchors.proposerCommit)
    await waitForOmnibusReceipt(
      chainA.publicClient,
      await aliceOnA.commit({lock, party: alice, counterparty: bob}),
    )
    expect(await aliceOnA.getLockState(lock)).toBe(LockState.Committed)

    // bob never commits. alice reclaims HER leg on chain A after HER release.
    // the counterparty (bob) leg is NOT local to chain A, so only one leg
    // returns and exactly one Reclaimed event is emitted
    await warpBoth(s.anchors.proposerReclaim)
    const reclaimTokensBefore = await chainA.publicClient.readContract({
      address: fixtureA.erc20,
      abi: erc20MockAbi,
      functionName: 'balanceOf',
      args: [ALICE_RECLAIM],
    })
    const result = await waitForOmnibusReceipt(
      chainA.publicClient,
      await aliceOnA.reclaim({lock, party: alice, counterparty: bob}),
    )
    expect(result.reclaims).toHaveLength(1)
    expect(result.reclaims[0]?.recipient.toLowerCase()).toBe(ALICE_RECLAIM.toLowerCase())
    expect(await aliceOnA.getLockState(lock)).toBe(LockState.Spent)
    expect(
      await chainA.publicClient.readContract({
        address: fixtureA.erc20,
        abi: erc20MockAbi,
        functionName: 'balanceOf',
        args: [ALICE_RECLAIM],
      }),
    ).toBe(reclaimTokensBefore + TOKENS)
    // chain B never saw the lock
    expect(await bobOnB.getLockState(lock)).toBe(LockState.Unused)
  })
})
