/**
 * Single-chain Anvil integration tests for the SDK against the REAL
 * Omnibus + mock tokens (no mocked RPC clients).
 *
 * Parallels the Foundry scenario suites (`test/Omnibus/scenario/*.t.sol`)
 * and uses the same timing model as `test/Omnibus/Omnibus.t.sol`: one
 * strictly interleaved schedule per swap (Alice = proposer, Bob = taker)
 * with warp anchors strictly inside each window. Block timestamps are
 * driven with evm_setNextBlockTimestamp + mining; schedules are derived
 * from the chain's CURRENT timestamp so files and tests compose (Anvil
 * time only moves forward).
 *
 * Run via `bun run test:integration` (the runner starts Anvil, builds
 * artifacts, and sets QUIP_SDK_RPC_URL / QUIP_SDK_CHAIN_ID).
 */
import {createWalletClient, getAddress, http, keccak256, stringToHex, toHex} from 'viem'
import type {Address, Hash} from 'viem'
import {privateKeyToAccount} from 'viem/accounts'
import {beforeAll, describe, expect, it} from 'vitest'
import {planApprovals, submitApproval} from '../../src/approvals.js'
import {erc1155Asset, erc20Asset, erc721Asset, nativeAsset, totalNative} from '../../src/assets.js'
import {createOmnibusClient} from '../../src/client.js'
import type {OmnibusClient} from '../../src/client.js'
import {COMMIT_DIGEST_TAG, buildKeyedSigner, computeCommitDigest, computeDomainSeparator} from '../../src/commitAuth.js'
import type {CommitAuth} from '../../src/commitAuth.js'
import {QuipSwapError, extractContractErrorName} from '../../src/errors.js'
import {omnibusAbi} from '../../src/generated/omnibusAbi.js'
import {digestTerms, digestTermsCanonically, generateLock, swapId} from '../../src/hashing.js'
import {waitForOmnibusReceipt} from '../../src/receipts.js'
import type {OmnibusReceipt} from '../../src/receipts.js'
import {MAX_ASSETS_PER_SIDE} from '../../src/terms.js'
import {LockState} from '../../src/types.js'
import type {Asset, Hex32, Terms} from '../../src/types.js'
import {keyedAuth as keyedAuthFor, deregisterWallet, registerWallet, walletAuth} from '../helpers/auth.js'
import {connectChain, deployFixture, loadArtifact} from '../helpers/chain.js'
import type {ChainContext, Fixture, TestActor} from '../helpers/chain.js'
import {erc1155MockAbi, erc20MockAbi, erc721MockAbi} from '../helpers/mockAbis.js'

const RPC_URL = process.env['QUIP_SDK_RPC_URL']
const CHAIN_ID = Number(process.env['QUIP_SDK_CHAIN_ID'] ?? '31337')

if (RPC_URL === undefined) {
  throw new Error('QUIP_SDK_RPC_URL is not set — run this suite via `bun run test:integration`')
}

// dedicated recipient addresses (plain, key-less) so balance deltas are
// clean; checksummed so decoded event Terms compare equal byte-for-byte
const ALICE_RECIPIENT: Address = getAddress('0x00000000000000000000000000000000000a0001')
const BOB_RECIPIENT: Address = getAddress('0x00000000000000000000000000000000000b0002')
const ALICE_RECLAIM: Address = getAddress('0x00000000000000000000000000000000000a0003')
const BOB_RECLAIM: Address = getAddress('0x00000000000000000000000000000000000b0004')

let ctx: ChainContext
let fixture: Fixture
let aliceClient: OmnibusClient
let bobClient: OmnibusClient
let charlieClient: OmnibusClient
let ownerClient: OmnibusClient

/** Deterministic per-test secrets: keccak256 of an incrementing counter. */
let secretCounter = 0
function nextSecret(): {secret: Hex32; lock: Hex32} {
  const secret = keccak256(toHex(++secretCounter, {size: 32}))
  return {secret, lock: generateLock(secret)}
}

/** One swap's schedule and warp anchors, derived from the chain's current time. */
interface Schedule {
  readonly anchors: {
    proposerCommit: bigint
    takerCommit: bigint
    proposerClaim: bigint
    takerClaim: bigint
    proposerReclaim: bigint
    takerReclaim: bigint
  }
  aliceTerms(assets: readonly Asset[], chainId?: bigint): Terms
  bobTerms(assets: readonly Asset[], chainId?: bigint): Terms
}

/**
 * Builds a fresh interleaved schedule starting from the chain's current
 * timestamp (the same 1000s-step shape as the Foundry suite, anchors at
 * +500 inside each window).
 */
async function freshSchedule(): Promise<Schedule> {
  const base = await ctx.now()
  const anchors = {
    proposerCommit: base + 500n,
    takerCommit: base + 1500n,
    proposerClaim: base + 2500n,
    takerClaim: base + 3500n,
    proposerReclaim: base + 5500n,
    takerReclaim: base + 6500n,
  }
  return {
    anchors,
    aliceTerms: (assets, chainId = BigInt(CHAIN_ID)) => ({
      chainId,
      reclaimRecipient: ALICE_RECLAIM,
      recipient: ALICE_RECIPIENT,
      commitmentDeadline: base + 1000n,
      claimDeadline: base + 3000n,
      reclaimRelease: base + 5000n,
      assets,
    }),
    bobTerms: (assets, chainId = BigInt(CHAIN_ID)) => ({
      chainId,
      reclaimRecipient: BOB_RECLAIM,
      recipient: BOB_RECIPIENT,
      commitmentDeadline: base + 2000n,
      claimDeadline: base + 4000n,
      reclaimRelease: base + 6000n,
      assets,
    }),
  }
}

/** Asserts an async call reverts with the given decoded contract error. */
async function expectContractError(promise: Promise<unknown>, errorName: string): Promise<void> {
  try {
    await promise
    expect.unreachable(`expected revert ${errorName}`)
  } catch (error) {
    if (error instanceof QuipSwapError) {
      expect(error.contractErrorName, `expected ${errorName}, got SDK code ${error.code}`).toBe(errorName)
      return
    }
    expect(extractContractErrorName(error), String(error)).toBe(errorName)
  }
}

/** Raw commit through viem, bypassing SDK preflight (for contract-level negative tests). */
async function rawCommit(
  actor: TestActor,
  lock: Hex32,
  party: Terms,
  counterparty: Terms,
  value: bigint,
  auth?: CommitAuth,
) {
  const {request} = await ctx.publicClient.simulateContract({
    address: fixture.omnibus,
    abi: omnibusAbi,
    functionName: 'commit',
    args: [lock, toTuple(party), toTuple(counterparty), auth ?? keyedAuth(actor.address)],
    value,
    account: actor.account,
  })
  const hash = await actor.walletClient.writeContract(request)
  return ctx.publicClient.waitForTransactionReceipt({hash})
}

function toTuple(terms: Terms) {
  return {
    chainId: terms.chainId,
    reclaimRecipient: terms.reclaimRecipient,
    recipient: terms.recipient,
    commitmentDeadline: terms.commitmentDeadline,
    claimDeadline: terms.claimDeadline,
    reclaimRelease: terms.reclaimRelease,
    assets: terms.assets.map(a => ({assetType: a.assetType, target: a.target, id: a.id, amount: a.amount})),
  }
}

/** ERC-20 balance helper. */
async function erc20Balance(token: Address, account: Address): Promise<bigint> {
  return ctx.publicClient.readContract({address: token, abi: erc20MockAbi, functionName: 'balanceOf', args: [account]})
}

/**
 * Address-scoped receipt wait bound to this suite's single Omnibus — every
 * decode is filtered to `fixture.omnibus`, mirroring `client.waitForReceipt`.
 */
function confirmReceipt(hash: Hash): Promise<OmnibusReceipt> {
  return waitForOmnibusReceipt(ctx.publicClient, hash, {address: fixture.omnibus})
}

/** Keyed ERC-7913 auth for an actor via the shared helper, bound to this suite's fixture. */
const keyedAuth = (addr: Address): CommitAuth => keyedAuthFor(fixture, addr)

beforeAll(async () => {
  ctx = connectChain(RPC_URL, CHAIN_ID)
  fixture = await deployFixture(ctx)

  const mkClient = (actor: TestActor): OmnibusClient =>
    createOmnibusClient({address: fixture.omnibus, publicClient: ctx.publicClient, walletClient: actor.walletClient})
  aliceClient = mkClient(ctx.alice)
  bobClient = mkClient(ctx.bob)
  charlieClient = mkClient(ctx.charlie)
  ownerClient = mkClient(ctx.deployer)

  // mint working balances and grant blanket ERC-20/ERC-1155 approvals for
  // alice and bob (the approval-planner tests use the UNAPPROVED fee token
  // and fresh NFTs so they still exercise the missing-approval paths)
  for (const actor of [ctx.alice, ctx.bob]) {
    for (const [address, abi, fn, args] of [
      [fixture.erc20, erc20MockAbi, 'mint', [actor.address, 10n ** 24n]],
      [fixture.erc1155, erc1155MockAbi, 'mint', [actor.address, 1n, 1_000_000n, '0x']],
      [fixture.erc20, erc20MockAbi, 'approve', [fixture.omnibus, (1n << 256n) - 1n]],
      [fixture.erc1155, erc1155MockAbi, 'setApprovalForAll', [fixture.omnibus, true]],
    ] as const) {
      const hash = await actor.walletClient.writeContract({
        address: address as Address,
        abi: abi as never,
        functionName: fn as never,
        args: args as never,
        chain: ctx.publicClient.chain ?? null,
        account: actor.account,
      })
      await ctx.publicClient.waitForTransactionReceipt({hash})
    }
  }
})

// ---------------------------------------------------------------------------
// reads
// ---------------------------------------------------------------------------

describe('read methods', () => {
  it('reads VERSION, MAX_FEE, commitmentFee, accruedFees', async () => {
    expect(await aliceClient.getVersion()).toBe(stringToHex('QUIP:Omnibus:sdk-test', {size: 32}))
    expect(await aliceClient.getMaxFee()).toBe(10n ** 16n) // 0.01 ether
    expect(await aliceClient.getCommitmentFee()).toBe(0n)
    expect(await aliceClient.getAccruedFees()).toBe(0n)
  })

  it('isVerifierActive is false for an arbitrary address; the owner can flip it', async () => {
    const verifier: Address = getAddress('0x00000000000000000000000000000000000e7913')
    expect(await aliceClient.isVerifierActive(verifier)).toBe(false)
    await ctx.publicClient.waitForTransactionReceipt({
      hash: await ownerClient.admin.setVerifierActivity(verifier, true),
    })
    expect(await aliceClient.isVerifierActive(verifier)).toBe(true)
    await ctx.publicClient.waitForTransactionReceipt({
      hash: await ownerClient.admin.setVerifierActivity(verifier, false),
    })
    expect(await aliceClient.isVerifierActive(verifier)).toBe(false)
  })

  it('setVerifierActivity is owner-only', async () => {
    const verifier: Address = getAddress('0x00000000000000000000000000000000000e7914')
    await expectContractError(charlieClient.admin.setVerifierActivity(verifier, true), 'OwnableUnauthorizedAccount')
  })

  it('reads lockState, termsHash, posted for an unused swap id', async () => {
    // any never-written key reads as empty state; a bare lock is one such key
    const {lock} = nextSecret()
    expect(await aliceClient.getLockState(lock)).toBe(LockState.Unused)
    expect(await aliceClient.getTermsHash(lock)).toBe(`0x${'00'.repeat(32)}`)
    expect(await aliceClient.getPosted(lock, `0x${'11'.repeat(32)}`)).toBe(false)
  })

  it('reads owner and pendingOwner', async () => {
    expect((await aliceClient.getOwner()).toLowerCase()).toBe(ctx.deployer.address.toLowerCase())
    expect(await aliceClient.getPendingOwner()).toBe('0x0000000000000000000000000000000000000000')
  })
})

// ---------------------------------------------------------------------------
// commit authorization (permissionless)
// ---------------------------------------------------------------------------

describe('commit authorization', () => {
  it('commit is PERMISSIONLESS: any funded EOA commits with a keyed identity', async () => {
    // charlie is an arbitrary third party — no registry, no gate; the
    // sender funds the leg + fee and his keyed identity endorses the payload
    const {lock} = nextSecret()
    const s = await freshSchedule()
    const alice = s.aliceTerms([nativeAsset(10n)])
    const bob = s.bobTerms([erc20Asset(fixture.erc20, 10n)])
    await ctx.warpTo(s.anchors.proposerCommit)
    const receipt = await confirmReceipt(
      await charlieClient.commit({lock, party: alice, counterparty: bob, auth: keyedAuth(ctx.charlie.address)}),
    )
    expect(receipt.commitments).toHaveLength(1)
    expect(receipt.commitments[0]?.sender.toLowerCase()).toBe(ctx.charlie.address.toLowerCase())
    expect(receipt.commitments[0]?.signer.toLowerCase()).toBe(keyedAuth(ctx.charlie.address).signer.toLowerCase())
  })

  it('a malformed auth.signer rejects MALFORMED_SIGNER in preflight; the contract agrees (MalformedSigner)', async () => {
    const {lock} = nextSecret()
    const s = await freshSchedule()
    const alice = s.aliceTerms([nativeAsset(10n)])
    const bob = s.bobTerms([erc20Asset(fixture.erc20, 10n)])
    await ctx.warpTo(s.anchors.proposerCommit)

    // SDK preflight: rejected before any transaction exists
    try {
      await aliceClient.commit({lock, party: alice, counterparty: bob, auth: {signer: '0x1234', signature: '0x'}})
      expect.unreachable()
    } catch (error) {
      expect(error).toBeInstanceOf(QuipSwapError)
      expect((error as QuipSwapError).code).toBe('MALFORMED_SIGNER')
    }
    expect(await aliceClient.getLockState(swapId(lock, alice, bob))).toBe(LockState.Unused) // nothing reached the chain

    // the contract enforces the same rule (raw call bypassing preflight)
    await expectContractError(
      rawCommit(ctx.alice, lock, alice, bob, 10n, {signer: '0x1234', signature: '0x'}),
      'MalformedSigner',
    )
  })

  it('a leg padded past MAX_ASSETS_PER_SIDE rejects TOO_MANY_ASSETS in preflight; the contract agrees (TooManyAssets)', async () => {
    // the gas-griefing padded leg (thousands of one-wei native entries) is bounded so
    // settling both legs together can never exceed the block gas limit
    const {lock} = nextSecret()
    const s = await freshSchedule()
    const padded = Array.from({length: MAX_ASSETS_PER_SIDE + 1}, () => nativeAsset(1n))
    const alice = s.aliceTerms(padded)
    const bob = s.bobTerms([erc20Asset(fixture.erc20, 10n)])
    await ctx.warpTo(s.anchors.proposerCommit)

    try {
      await aliceClient.commit({lock, party: alice, counterparty: bob, auth: keyedAuth(ctx.alice.address)})
      expect.unreachable()
    } catch (error) {
      expect(error).toBeInstanceOf(QuipSwapError)
      expect((error as QuipSwapError).code).toBe('TOO_MANY_ASSETS')
    }
    expect(await aliceClient.getLockState(swapId(lock, alice, bob))).toBe(LockState.Unused)

    // the contract enforces the same cap (raw call bypassing preflight)
    await expectContractError(
      rawCommit(ctx.alice, lock, alice, bob, BigInt(MAX_ASSETS_PER_SIDE + 1)),
      'TooManyAssets',
    )
  })

  it('a keyed signer whose verifier was never activated reverts on-chain (VerifierNotActive)', async () => {
    const {lock} = nextSecret()
    const s = await freshSchedule()
    const alice = s.aliceTerms([nativeAsset(10n)])
    const bob = s.bobTerms([erc20Asset(fixture.erc20, 10n)])
    await ctx.warpTo(s.anchors.proposerCommit)
    // well-formed 40-byte keyed blob, but the declared "verifier" (alice's
    // EOA address) was never activated by the owner. The signature must be
    // NON-EMPTY: an empty one would select the wallet route, which never
    // consults the verifier
    await expectContractError(
      rawCommit(ctx.bob, lock, alice, bob, 10n, {
        signer: buildKeyedSigner(ctx.alice.address, ctx.alice.address),
        signature: '0x656e76656c6f7065',
      }),
      'VerifierNotActive',
    )
  })

  it('wallet route: an empty signature commits iff the sender is registered in the wallet factory', async () => {
    // register bob as a "factory-deployed quip wallet" in the settable
    // registry mock; his identity blob rides along as attribution only
    await registerWallet(ctx, fixture, ctx.bob.address)

    const {lock} = nextSecret()
    const s = await freshSchedule()
    const alice = s.aliceTerms([nativeAsset(10n)])
    const bob = s.bobTerms([erc20Asset(fixture.erc20, 10n)])
    await ctx.warpTo(s.anchors.proposerCommit)

    const auth = walletAuth(fixture, ctx.bob.address)
    const receipt = await confirmReceipt(
      await bobClient.commit({lock, party: alice, counterparty: bob, auth}),
    )
    expect(receipt.commitments).toHaveLength(1)
    expect(receipt.commitments[0]?.sender.toLowerCase()).toBe(ctx.bob.address.toLowerCase())
    expect(receipt.commitments[0]?.signer.toLowerCase()).toBe(auth.signer.toLowerCase())

    // deregister to restore the fixture invariant (no actor is a wallet)
    await deregisterWallet(ctx, fixture, ctx.bob.address)
  })

  it('wallet route: an unregistered sender is rejected in preflight (NOT_QUIP_WALLET) and on-chain (NotQuipWallet)', async () => {
    const {lock} = nextSecret()
    const s = await freshSchedule()
    const alice = s.aliceTerms([nativeAsset(10n)])
    const bob = s.bobTerms([erc20Asset(fixture.erc20, 10n)])
    await ctx.warpTo(s.anchors.proposerCommit)

    // SDK preflight: rejected before any transaction exists
    try {
      await aliceClient.commit({lock, party: alice, counterparty: bob, auth: walletAuth(fixture, ctx.alice.address)})
      expect.unreachable()
    } catch (error) {
      expect(error).toBeInstanceOf(QuipSwapError)
      expect((error as QuipSwapError).code).toBe('NOT_QUIP_WALLET')
    }
    expect(await aliceClient.getLockState(swapId(lock, alice, bob))).toBe(LockState.Unused) // nothing reached the chain

    // the contract enforces the same rule (raw call bypassing preflight):
    // membership is checked against the actual sender, regardless of the
    // declared identity
    await expectContractError(
      rawCommit(ctx.alice, lock, alice, bob, 10n, walletAuth(fixture, ctx.alice.address)),
      'NotQuipWallet',
    )
  })

  it('isQuipWallet and getWalletFactory read the factory surface', async () => {
    expect((await aliceClient.getWalletFactory()).toLowerCase()).toBe(fixture.walletFactory.toLowerCase())
    expect(await aliceClient.isQuipWallet(ctx.alice.address)).toBe(false)
    await registerWallet(ctx, fixture, ctx.alice.address)
    expect(await aliceClient.isQuipWallet(ctx.alice.address)).toBe(true)
    await deregisterWallet(ctx, fixture, ctx.alice.address)
    expect(await aliceClient.isQuipWallet(ctx.alice.address)).toBe(false)
  })

  it('claim and reclaim succeed from an arbitrary third-party account', async () => {
    // full swap, then charlie (uninvolved third party) claims with the
    // secret — claim is permissionless by design
    const {secret, lock} = nextSecret()
    const s = await freshSchedule()
    const alice = s.aliceTerms([nativeAsset(1000n)])
    const bob = s.bobTerms([erc20Asset(fixture.erc20, 500n)])

    await ctx.warpTo(s.anchors.proposerCommit)
    await confirmReceipt(await aliceClient.commit({lock, party: alice, counterparty: bob, auth: keyedAuth(ctx.alice.address)}))
    await ctx.warpTo(s.anchors.takerCommit)
    await confirmReceipt(await bobClient.commit({lock, party: bob, counterparty: alice, auth: keyedAuth(ctx.bob.address)}))
    await ctx.warpTo(s.anchors.proposerClaim)
    const hash = await charlieClient.claim({secret, party: alice, counterparty: bob})
    const result = await confirmReceipt(hash)
    // same-chain claim emits one Claim per leg; neither recipient is charlie (the caller)
    expect(result.claims).toHaveLength(2)
    expect(result.claims.map(c => c.recipient.toLowerCase())).not.toContain(ctx.charlie.address.toLowerCase())
    expect(await aliceClient.getLockState(swapId(lock, alice, bob))).toBe(LockState.Spent)
  })
})

// ---------------------------------------------------------------------------
// native commits and fees
// ---------------------------------------------------------------------------

describe('native commits and fee handling', () => {
  it('exact native amount plus fee succeeds and the fee accrues', async () => {
    // owner sets a non-zero fee; the SDK re-reads it before simulating
    const FEE = 12_345n
    await ctx.publicClient.waitForTransactionReceipt({hash: await ownerClient.admin.setCommitmentFee(FEE)})
    expect(await aliceClient.getCommitmentFee()).toBe(FEE)

    const accruedBefore = await aliceClient.getAccruedFees()
    const {lock} = nextSecret()
    const s = await freshSchedule()
    const alice = s.aliceTerms([nativeAsset(777n)])
    const bob = s.bobTerms([erc20Asset(fixture.erc20, 10n)])
    await ctx.warpTo(s.anchors.proposerCommit)
    await confirmReceipt(await aliceClient.commit({lock, party: alice, counterparty: bob, auth: keyedAuth(ctx.alice.address)}))

    expect(await aliceClient.getLockState(swapId(lock, alice, bob))).toBe(LockState.Free)
    expect(await aliceClient.getAccruedFees()).toBe(accruedBefore + FEE)

    // reset the fee so later tests run with fee 0
    await ctx.publicClient.waitForTransactionReceipt({hash: await ownerClient.admin.setCommitmentFee(0n)})
  })

  it('underpayment and overpayment both revert IncorrectNativeAmountReceived', async () => {
    const {lock} = nextSecret()
    const s = await freshSchedule()
    const alice = s.aliceTerms([nativeAsset(1000n)])
    const bob = s.bobTerms([erc20Asset(fixture.erc20, 10n)])
    await ctx.warpTo(s.anchors.proposerCommit)
    const exact = totalNative(alice) + (await aliceClient.getCommitmentFee())
    // raw calls bypass the SDK's exact-value calculation on purpose
    await expectContractError(rawCommit(ctx.alice, lock, alice, bob, exact - 1n), 'IncorrectNativeAmountReceived')
    await expectContractError(rawCommit(ctx.alice, lock, alice, bob, exact + 1n), 'IncorrectNativeAmountReceived')
  })

  it('owner can withdraw accrued fees; non-owner cannot set the fee', async () => {
    await expectContractError(charlieClient.admin.setCommitmentFee(1n), 'OwnableUnauthorizedAccount')
    const accrued = await ownerClient.getAccruedFees()
    const target: Address = '0x00000000000000000000000000000000000fee01'
    await ctx.publicClient.waitForTransactionReceipt({hash: await ownerClient.admin.withdrawFees(target)})
    expect(await ctx.publicClient.getBalance({address: target})).toBe(accrued)
    expect(await ownerClient.getAccruedFees()).toBe(0n)
  })

  it('setCommitmentFee above MAX_FEE reverts FeeExceedsMax', async () => {
    await expectContractError(ownerClient.admin.setCommitmentFee(10n ** 16n + 1n), 'FeeExceedsMax')
  })
})

// ---------------------------------------------------------------------------
// approvals
// ---------------------------------------------------------------------------

describe('approval planning', () => {
  it('detects a missing ERC-20 approval, fixes it via submitApproval, then commit pulls the balance', async () => {
    // the fee-token was never approved by alice — but use a fresh plain
    // mint of the standard token to charlie's slot instead: simplest is the
    // never-approved feeERC20 read path for detection only
    const {lock} = nextSecret()
    const s = await freshSchedule()

    // detection: alice never approved feeERC20
    const feeTerms = s.aliceTerms([erc20Asset(fixture.feeERC20, 100n)])
    const plan = await planApprovals({
      publicClient: ctx.publicClient,
      omnibusAddress: fixture.omnibus,
      committer: ctx.alice.address,
      terms: feeTerms,
    })
    expect(plan.satisfied).toBe(false)
    expect(plan.items[0]).toMatchObject({kind: 'erc20', satisfied: false, requiredAllowance: 100n})

    // approval succeeds (exact mode — the SDK never defaults to unlimited)
    const item = plan.items[0]
    if (item === undefined) throw new Error('plan should have one item')
    const approveHash = await submitApproval({
      publicClient: ctx.publicClient,
      walletClient: ctx.alice.walletClient,
      omnibusAddress: fixture.omnibus,
      item,
      erc20Mode: 'exact',
    })
    await ctx.publicClient.waitForTransactionReceipt({hash: approveHash})
    const replanned = await planApprovals({
      publicClient: ctx.publicClient,
      omnibusAddress: fixture.omnibus,
      committer: ctx.alice.address,
      terms: feeTerms,
    })
    expect(replanned.satisfied).toBe(true)

    // commit with the STANDARD token pulls the correct balance into Omnibus
    const alice = s.aliceTerms([erc20Asset(fixture.erc20, 5000n)])
    const bob = s.bobTerms([nativeAsset(10n)])
    const omnibusBefore = await erc20Balance(fixture.erc20, fixture.omnibus)
    const aliceBefore = await erc20Balance(fixture.erc20, ctx.alice.address)
    await ctx.warpTo(s.anchors.proposerCommit)
    await confirmReceipt(await aliceClient.commit({lock, party: alice, counterparty: bob, auth: keyedAuth(ctx.alice.address)}))
    expect(await erc20Balance(fixture.erc20, fixture.omnibus)).toBe(omnibusBefore + 5000n)
    expect(await erc20Balance(fixture.erc20, ctx.alice.address)).toBe(aliceBefore - 5000n)
  })

  it('aggregates repeated ERC-20 entries into one allowance requirement', async () => {
    const s = await freshSchedule()
    const terms = s.aliceTerms([erc20Asset(fixture.feeERC20, 60n), erc20Asset(fixture.feeERC20, 40n)])
    const plan = await planApprovals({
      publicClient: ctx.publicClient,
      omnibusAddress: fixture.omnibus,
      committer: ctx.bob.address,
      terms,
    })
    expect(plan.items).toHaveLength(1)
    expect(plan.items[0]).toMatchObject({kind: 'erc20', requiredAllowance: 100n})
  })
})

// ---------------------------------------------------------------------------
// ERC-721
// ---------------------------------------------------------------------------

describe('ERC-721 flows', () => {
  let nftCounter = 7000n
  async function mintNft(actor: TestActor): Promise<bigint> {
    const tokenId = ++nftCounter
    const hash = await actor.walletClient.writeContract({
      address: fixture.erc721,
      abi: erc721MockAbi,
      functionName: 'mint',
      args: [actor.address, tokenId],
      chain: ctx.publicClient.chain ?? null,
      account: actor.account,
    })
    await ctx.publicClient.waitForTransactionReceipt({hash})
    return tokenId
  }
  async function ownerOf(tokenId: bigint): Promise<Address> {
    return ctx.publicClient.readContract({
      address: fixture.erc721,
      abi: erc721MockAbi,
      functionName: 'ownerOf',
      args: [tokenId],
    })
  }

  it('single-token approval satisfies the planner; ownership moves on commit and claim', async () => {
    const tokenId = await mintNft(ctx.alice)
    const {secret, lock} = nextSecret()
    const s = await freshSchedule()
    const alice = s.aliceTerms([erc721Asset(fixture.erc721, tokenId)])
    const bob = s.bobTerms([erc20Asset(fixture.erc20, 100n)])

    // planner flags the missing approval, then single-token approval fixes it
    const before = await planApprovals({
      publicClient: ctx.publicClient,
      omnibusAddress: fixture.omnibus,
      committer: ctx.alice.address,
      terms: alice,
    })
    expect(before.satisfied).toBe(false)
    const item = before.items[0]
    if (item === undefined) throw new Error('expected one approval item')
    const approveHash = await submitApproval({
      publicClient: ctx.publicClient,
      walletClient: ctx.alice.walletClient,
      omnibusAddress: fixture.omnibus,
      item,
      erc721Mode: 'token',
    })
    await ctx.publicClient.waitForTransactionReceipt({hash: approveHash})
    const after = await planApprovals({
      publicClient: ctx.publicClient,
      omnibusAddress: fixture.omnibus,
      committer: ctx.alice.address,
      terms: alice,
    })
    expect(after.items[0]).toMatchObject({kind: 'erc721', tokenApproved: true, satisfied: true})

    // commit escrows the NFT in Omnibus
    await ctx.warpTo(s.anchors.proposerCommit)
    await confirmReceipt(await aliceClient.commit({lock, party: alice, counterparty: bob, auth: keyedAuth(ctx.alice.address)}))
    expect((await ownerOf(tokenId)).toLowerCase()).toBe(fixture.omnibus.toLowerCase())

    // taker commits, proposer claims: alice's NFT goes to BOB's recipient
    // (recipient receives the COUNTERPARTY's assets)
    await ctx.warpTo(s.anchors.takerCommit)
    await confirmReceipt(await bobClient.commit({lock, party: bob, counterparty: alice, auth: keyedAuth(ctx.bob.address)}))
    await ctx.warpTo(s.anchors.proposerClaim)
    await confirmReceipt(await aliceClient.claim({secret, party: alice, counterparty: bob}),
    )
    expect((await ownerOf(tokenId)).toLowerCase()).toBe(BOB_RECIPIENT.toLowerCase())
  })

  it('operator approval also satisfies the planner', async () => {
    const tokenId = await mintNft(ctx.bob)
    const s = await freshSchedule()
    const terms = s.bobTerms([erc721Asset(fixture.erc721, tokenId)])
    const before = await planApprovals({
      publicClient: ctx.publicClient,
      omnibusAddress: fixture.omnibus,
      committer: ctx.bob.address,
      terms,
    })
    expect(before.satisfied).toBe(false)
    const item = before.items[0]
    if (item === undefined) throw new Error('expected one approval item')
    const hash = await submitApproval({
      publicClient: ctx.publicClient,
      walletClient: ctx.bob.walletClient,
      omnibusAddress: fixture.omnibus,
      item,
      erc721Mode: 'operator',
    })
    await ctx.publicClient.waitForTransactionReceipt({hash})
    const after = await planApprovals({
      publicClient: ctx.publicClient,
      omnibusAddress: fixture.omnibus,
      committer: ctx.bob.address,
      terms,
    })
    expect(after.items[0]).toMatchObject({kind: 'erc721', operatorApproved: true, satisfied: true})
  })
})

// ---------------------------------------------------------------------------
// ERC-1155
// ---------------------------------------------------------------------------

describe('ERC-1155 flows', () => {
  async function balance1155(account: Address, id: bigint): Promise<bigint> {
    return ctx.publicClient.readContract({
      address: fixture.erc1155,
      abi: erc1155MockAbi,
      functionName: 'balanceOf',
      args: [account, id],
    })
  }

  it('operator approval is in place and the exact quantity moves on commit and claim', async () => {
    const {secret, lock} = nextSecret()
    const s = await freshSchedule()
    const alice = s.aliceTerms([erc1155Asset(fixture.erc1155, 1n, 250n)])
    const bob = s.bobTerms([erc20Asset(fixture.erc20, 100n)])

    // operator approval was granted in beforeAll; the planner agrees
    const plan = await planApprovals({
      publicClient: ctx.publicClient,
      omnibusAddress: fixture.omnibus,
      committer: ctx.alice.address,
      terms: alice,
    })
    expect(plan.items[0]).toMatchObject({kind: 'erc1155', operatorApproved: true, satisfied: true})

    const omnibusBefore = await balance1155(fixture.omnibus, 1n)
    await ctx.warpTo(s.anchors.proposerCommit)
    await confirmReceipt(await aliceClient.commit({lock, party: alice, counterparty: bob, auth: keyedAuth(ctx.alice.address)}))
    expect(await balance1155(fixture.omnibus, 1n)).toBe(omnibusBefore + 250n)

    await ctx.warpTo(s.anchors.takerCommit)
    await confirmReceipt(await bobClient.commit({lock, party: bob, counterparty: alice, auth: keyedAuth(ctx.bob.address)}))
    await ctx.warpTo(s.anchors.proposerClaim)
    const recipientBefore = await balance1155(BOB_RECIPIENT, 1n)
    await confirmReceipt(await aliceClient.claim({secret, party: alice, counterparty: bob}),
    )
    // alice's 1155 quantity lands with BOB's recipient (counterparty's assets rule)
    expect(await balance1155(BOB_RECIPIENT, 1n)).toBe(recipientBefore + 250n)
  })
})

// ---------------------------------------------------------------------------
// same-chain happy path with event decoding
// ---------------------------------------------------------------------------

describe('same-chain happy path', () => {
  it('proposer commit -> Free; taker commit -> Committed; claim -> Spent; both legs settle; events decode', async () => {
    const {secret, lock} = nextSecret()
    const s = await freshSchedule()
    const NATIVE = 123_456n
    const TOKENS = 9_876n
    const alice = s.aliceTerms([nativeAsset(NATIVE)])
    const bob = s.bobTerms([erc20Asset(fixture.erc20, TOKENS)])

    // proposer commit -> Free
    await ctx.warpTo(s.anchors.proposerCommit)
    const commitA = await confirmReceipt(await aliceClient.commit({lock, party: alice, counterparty: bob, auth: keyedAuth(ctx.alice.address)}),
    )
    expect(await aliceClient.getLockState(swapId(lock, alice, bob))).toBe(LockState.Free)
    expect(await aliceClient.getTermsHash(swapId(lock, alice, bob))).toBe(digestTermsCanonically(alice, bob))
    expect(await aliceClient.getPosted(swapId(lock, alice, bob), digestTerms(alice))).toBe(true)

    // taker MUST wait for the proposer's deadline (the window only opens there)
    await ctx.warpTo(s.anchors.takerCommit)
    const commitB = await confirmReceipt(await bobClient.commit({lock, party: bob, counterparty: alice, auth: keyedAuth(ctx.bob.address)}),
    )
    expect(await aliceClient.getLockState(swapId(lock, alice, bob))).toBe(LockState.Committed)

    // Commitment events decode back to the EXACT terms that were committed
    const fromA = commitA.commitments[0]
    const fromB = commitB.commitments[0]
    if (fromA === undefined || fromB === undefined) throw new Error('missing Commitment events')
    expect(fromA.lock).toBe(lock)
    expect(fromA.sender.toLowerCase()).toBe(ctx.alice.address.toLowerCase())
    expect(fromA.signer.toLowerCase()).toBe(keyedAuth(ctx.alice.address).signer.toLowerCase()) // the full keyed blob
    expect(fromB.sender.toLowerCase()).toBe(ctx.bob.address.toLowerCase())
    expect(fromB.signer.toLowerCase()).toBe(keyedAuth(ctx.bob.address).signer.toLowerCase())
    expect(fromA.party).toEqual({...alice, assets: alice.assets.map(a => ({...a}))})
    expect(fromB.party).toEqual({...bob, assets: bob.assets.map(a => ({...a}))})

    // one claim settles BOTH legs
    await ctx.warpTo(s.anchors.proposerClaim)
    const bobRecipientNativeBefore = await ctx.publicClient.getBalance({address: BOB_RECIPIENT})
    const aliceRecipientTokensBefore = await erc20Balance(fixture.erc20, ALICE_RECIPIENT)
    const claim = await confirmReceipt(await aliceClient.claim({secret, party: alice, counterparty: bob}),
    )
    expect(await aliceClient.getLockState(swapId(lock, alice, bob))).toBe(LockState.Spent)
    // bob's tokens -> alice's recipient; alice's native -> bob's recipient
    expect(await erc20Balance(fixture.erc20, ALICE_RECIPIENT)).toBe(aliceRecipientTokensBefore + TOKENS)
    expect(await ctx.publicClient.getBalance({address: BOB_RECIPIENT})).toBe(bobRecipientNativeBefore + NATIVE)

    // a same-chain claim emits one Claim per payout leg, each naming its terms-pinned
    // recipient (NOT the caller) and revealing the ORIGINAL secret
    expect(claim.claims).toHaveLength(2)
    expect(claim.claims.every(c => c.secret === secret && c.lock === lock)).toBe(true)
    const recipients = claim.claims.map(c => c.recipient.toLowerCase()).sort()
    expect(recipients).toEqual([ALICE_RECIPIENT.toLowerCase(), BOB_RECIPIENT.toLowerCase()].sort())
    // the caller (aliceClient's sender) is NOT among the emitted recipients
    expect(recipients).not.toContain(ctx.alice.address.toLowerCase())
  })
})

// ---------------------------------------------------------------------------
// keyed commit authorization (the identity is distinct from the sender)
// ---------------------------------------------------------------------------

describe('keyed ERC-7913 commit authorization', () => {
  // anvil dev account #4 — holds NO role in this suite and never sends a
  // transaction here; its address is only KEY MATERIAL for a keyed identity
  const signerAccount = privateKeyToAccount('0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a')

  it("the contract's COMMIT_DIGEST_TAG equals the SDK constant", async () => {
    const onChainTag = await ctx.publicClient.readContract({
      address: fixture.omnibus,
      abi: omnibusAbi,
      functionName: 'COMMIT_DIGEST_TAG',
    })
    expect(onChainTag).toBe(COMMIT_DIGEST_TAG)
  })

  it("the contract's DOMAIN_SEPARATOR equals the SDK computation", async () => {
    const onChainSeparator = await ctx.publicClient.readContract({
      address: fixture.omnibus,
      abi: omnibusAbi,
      functionName: 'DOMAIN_SEPARATOR',
    })
    expect(onChainSeparator).toBe(computeDomainSeparator(BigInt(CHAIN_ID), fixture.omnibus))
  })

  it('keyed commit by a third-party sender + keyed counterpart + claim settles both legs', async () => {
    const {secret, lock} = nextSecret()
    const s = await freshSchedule()
    const NATIVE = 43_210n
    const TOKENS = 6_789n
    const alice = s.aliceTerms([nativeAsset(NATIVE)])
    const bob = s.bobTerms([erc20Asset(fixture.erc20, TOKENS)])

    // the keyed identity: fixture verifier ‖ account-#4 key material —
    // distinct from every sender in this test
    const keyedSigner = buildKeyedSigner(fixture.verifier, signerAccount.address)

    // (a) digest parity first: local computation == the contract's view
    // (the digest hashes the WHOLE keyed blob)
    const digest = computeCommitDigest({
      lock,
      party: alice,
      counterparty: bob,
      signer: keyedSigner,
      omnibusAddress: fixture.omnibus,
    })
    expect(await charlieClient.getCommitDigest(lock, alice, bob, keccak256(keyedSigner))).toBe(digest)

    // a DIFFERENT actor (charlie) submits and FUNDS the leg + fee; the
    // AcceptAll mock ignores the envelope, so '0x' suffices
    expect(signerAccount.address.toLowerCase()).not.toBe(ctx.charlie.address.toLowerCase())
    await ctx.warpTo(s.anchors.proposerCommit)
    const commitA = await confirmReceipt(
      await charlieClient.commit({
        lock,
        party: alice,
        counterparty: bob,
        auth: {signer: keyedSigner, signature: '0x656e76656c6f7065'},
      }),
    )
    expect(await charlieClient.getLockState(swapId(lock, alice, bob))).toBe(LockState.Free)
    expect(commitA.commitments[0]?.signer.toLowerCase()).toBe(keyedSigner.toLowerCase())
    expect(commitA.commitments[0]?.sender.toLowerCase()).toBe(ctx.charlie.address.toLowerCase())

    // (b) the other side commits with its own keyed identity
    await ctx.warpTo(s.anchors.takerCommit)
    await confirmReceipt(
      await bobClient.commit({lock, party: bob, counterparty: alice, auth: keyedAuth(ctx.bob.address)}),
    )
    expect(await charlieClient.getLockState(swapId(lock, alice, bob))).toBe(LockState.Committed)

    // (c) the claim settles both legs — balance deltas prove it
    await ctx.warpTo(s.anchors.proposerClaim)
    const aliceRecipientTokensBefore = await erc20Balance(fixture.erc20, ALICE_RECIPIENT)
    const bobRecipientNativeBefore = await ctx.publicClient.getBalance({address: BOB_RECIPIENT})
    await confirmReceipt(await aliceClient.claim({secret, party: alice, counterparty: bob}))
    expect(await charlieClient.getLockState(swapId(lock, alice, bob))).toBe(LockState.Spent)
    expect(await erc20Balance(fixture.erc20, ALICE_RECIPIENT)).toBe(aliceRecipientTokensBefore + TOKENS)
    expect(await ctx.publicClient.getBalance({address: BOB_RECIPIENT})).toBe(bobRecipientNativeBefore + NATIVE)
  })

  it('a bare 20-byte address blob is rejected on-chain (MalformedSigner — the blob must EXCEED 20 bytes)', async () => {
    const {lock} = nextSecret()
    const s = await freshSchedule()
    const alice = s.aliceTerms([nativeAsset(10n)])
    const bob = s.bobTerms([erc20Asset(fixture.erc20, 10n)])
    // an address-length blob no longer routes anywhere — even for msg.sender
    await ctx.warpTo(s.anchors.proposerCommit)
    await expectContractError(
      rawCommit(ctx.charlie, lock, alice, bob, 10n, {signer: ctx.charlie.address, signature: '0x'}),
      'MalformedSigner',
    )
  })
})

// ---------------------------------------------------------------------------
// reclaim flows
// ---------------------------------------------------------------------------

describe('reclaim flows', () => {
  it('reclaim before reclaimRelease fails in SDK preflight AND on-chain (WindowViolated)', async () => {
    const {lock} = nextSecret()
    const s = await freshSchedule()
    const alice = s.aliceTerms([nativeAsset(100n)])
    const bob = s.bobTerms([erc20Asset(fixture.erc20, 100n)])
    await ctx.warpTo(s.anchors.proposerCommit)
    await confirmReceipt(await aliceClient.commit({lock, party: alice, counterparty: bob, auth: keyedAuth(ctx.alice.address)}))

    // SDK preflight rejects with the window error before any submission
    await ctx.warpTo(s.anchors.proposerClaim)
    try {
      await aliceClient.reclaim({lock, party: alice, counterparty: bob})
      expect.unreachable()
    } catch (error) {
      expect((error as QuipSwapError).code).toBe('WINDOW_VIOLATED')
    }
    // the contract agrees (raw call bypassing preflight)
    await expectContractError(
      ctx.publicClient.simulateContract({
        address: fixture.omnibus,
        abi: omnibusAbi,
        functionName: 'reclaim',
        args: [lock, toTuple(alice), toTuple(bob)],
        account: ctx.alice.account,
      }),
      'WindowViolated',
    )
  })

  it('reclaim from Free (only the proposer committed) succeeds after release; assets return to reclaimRecipient', async () => {
    const {lock} = nextSecret()
    const s = await freshSchedule()
    const NATIVE = 5_000n
    const alice = s.aliceTerms([nativeAsset(NATIVE)])
    const bob = s.bobTerms([erc20Asset(fixture.erc20, 100n)])
    await ctx.warpTo(s.anchors.proposerCommit)
    await confirmReceipt(await aliceClient.commit({lock, party: alice, counterparty: bob, auth: keyedAuth(ctx.alice.address)}))
    expect(await aliceClient.getLockState(swapId(lock, alice, bob))).toBe(LockState.Free)

    await ctx.warpTo(s.anchors.proposerReclaim)
    const reclaimBalanceBefore = await ctx.publicClient.getBalance({address: ALICE_RECLAIM})
    const result = await confirmReceipt(// reclaim is PERMISSIONLESS: charlie (unregistered) reclaims for alice's leg
      await charlieClient.reclaim({lock, party: alice, counterparty: bob}),
    )
    expect(await aliceClient.getLockState(swapId(lock, alice, bob))).toBe(LockState.Spent)
    // assets go to the reclaimRecipient, NOT the committer
    expect(await ctx.publicClient.getBalance({address: ALICE_RECLAIM})).toBe(reclaimBalanceBefore + NATIVE)
    expect(result.reclaims).toHaveLength(1)
    expect(result.reclaims[0]?.recipient.toLowerCase()).toBe(ALICE_RECLAIM.toLowerCase())
  })

  it('per-side reclaim: both committed, nobody claimed — each party reclaims ONLY its own leg (independent, either order)', async () => {
    // Finding 4: reclaim returns only the caller's own leg to its own
    // reclaimRecipient. A same-chain refund is therefore TWO reclaims; a
    // hostile counterparty recipient can never block the other side.
    const {lock} = nextSecret()
    const s = await freshSchedule()
    const NATIVE = 3_333n
    const TOKENS = 4_444n
    const alice = s.aliceTerms([nativeAsset(NATIVE)])
    const bob = s.bobTerms([erc20Asset(fixture.erc20, TOKENS)])
    const id = swapId(lock, alice, bob)
    await ctx.warpTo(s.anchors.proposerCommit)
    await confirmReceipt(await aliceClient.commit({lock, party: alice, counterparty: bob, auth: keyedAuth(ctx.alice.address)}))
    await ctx.warpTo(s.anchors.takerCommit)
    await confirmReceipt(await bobClient.commit({lock, party: bob, counterparty: alice, auth: keyedAuth(ctx.bob.address)}))

    // both releases have passed; bob reclaims his OWN token leg first
    await ctx.warpTo(s.anchors.takerReclaim)
    const aliceReclaimBefore = await ctx.publicClient.getBalance({address: ALICE_RECLAIM})
    const bobReclaimBefore = await erc20Balance(fixture.erc20, BOB_RECLAIM)
    const bobResult = await confirmReceipt(await bobClient.reclaim({lock, party: bob, counterparty: alice}))
    // exactly one Reclaimed, bob's own leg only; alice's native is untouched
    expect(bobResult.reclaims).toHaveLength(1)
    expect(bobResult.reclaims[0]?.recipient.toLowerCase()).toBe(BOB_RECLAIM.toLowerCase())
    expect(await erc20Balance(fixture.erc20, BOB_RECLAIM)).toBe(bobReclaimBefore + TOKENS)
    expect(await ctx.publicClient.getBalance({address: ALICE_RECLAIM})).toBe(aliceReclaimBefore)
    // lock is Spent, but only bob's side is flagged reclaimed
    expect(await aliceClient.getLockState(id)).toBe(LockState.Spent)
    expect(await aliceClient.getReclaimed(id, digestTerms(bob))).toBe(true)
    expect(await aliceClient.getReclaimed(id, digestTerms(alice))).toBe(false)

    // alice reclaims her OWN native leg from the Spent lock (mid-reclaim)
    const aliceResult = await confirmReceipt(await aliceClient.reclaim({lock, party: alice, counterparty: bob}))
    expect(aliceResult.reclaims).toHaveLength(1)
    expect(aliceResult.reclaims[0]?.recipient.toLowerCase()).toBe(ALICE_RECLAIM.toLowerCase())
    expect(await ctx.publicClient.getBalance({address: ALICE_RECLAIM})).toBe(aliceReclaimBefore + NATIVE)
    expect(await aliceClient.getReclaimed(id, digestTerms(alice))).toBe(true)
  })

  it('double reclaim of the same side reverts AlreadyReclaimed (and SDK preflight INVALID_LOCK_STATE)', async () => {
    const {lock} = nextSecret()
    const s = await freshSchedule()
    const alice = s.aliceTerms([nativeAsset(10n)])
    const bob = s.bobTerms([erc20Asset(fixture.erc20, 10n)])
    await ctx.warpTo(s.anchors.proposerCommit)
    await confirmReceipt(await aliceClient.commit({lock, party: alice, counterparty: bob, auth: keyedAuth(ctx.alice.address)}))
    await ctx.warpTo(s.anchors.proposerReclaim)
    await confirmReceipt(await aliceClient.reclaim({lock, party: alice, counterparty: bob}))

    // SDK preflight catches the already-reclaimed side before submitting
    try {
      await aliceClient.reclaim({lock, party: alice, counterparty: bob})
      expect.unreachable()
    } catch (error) {
      expect((error as QuipSwapError).code).toBe('INVALID_LOCK_STATE')
      expect((error as QuipSwapError).message).toContain('already reclaimed')
    }
    // the contract agrees (raw call bypassing preflight)
    await expectContractError(
      ctx.publicClient.simulateContract({
        address: fixture.omnibus,
        abi: omnibusAbi,
        functionName: 'reclaim',
        args: [lock, toTuple(alice), toTuple(bob)],
        account: ctx.alice.account,
      }),
      'AlreadyReclaimed',
    )
  })

  it('reclaim pays the clamped remainder after an escrow shortfall (negative rebase regression)', async () => {
    // a fresh token isolates this swap's escrow from the shared fixture pool,
    // so burning from the Omnibus creates a REAL shortfall for this swap
    const rebaseToken = await ctx.deploy(loadArtifact('ERC20Mock.sol', 'ERC20Mock'), ['Rebase', 'REB', 18])
    const TOKENS = 500n
    for (const [fn, args] of [
      ['mint', [ctx.bob.address, TOKENS]],
      ['approve', [fixture.omnibus, (1n << 256n) - 1n]],
    ] as const) {
      const hash = await ctx.bob.walletClient.writeContract({
        address: rebaseToken,
        abi: erc20MockAbi,
        functionName: fn,
        args: args as never,
        chain: ctx.bob.walletClient.chain,
        account: ctx.bob.account,
      })
      await ctx.publicClient.waitForTransactionReceipt({hash})
    }

    const {lock} = nextSecret()
    const s = await freshSchedule()
    const NATIVE = 1000n
    const alice = s.aliceTerms([nativeAsset(NATIVE)])
    const bob = s.bobTerms([erc20Asset(rebaseToken, TOKENS)])
    await ctx.warpTo(s.anchors.proposerCommit)
    await confirmReceipt(await aliceClient.commit({lock, party: alice, counterparty: bob, auth: keyedAuth(ctx.alice.address)}))
    await ctx.warpTo(s.anchors.takerCommit)
    await confirmReceipt(await bobClient.commit({lock, party: bob, counterparty: alice, auth: keyedAuth(ctx.bob.address)}))

    // negative rebase: the pooled escrow is now 1 short of Bob's declared amount
    const burnHash = await ctx.deployer.walletClient.writeContract({
      address: rebaseToken,
      abi: erc20MockAbi,
      functionName: 'burn',
      args: [fixture.omnibus, 1n],
      chain: ctx.deployer.walletClient.chain,
      account: ctx.deployer.account,
    })
    await ctx.publicClient.waitForTransactionReceipt({hash: burnHash})

    // the shortfall is on BOB's token leg, so BOB reclaims it. Before the clamp
    // this reverted forever (TransferFailed) and froze the escrow; now the SDK
    // write path (preflight + estimate) goes through and the token leg pays the
    // clamped remainder. Alice's native leg is a separate, full-value reclaim.
    await ctx.warpTo(s.anchors.takerReclaim)
    const aliceReclaimBefore = await ctx.publicClient.getBalance({address: ALICE_RECLAIM})
    const bobResult = await confirmReceipt(await bobClient.reclaim({lock, party: bob, counterparty: alice}))
    expect(bobResult.reclaims).toHaveLength(1)
    expect(await erc20Balance(rebaseToken, BOB_RECLAIM)).toBe(TOKENS - 1n)
    expect(await aliceClient.getLockState(swapId(lock, alice, bob))).toBe(LockState.Spent)

    const aliceResult = await confirmReceipt(await aliceClient.reclaim({lock, party: alice, counterparty: bob}))
    expect(aliceResult.reclaims).toHaveLength(1)
    expect(await ctx.publicClient.getBalance({address: ALICE_RECLAIM})).toBe(aliceReclaimBefore + NATIVE)
  })
})

// ---------------------------------------------------------------------------
// invalid operations (contract-level, raw calls bypassing SDK preflight)
// ---------------------------------------------------------------------------

describe('invalid operations', () => {
  it('wrong chain id reverts ChainIdMismatch on-chain and CHAIN_ID_MISMATCH in preflight', async () => {
    const {lock} = nextSecret()
    const s = await freshSchedule()
    const alice = s.aliceTerms([nativeAsset(10n)], 999n) // wrong chain
    const bob = s.bobTerms([erc20Asset(fixture.erc20, 10n)])
    await ctx.warpTo(s.anchors.proposerCommit)
    await expectContractError(rawCommit(ctx.alice, lock, alice, bob, 10n), 'ChainIdMismatch')
    try {
      await aliceClient.commit({lock, party: alice, counterparty: bob, auth: keyedAuth(ctx.alice.address)})
      expect.unreachable()
    } catch (error) {
      expect((error as QuipSwapError).code).toBe('CHAIN_ID_MISMATCH')
    }
  })

  it('proposer commit after its deadline reverts WindowViolated', async () => {
    const {lock} = nextSecret()
    const s = await freshSchedule()
    const alice = s.aliceTerms([nativeAsset(10n)])
    const bob = s.bobTerms([erc20Asset(fixture.erc20, 10n)])
    await ctx.warpTo(s.anchors.takerCommit) // past the proposer window
    await expectContractError(rawCommit(ctx.alice, lock, alice, bob, 10n), 'WindowViolated')
  })

  it('taker commit BEFORE the proposer deadline reverts WindowViolated', async () => {
    const {lock} = nextSecret()
    const s = await freshSchedule()
    const alice = s.aliceTerms([nativeAsset(10n)])
    const bob = s.bobTerms([erc20Asset(fixture.erc20, 10n)])
    await ctx.warpTo(s.anchors.proposerCommit) // proposer window still open
    await expectContractError(rawCommit(ctx.bob, lock, bob, alice, 0n), 'WindowViolated')
  })

  it('non-interleaved schedules revert DisordedDeadlines', async () => {
    const {lock} = nextSecret()
    const s = await freshSchedule()
    const alice = s.aliceTerms([nativeAsset(10n)])
    // bob entirely after alice: sequential, not interleaved
    const base = alice.reclaimRelease
    const bob: Terms = {
      ...s.bobTerms([erc20Asset(fixture.erc20, 10n)]),
      commitmentDeadline: base + 1000n,
      claimDeadline: base + 2000n,
      reclaimRelease: base + 3000n,
    }
    await ctx.warpTo(s.anchors.proposerCommit)
    await expectContractError(rawCommit(ctx.alice, lock, alice, bob, 10n), 'DisordedDeadlines')
  })

  it('re-posting the same side: TERMS_ALREADY_POSTED preflight; contract TermsAlreadyPosted with the flag off', async () => {
    // the second same-chain commit must post the OTHER side; the committer
    // re-posting its own side inside its still-open window hits the
    // posted[partyDigest] guard (lock is Free at that point)
    const {lock} = nextSecret()
    const s = await freshSchedule()
    const alice = s.aliceTerms([nativeAsset(10n)])
    const bob = s.bobTerms([erc20Asset(fixture.erc20, 10n)])
    await ctx.warpTo(s.anchors.proposerCommit)
    await confirmReceipt(await aliceClient.commit({lock, party: alice, counterparty: bob, auth: keyedAuth(ctx.alice.address)}))

    // SDK preflight catches the duplicate with its precise code, before estimation
    try {
      await aliceClient.commit({lock, party: alice, counterparty: bob, auth: keyedAuth(ctx.alice.address)})
      expect.unreachable()
    } catch (error) {
      expect((error as QuipSwapError).code).toBe('TERMS_ALREADY_POSTED')
    }
    // with the flag off, the same scenario surfaces through the gas-estimation
    // path as the decoded contract error
    await expectContractError(
      aliceClient.commit({lock, party: alice, counterparty: bob, verifyOnChainState: false, auth: keyedAuth(ctx.alice.address)}),
      'TermsAlreadyPosted',
    )
    // and the raw contract call agrees
    await expectContractError(rawCommit(ctx.alice, lock, alice, bob, 10n), 'TermsAlreadyPosted')
  })

  it('a second commit with DIFFERENT terms opens an ISOLATED swap; the original is untouched', async () => {
    const {lock} = nextSecret()
    const s = await freshSchedule()
    const alice = s.aliceTerms([nativeAsset(10n)])
    const bob = s.bobTerms([erc20Asset(fixture.erc20, 10n)])
    await ctx.warpTo(s.anchors.proposerCommit)
    await confirmReceipt(await aliceClient.commit({lock, party: alice, counterparty: bob, auth: keyedAuth(ctx.alice.address)}))
    // bob commits against MUTATED alice terms — the canonical digest differs, so the
    // pairing derives a DIFFERENT swap id: it cannot join (or corrupt) alice's swap
    // and lands in its own isolated one instead of reverting
    const mutatedAlice: Terms = {...alice, recipient: BOB_RECIPIENT}
    await ctx.warpTo(s.anchors.takerCommit)
    await confirmReceipt(
      await bobClient.commit({lock, party: bob, counterparty: mutatedAlice, auth: keyedAuth(ctx.bob.address)}),
    )

    // alice's swap: still Free, awaiting HER pairing's taker leg
    expect(await aliceClient.getLockState(swapId(lock, alice, bob))).toBe(LockState.Free)
    expect(await aliceClient.getPosted(swapId(lock, alice, bob), digestTerms(bob))).toBe(false)
    // the mismatched pairing: tracked entirely under its own swap id
    expect(await aliceClient.getLockState(swapId(lock, bob, mutatedAlice))).toBe(LockState.Free)
    expect(await aliceClient.getPosted(swapId(lock, bob, mutatedAlice), digestTerms(bob))).toBe(true)
  })

  it('reclaim on an Unused lock: TERMS_NOT_ON_CHAIN preflight; contract TermsMismatch with the flag off', async () => {
    // nothing was ever committed under this lock; the contract hits the
    // termsHash check first (zero != canonical digest) and the preflight
    // mirrors that ordering (termsHash before the lock-state checks), naming
    // the actual cause instead of a misleading lock-state error
    const {lock} = nextSecret()
    const s = await freshSchedule()
    const alice = s.aliceTerms([nativeAsset(10n)])
    const bob = s.bobTerms([erc20Asset(fixture.erc20, 10n)])
    await ctx.warpTo(s.anchors.proposerReclaim)
    try {
      await aliceClient.reclaim({lock, party: alice, counterparty: bob})
      expect.unreachable()
    } catch (error) {
      expect((error as QuipSwapError).code).toBe('TERMS_NOT_ON_CHAIN')
    }
    await expectContractError(
      aliceClient.reclaim({lock, party: alice, counterparty: bob, verifyOnChainState: false}),
      'TermsMismatch',
    )
  })

  it('claim with the wrong secret reverts TermsMismatch (the wrong lock has no termsHash)', async () => {
    const right = nextSecret()
    const wrong = nextSecret()
    const s = await freshSchedule()
    const alice = s.aliceTerms([nativeAsset(10n)])
    const bob = s.bobTerms([erc20Asset(fixture.erc20, 10n)])
    await ctx.warpTo(s.anchors.proposerCommit)
    await confirmReceipt(await aliceClient.commit({lock: right.lock, party: alice, counterparty: bob, auth: keyedAuth(ctx.alice.address)}),
    )
    await ctx.warpTo(s.anchors.takerCommit)
    await confirmReceipt(await bobClient.commit({lock: right.lock, party: bob, counterparty: alice, auth: keyedAuth(ctx.bob.address)}),
    )
    await ctx.warpTo(s.anchors.proposerClaim)
    await expectContractError(
      ctx.publicClient.simulateContract({
        address: fixture.omnibus,
        abi: omnibusAbi,
        functionName: 'claim',
        args: [wrong.secret, toTuple(alice), toTuple(bob)],
        account: ctx.alice.account,
      }),
      'TermsMismatch',
    )
  })

  it('claim on a non-Committed lock reverts InvalidLockState; double claim too', async () => {
    const {secret, lock} = nextSecret()
    const s = await freshSchedule()
    const alice = s.aliceTerms([nativeAsset(10n)])
    const bob = s.bobTerms([erc20Asset(fixture.erc20, 10n)])
    await ctx.warpTo(s.anchors.proposerCommit)
    await confirmReceipt(await aliceClient.commit({lock, party: alice, counterparty: bob, auth: keyedAuth(ctx.alice.address)}))

    // lock is Free (only one side committed): the SDK preflight names the
    // cause; the raw contract call reverts InvalidLockState
    await ctx.warpTo(s.anchors.proposerClaim)
    try {
      await aliceClient.claim({secret, party: alice, counterparty: bob})
      expect.unreachable()
    } catch (error) {
      expect((error as QuipSwapError).code).toBe('INVALID_LOCK_STATE')
      expect((error as QuipSwapError).message).toContain('counterparty has not committed')
    }
    await expectContractError(
      ctx.publicClient.simulateContract({
        address: fixture.omnibus,
        abi: omnibusAbi,
        functionName: 'claim',
        args: [secret, toTuple(alice), toTuple(bob)],
        account: ctx.alice.account,
      }),
      'InvalidLockState',
    )

    // NOTE: a complete-and-double-claim needs the taker commit, which is now
    // impossible for this schedule (we're past the taker window) — use a new swap
    const second = nextSecret()
    const s2 = await freshSchedule()
    const alice2 = s2.aliceTerms([nativeAsset(10n)])
    const bob2 = s2.bobTerms([erc20Asset(fixture.erc20, 10n)])
    await ctx.warpTo(s2.anchors.proposerCommit)
    await confirmReceipt(await aliceClient.commit({lock: second.lock, party: alice2, counterparty: bob2, auth: keyedAuth(ctx.alice.address)}),
    )
    await ctx.warpTo(s2.anchors.takerCommit)
    await confirmReceipt(await bobClient.commit({lock: second.lock, party: bob2, counterparty: alice2, auth: keyedAuth(ctx.bob.address)}),
    )
    await ctx.warpTo(s2.anchors.proposerClaim)
    await confirmReceipt(await aliceClient.claim({secret: second.secret, party: alice2, counterparty: bob2}),
    )
    // double claim (lock now Spent): SDK preflight catches it with its
    // precise code instead of a generic CONTRACT_REVERT...
    try {
      await aliceClient.claim({secret: second.secret, party: alice2, counterparty: bob2})
      expect.unreachable()
    } catch (error) {
      expect((error as QuipSwapError).code).toBe('INVALID_LOCK_STATE')
      expect((error as QuipSwapError).message).toContain('already claimed or reclaimed')
    }
    // ...with the flag off, the same scenario surfaces through the
    // gas-estimation path as the decoded contract error
    await expectContractError(
      aliceClient.claim({secret: second.secret, party: alice2, counterparty: bob2, verifyOnChainState: false}),
      'InvalidLockState',
    )
    await expectContractError(
      ctx.publicClient.simulateContract({
        address: fixture.omnibus,
        abi: omnibusAbi,
        functionName: 'claim',
        args: [second.secret, toTuple(alice2), toTuple(bob2)],
        account: ctx.alice.account,
      }),
      'InvalidLockState',
    )
  })
})

// ---------------------------------------------------------------------------
// fee-on-transfer token
// ---------------------------------------------------------------------------

describe('fee-on-transfer token', () => {
  it('commit reverts UnexpectedAmountReceived despite a satisfied approval plan', async () => {
    // mint + approve the fee token for bob so the APPROVAL plan is satisfied
    let hash = await ctx.bob.walletClient.writeContract({
      address: fixture.feeERC20,
      abi: erc20MockAbi,
      functionName: 'mint',
      args: [ctx.bob.address, 10n ** 21n],
      chain: ctx.publicClient.chain ?? null,
      account: ctx.bob.account,
    })
    await ctx.publicClient.waitForTransactionReceipt({hash})
    hash = await ctx.bob.walletClient.writeContract({
      address: fixture.feeERC20,
      abi: erc20MockAbi,
      functionName: 'approve',
      args: [fixture.omnibus, (1n << 256n) - 1n],
      chain: ctx.publicClient.chain ?? null,
      account: ctx.bob.account,
    })
    await ctx.publicClient.waitForTransactionReceipt({hash})

    const {lock} = nextSecret()
    const s = await freshSchedule()
    const alice = s.aliceTerms([erc20Asset(fixture.feeERC20, 10_000n)])
    const bob = s.bobTerms([nativeAsset(10n)])
    // alice needs the fee token too — reuse bob's mint pattern for alice
    hash = await ctx.alice.walletClient.writeContract({
      address: fixture.feeERC20,
      abi: erc20MockAbi,
      functionName: 'mint',
      args: [ctx.alice.address, 10n ** 21n],
      chain: ctx.publicClient.chain ?? null,
      account: ctx.alice.account,
    })
    await ctx.publicClient.waitForTransactionReceipt({hash})

    const plan = await planApprovals({
      publicClient: ctx.publicClient,
      omnibusAddress: fixture.omnibus,
      committer: ctx.alice.address,
      terms: alice,
    })
    // alice approved exactly 100n earlier in the approvals suite; top up to satisfied
    if (!plan.satisfied) {
      const item = plan.items[0]
      if (item === undefined) throw new Error('expected one approval item')
      const approveHash = await submitApproval({
        publicClient: ctx.publicClient,
        walletClient: ctx.alice.walletClient,
        omnibusAddress: fixture.omnibus,
        item,
        erc20Mode: 'exact',
      })
      await ctx.publicClient.waitForTransactionReceipt({hash: approveHash})
    }

    // the approval plan is satisfied, yet the 1%-skim makes the escrow
    // receive 9900 != 10000 — the contract's balance reconciliation reverts
    await ctx.warpTo(s.anchors.proposerCommit)
    await expectContractError(rawCommit(ctx.alice, lock, alice, bob, 0n), 'UnexpectedAmountReceived')
  })
})

// ---------------------------------------------------------------------------
// gas estimation and balance preflight (the estimate-before-write flow)
// ---------------------------------------------------------------------------

describe('gas and balance preflight', () => {
  it('a commit sender underfunded for the VALUE is rejected BALANCE_TOO_LOW before any transaction exists', async () => {
    // a fixed key that is NOT one of anvil's funded dev accounts → 0 balance;
    // commit is permissionless, so the balance preflight is the failing check
    const pauper = privateKeyToAccount(`0x${'77'.repeat(32)}`)
    expect(await ctx.publicClient.getBalance({address: pauper.address})).toBe(0n)
    const pauperClient = createOmnibusClient({
      address: fixture.omnibus,
      publicClient: ctx.publicClient,
      walletClient: createWalletClient({
        chain: ctx.publicClient.chain,
        transport: http(RPC_URL),
        account: pauper,
      }),
    })

    const {lock} = nextSecret()
    const s = await freshSchedule()
    const NATIVE = 10n ** 18n
    const alice = s.aliceTerms([nativeAsset(NATIVE)])
    const bob = s.bobTerms([erc20Asset(fixture.erc20, 100n)])
    await ctx.warpTo(s.anchors.proposerCommit)

    // the stage-1 value preflight rejects BEFORE gas estimation — were the
    // order reversed, anvil's insufficient-funds estimation error would
    // mislabel this GAS_ESTIMATION_FAILED
    try {
      await pauperClient.commit({lock, party: alice, counterparty: bob, auth: keyedAuth(pauper.address)})
      expect.unreachable()
    } catch (error) {
      expect((error as QuipSwapError).code).toBe('BALANCE_TOO_LOW')
      expect((error as QuipSwapError).details).toMatchObject({balance: 0n, required: NATIVE})
    }
    // nothing reached the chain
    expect(await aliceClient.getLockState(swapId(lock, alice, bob))).toBe(LockState.Unused)
  })

  it('a gas-unfunded claimer fails at SEND time as BALANCE_TOO_LOW (value-less calls have no preflight)', async () => {
    // arrange a claimable swap (claim is permissionless, so ANY account may try)
    const {secret, lock} = nextSecret()
    const s = await freshSchedule()
    const alice = s.aliceTerms([nativeAsset(100n)])
    const bob = s.bobTerms([erc20Asset(fixture.erc20, 100n)])
    await ctx.warpTo(s.anchors.proposerCommit)
    await confirmReceipt(await aliceClient.commit({lock, party: alice, counterparty: bob, auth: keyedAuth(ctx.alice.address)}))
    await ctx.warpTo(s.anchors.takerCommit)
    await confirmReceipt(await bobClient.commit({lock, party: bob, counterparty: alice, auth: keyedAuth(ctx.bob.address)}))
    await ctx.warpTo(s.anchors.proposerClaim)

    const pauper = privateKeyToAccount(`0x${'78'.repeat(32)}`) // 0 balance, never funded
    const pauperClient = createOmnibusClient({
      address: fixture.omnibus,
      publicClient: ctx.publicClient,
      walletClient: createWalletClient({
        chain: ctx.publicClient.chain,
        transport: http(RPC_URL),
        account: pauper,
      }),
    })

    // claim carries no value, so no balance preflight runs; the node rejects
    // the SEND for gas funds and submitWrite maps viem's
    // InsufficientFundsError to BALANCE_TOO_LOW (not CONTRACT_REVERT)
    try {
      await pauperClient.claim({secret, party: alice, counterparty: bob})
      expect.unreachable()
    } catch (error) {
      expect((error as QuipSwapError).code).toBe('BALANCE_TOO_LOW')
    }
    expect(await aliceClient.getLockState(swapId(lock, alice, bob))).toBe(LockState.Committed)

    // a funded (still permissionless, unregistered) claimer settles the swap
    // end-to-end through the same prepare+write flow
    await confirmReceipt(await charlieClient.claim({secret, party: alice, counterparty: bob}),
    )
    expect(await aliceClient.getLockState(swapId(lock, alice, bob))).toBe(LockState.Spent)
  })

  it('explicit TxOptions are honored on a real transaction (gas verbatim, pinned fees)', async () => {
    const {lock} = nextSecret()
    const s = await freshSchedule()
    const alice = s.aliceTerms([nativeAsset(10n)])
    const bob = s.bobTerms([erc20Asset(fixture.erc20, 10n)])
    await ctx.warpTo(s.anchors.proposerCommit)
    const hash = await aliceClient.commit(
      {lock, party: alice, counterparty: bob, auth: keyedAuth(ctx.alice.address)},
      {gas: 400_000n, maxFeePerGas: 5_000_000_000n, maxPriorityFeePerGas: 1_000_000_000n},
    )
    const receipt = await ctx.publicClient.waitForTransactionReceipt({hash})
    expect(receipt.status).toBe('success')
    const tx = await ctx.publicClient.getTransaction({hash})
    expect(tx.gas).toBe(400_000n) // verbatim — no multiplier applied
    expect(tx.maxFeePerGas).toBe(5_000_000_000n)
    expect(tx.maxPriorityFeePerGas).toBe(1_000_000_000n)
  })
})
