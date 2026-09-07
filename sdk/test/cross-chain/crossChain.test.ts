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
import {
  DEMO_ALICE_AMOUNT,
  DEMO_BOB_AMOUNT,
  bootstrapDemoEnvironment,
  serializeDemoDeploymentArtifact,
} from '../../scripts/demo/shared/environment.js'
import type {DemoDeploymentArtifact} from '../../scripts/demo/shared/environment.js'
import {runCrossChainRecoveryDemo, validateCrossChainRecoveryArtifact} from '../../scripts/demo/cross-chain/recovery-demo.js'
import {readCrossChainSettlementSnapshot} from '../../scripts/demo/shared/settlement-trace.js'
import {
  fullDemoLogicalFingerprint,
  runFullDemo,
  serializeFullDemo,
  validateFullDemoArtifact,
} from '../../scripts/demo/cross-chain/full-demo.js'
import './trustedWorkflow.test.js'
import type {Address} from 'viem'
import {beforeAll, describe, expect, it} from 'vitest'
import {erc20Asset, nativeAsset} from '../../src/assets.js'
import {keyedAuth} from '../helpers/auth.js'
import type {CommitAuth} from '../../src/commitAuth.js'
import {createOmnibusClient} from '../../src/client.js'
import type {OmnibusClient} from '../../src/client.js'
import {QuipSwapError, extractContractErrorName} from '../../src/errors.js'
import {extractSecretFromClaims} from '../../src/events.js'
import {omnibusAbi} from '../../src/generated/omnibusAbi.js'
import {assetSupportRegistryAbi} from '../../src/generated/assetSupportRegistryAbi.js'
import {crossChainWrapperAbi} from '../../src/generated/crossChainWrapperAbi.js'
import {directAuthorizationAbi} from '../../src/generated/directAuthorizationAbi.js'
import {generateLock} from '../../src/hashing.js'
import {AuthorizationMode, DelegationPolicy} from '../../src/protocol.js'
import type {ProtocolTerms} from '../../src/protocol.js'
import {AssetType, LockState} from '../../src/types.js'
import type {Asset, Hex32, Terms} from '../../src/types.js'
import {validateCrossChainSchedule, verifyRemoteCommitment} from '../../src/workflows/crossChain.js'
import {connectChain, deployFixture, loadArtifact} from '../helpers/chain.js'
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
let deploymentA: PrototypeDeployment
let deploymentB: PrototypeDeployment
let demoDeployment: DemoDeploymentArtifact

interface PrototypeDeployment {
  readonly assetSupportRegistry: Address
  readonly directAuthorization: Address
  readonly crossChainWrapper: Address
  readonly sameChainWrapper: Address
  readonly swapHTLC: Address
  readonly verifier: Address
}

async function deployPrototype(ctx: ChainContext): Promise<PrototypeDeployment> {
  const verifier = await ctx.deploy(loadArtifact('KeyBoundVerifierMock.sol', 'KeyBoundVerifierMock'))
  const assetSupportRegistry = await ctx.deploy(loadArtifact('AssetSupportRegistry.sol', 'AssetSupportRegistry'), [
    ctx.deployer.address,
  ])
  const directAuthorization = await ctx.deploy(loadArtifact('DirectAuthorization.sol', 'DirectAuthorization'), [verifier])
  const swapHTLC = await ctx.deploy(loadArtifact('SwapHTLC.sol', 'SwapHTLC'))
  const crossChainWrapper = await ctx.deploy(loadArtifact('CrossChainWrapper.sol', 'CrossChainWrapper'), [
    directAuthorization,
    assetSupportRegistry,
    swapHTLC,
    ctx.deployer.address,
    10n,
  ])
  const sameChainWrapper = await ctx.deploy(loadArtifact('SameChainWrapper.sol', 'SameChainWrapper'), [
    directAuthorization,
    assetSupportRegistry,
    swapHTLC,
    ctx.deployer.address,
  ])
  return {
    verifier,
    assetSupportRegistry,
    directAuthorization,
    crossChainWrapper,
    sameChainWrapper,
    swapHTLC,
  }
}

// keyedAuth comes from the shared helper — each commit must use ITS OWN
// chain's fixture verifier, so every call site passes its chain's fixture
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
  ;[deploymentA, deploymentB] = await Promise.all([deployPrototype(chainA), deployPrototype(chainB)])
  demoDeployment = await bootstrapDemoEnvironment(chainA, chainB, loadArtifact)
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

describe('v1.1 deployment smoke', () => {
  it('runs the complete deterministic v1.1 demo and emits one combined artifact', async () => {
    const artifact = await runFullDemo(chainA, chainB, loadArtifact)
    expect(() => validateFullDemoArtifact(artifact)).not.toThrow()
    expect(artifact.settlementTrace.finalSnapshots.map(snapshot => snapshot.state)).toEqual(['Claimed', 'Claimed'])
    expect(artifact.authorizationTrace.records).toHaveLength(2)
    expect(artifact.negativeControls.records).toHaveLength(4)
    expect(artifact.clientTrace.at(-1)?.status.workflowStage).toBe('complete')
    expect(artifact.negativeControls.records.every(record => record.stateUnchanged && record.reverted)).toBe(true)
    const operatorTrace = JSON.stringify(artifact.clientTrace)
    expect(operatorTrace).not.toContain(artifact.deterministicSecrets.settlementSecret)
    expect(operatorTrace).not.toContain(artifact.deterministicSecrets.bobCommitSecret)

    const replay = {
      ...artifact,
      authorizationTrace: {
        ...artifact.authorizationTrace,
        records: artifact.authorizationTrace.records.map((record, index) =>
          index === 0 ? {...record, transactionHash: `0x${'11'.repeat(32)}` as const} : record,
        ),
      },
      settlementTrace: {
        ...artifact.settlementTrace,
        transactions: artifact.settlementTrace.transactions.map((record, index) =>
          index === 0 ? {...record, transactionHash: `0x${'22'.repeat(32)}` as const} : record,
        ),
      },
    }
    expect(fullDemoLogicalFingerprint(replay)).toBe(fullDemoLogicalFingerprint(artifact))

    const incomplete = {
      ...artifact,
      settlementTrace: {...artifact.settlementTrace, transactions: artifact.settlementTrace.transactions.slice(0, -1)},
    }
    expect(() => validateFullDemoArtifact(incomplete)).toThrow('settlement trace is incomplete')
    expect(serializeFullDemo(artifact)).toContain('quip-swap-full-demo.v1')
  })

  it('runs live two-chain recovery and terminal-race branches', async () => {
    const artifact = await runCrossChainRecoveryDemo(chainA, chainB, loadArtifact)
    expect(() => validateCrossChainRecoveryArtifact(artifact)).not.toThrow()
    expect(artifact.outcomes.map(outcome => outcome.finalStates.map(state => state.state))).toEqual([
      ['Reclaimed', 'Reclaimed'],
      ['Reclaimed', 'Claimed'],
      ['Claimed', 'Claimed'],
      ['Reclaimed', 'Claimed'],
    ])
    expect(artifact.observations.filter(value => value.lifecycle !== 'final').every(value => !value.advanced)).toBe(true)
  })

  it('emits the deterministic two-chain CREATE3 bootstrap artifact', () => {
    expect(demoDeployment.schema).toBe('quip-swap-demo-deployment.v1')
    expect(demoDeployment.identityRegistration).toBe('lazy-on-first-commit')
    expect(demoDeployment.owner).toBe(chainA.deployer.address)
    expect(demoDeployment.chains.map(chain => chain.chainId)).toEqual([31337, 31338])
    expect(demoDeployment.chains[0].addresses).toEqual(demoDeployment.chains[1].addresses)
    expect(serializeDemoDeploymentArtifact(demoDeployment)).toContain('crossChainWrapper')
  })

  it('records deterministic principal funding and exact wrapper approvals', async () => {
    for (const [ctx, chain, principal, amount] of [
      [chainA, demoDeployment.chains[0], chainA.alice.address, DEMO_ALICE_AMOUNT],
      [chainB, demoDeployment.chains[1], chainB.bob.address, DEMO_BOB_AMOUNT],
    ] as const) {
      expect(chain.funding).toMatchObject({
        assetType: 'ERC20',
        principal,
        owner: principal,
        wrapper: chain.addresses.crossChainWrapper,
        amount: amount.toString(),
        balance: amount.toString(),
        allowance: amount.toString(),
      })
      expect(
        await ctx.publicClient.readContract({
          address: chain.addresses.assetSupportRegistry,
          abi: assetSupportRegistryAbi,
          functionName: 'isSupported',
          args: [AssetType.ERC20, chain.funding.token],
        }),
      ).toBe(true)
      expect(
        await ctx.publicClient.readContract({
          address: chain.funding.token,
          abi: erc20MockAbi,
          functionName: 'allowance',
          args: [principal, chain.addresses.sameChainWrapper],
        }),
      ).toBe(0n)
    }
  })

  it('reads live wrapper-state and balance snapshots for both demo legs', async () => {
    const zeroAddress = getAddress('0x0000000000000000000000000000000000000000')
    const zero32 = `0x${'00'.repeat(32)}` as Hex32
    const terms: ProtocolTerms = {
      partySide: {
        chainId: 31337n, assets: [{assetType: AssetType.ERC20, target: demoDeployment.chains[0].funding.token, id: 0n, amount: DEMO_ALICE_AMOUNT}],
        principal: chainA.alice.address, authorizationMode: AuthorizationMode.RegisteredDirect, principalKeyVersion: 1n,
        reclaimRecipient: chainA.alice.address, recipient: chainB.bob.address, commitmentDeadline: 100n, claimDeadline: 200n, reclaimRelease: 300n,
        commitLock: zero32, delegationPolicy: DelegationPolicy.NotAllowed, delegate: zeroAddress, delegateKeyVersion: 0n, sideNonce: `0x${'22'.repeat(32)}` as Hex32,
      },
      counterpartySide: {
        chainId: 31338n, assets: [{assetType: AssetType.ERC20, target: demoDeployment.chains[1].funding.token, id: 0n, amount: DEMO_BOB_AMOUNT}],
        principal: chainB.bob.address, authorizationMode: AuthorizationMode.RegisteredDirect, principalKeyVersion: 1n,
        reclaimRecipient: chainB.bob.address, recipient: chainA.alice.address, commitmentDeadline: 150n, claimDeadline: 250n, reclaimRelease: 350n,
        commitLock: `0x${'33'.repeat(32)}` as Hex32, delegationPolicy: DelegationPolicy.NotAllowed, delegate: zeroAddress, delegateKeyVersion: 0n, sideNonce: `0x${'44'.repeat(32)}` as Hex32,
      },
    }
    const lock = `0x${'55'.repeat(32)}` as Hex32
    const [alice, bob] = await Promise.all([
      readCrossChainSettlementSnapshot({publicClient: chainA.publicClient, chainId: 31337, wrapper: demoDeployment.chains[0].addresses.crossChainWrapper, terms, party: true, lock, holdings: [{assetType: 'erc20', token: demoDeployment.chains[0].funding.token, account: chainA.alice.address}, {assetType: 'erc20', token: demoDeployment.chains[0].funding.token, account: demoDeployment.chains[0].addresses.crossChainWrapper}]}),
      readCrossChainSettlementSnapshot({publicClient: chainB.publicClient, chainId: 31338, wrapper: demoDeployment.chains[1].addresses.crossChainWrapper, terms, party: false, lock, holdings: [{assetType: 'erc20', token: demoDeployment.chains[1].funding.token, account: chainB.bob.address}, {assetType: 'erc20', token: demoDeployment.chains[1].funding.token, account: demoDeployment.chains[1].addresses.crossChainWrapper}]}),
    ])
    expect([alice.state, bob.state]).toEqual(['Unused', 'Unused'])
    expect(alice.holdings.map(holding => 'balance' in holding ? holding.balance : null)).toEqual([DEMO_ALICE_AMOUNT.toString(), '0'])
    expect(bob.holdings.map(holding => 'balance' in holding ? holding.balance : null)).toEqual([DEMO_BOB_AMOUNT.toString(), '0'])
  })

  it('reproduces the same address graph and immutable configuration on both chains', async () => {
    expect(deploymentB).toEqual(deploymentA)
    for (const [ctx, deployment] of [
      [chainA, deploymentA],
      [chainB, deploymentB],
    ] as const) {
      expect(
        await ctx.publicClient.readContract({
          address: deployment.directAuthorization,
          abi: directAuthorizationAbi,
          functionName: 'TRUSTED_VERIFIER',
        }),
      ).toBe(deployment.verifier)
      expect(
        await ctx.publicClient.readContract({
          address: deployment.crossChainWrapper,
          abi: crossChainWrapperAbi,
          functionName: 'DIRECT_AUTHORIZATION',
        }),
      ).toBe(deployment.directAuthorization)
    }
  })
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
    // Chain A receipt decoded against Chain A's Omnibus (aliceOnA is bound to it)
    await aliceOnA.waitForReceipt(await aliceOnA.commit({lock, party: alice, counterparty: bob, auth: keyedAuth(fixtureA, chainA.alice.address)}))
    expect(await aliceOnA.getLockState(lock)).toBe(LockState.Committed)
    expect(await bobOnB.getLockState(lock)).toBe(LockState.Unused) // B untouched

    // 3. Bob's MANDATORY off-chain verification of Alice's remote commitment
    // (the chain B contract cannot do this for him)
    const remote = await verifyRemoteCommitment(bobOnA, lock, alice, bob)
    expect(remote).toMatchObject({committed: true, lockState: LockState.Committed, termsHashMatches: true})

    // ...then Bob commits his leg ON CHAIN B inside the taker window.
    // Decoded against Chain B's Omnibus (bobOnB is bound to it), NOT Chain A.
    await warpBoth(s.anchors.takerCommit)
    await bobOnB.waitForReceipt(await bobOnB.commit({lock, party: bob, counterparty: alice, auth: keyedAuth(fixtureB, chainB.bob.address)}))
    expect(await bobOnB.getLockState(lock)).toBe(LockState.Committed)

    // 4. Alice claims Bob's leg ON CHAIN B in the proposer-claim window —
    // this transaction publicly REVEALS the secret on chain B. The receipt
    // is decoded against Chain B's Omnibus via aliceOnB.
    await warpBoth(s.anchors.proposerClaim)
    const aliceRecipientNativeBefore = await chainB.publicClient.getBalance({address: ALICE_RECIPIENT})
    const claimB = await aliceOnB.waitForReceipt(await aliceOnB.claim({secret, party: alice, counterparty: bob}))
    expect(await bobOnB.getLockState(lock)).toBe(LockState.Spent)
    // bob's native (counterparty leg) went to ALICE's recipient on chain B
    expect(await chainB.publicClient.getBalance({address: ALICE_RECIPIENT})).toBe(
      aliceRecipientNativeBefore + NATIVE,
    )

    // 5. Bob (or a relayer) extracts the revealed secret from the chain B
    // Claim event — from the address-SCOPED decoded claims, not raw logs.
    const revealed = extractSecretFromClaims(claimB.claims, lock)
    expect(revealed).toBe(secret)

    // duplicate Claim-event processing is idempotent: feeding the same scoped
    // claims twice yields the same single secret
    expect(extractSecretFromClaims([...claimB.claims, ...claimB.claims], lock)).toBe(secret)

    // 6. Bob claims Alice's leg ON CHAIN A in the taker-claim window
    if (revealed === undefined) throw new Error('secret must have been revealed')
    await warpBoth(s.anchors.takerClaim)
    const bobRecipientTokensBefore = await chainA.publicClient.readContract({
      address: fixtureA.erc20,
      abi: erc20MockAbi,
      functionName: 'balanceOf',
      args: [BOB_RECIPIENT],
    })
    // Chain A receipt decoded against Chain A's Omnibus via bobOnA
    await bobOnA.waitForReceipt(await bobOnA.claim({secret: revealed, party: bob, counterparty: alice}))

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
          keyedAuth(fixtureA, chainA.alice.address),
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
    await aliceOnA.waitForReceipt(await aliceOnA.commit({lock, party: alice, counterparty: bob, auth: keyedAuth(fixtureA, chainA.alice.address)}))
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
    const result = await aliceOnA.waitForReceipt(await aliceOnA.reclaim({lock, party: alice, counterparty: bob}))
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
