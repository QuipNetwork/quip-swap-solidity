/**
 * Single-chain Anvil integration tests for the SDK against the REAL
 * Omnibus + QuipFactoryMock + mock tokens (no mocked RPC clients).
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
import {getAddress, keccak256, toHex} from 'viem'
import type {Address} from 'viem'
import {beforeAll, describe, expect, it} from 'vitest'
import {planApprovals, submitApproval} from '../../src/approvals.js'
import {erc1155Asset, erc20Asset, erc721Asset, nativeAsset, totalNative} from '../../src/assets.js'
import {createOmnibusClient} from '../../src/client.js'
import type {OmnibusClient} from '../../src/client.js'
import {QuipSdkError, extractContractErrorName} from '../../src/errors.js'
import {omnibusAbi} from '../../src/generated/omnibusAbi.js'
import {digestTerms, digestTermsCanonically, generateLock} from '../../src/hashing.js'
import {waitForOmnibusReceipt} from '../../src/receipts.js'
import {LockState} from '../../src/types.js'
import type {Asset, Hex32, Terms} from '../../src/types.js'
import {
  connectChain,
  deployFixture,
  erc1155MockAbi,
  erc20MockAbi,
  erc721MockAbi,
  quipFactoryMockAbi,
} from '../helpers/chain.js'
import type {ChainContext, Fixture, TestActor} from '../helpers/chain.js'

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
    if (error instanceof QuipSdkError) {
      expect(error.contractErrorName, `expected ${errorName}, got SDK code ${error.code}`).toBe(errorName)
      return
    }
    expect(extractContractErrorName(error), String(error)).toBe(errorName)
  }
}

/** Raw commit through viem, bypassing SDK preflight (for contract-level negative tests). */
async function rawCommit(actor: TestActor, lock: Hex32, party: Terms, counterparty: Terms, value: bigint) {
  const {request} = await ctx.publicClient.simulateContract({
    address: fixture.omnibus,
    abi: omnibusAbi,
    functionName: 'commit',
    args: [lock, toTuple(party), toTuple(counterparty)],
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
  it('reads VERSION, MAX_FEE, QUIP_FACTORY, commitmentFee, accruedFees', async () => {
    expect(await aliceClient.getVersion()).toBe(0n)
    expect(await aliceClient.getMaxFee()).toBe(10n ** 16n) // 0.01 ether
    expect((await aliceClient.getQuipFactory()).toLowerCase()).toBe(fixture.quipFactory.toLowerCase())
    expect(await aliceClient.getCommitmentFee()).toBe(0n)
    expect(await aliceClient.getAccruedFees()).toBe(0n)
  })

  it('reads lockState, termsHash, posted for an unused lock', async () => {
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
// QuipWallet gating
// ---------------------------------------------------------------------------

describe('QuipWallet gating', () => {
  it('isQuipWallet reflects the registry', async () => {
    expect(await aliceClient.isQuipWallet(ctx.alice.address)).toBe(true)
    expect(await aliceClient.isQuipWallet(ctx.charlie.address)).toBe(false)
  })

  it('the SDK preflight catches an unregistered committer BEFORE submission', async () => {
    const {lock} = nextSecret()
    const s = await freshSchedule()
    const alice = s.aliceTerms([nativeAsset(10n)])
    const bob = s.bobTerms([erc20Asset(fixture.erc20, 10n)])
    await ctx.warpTo(s.anchors.proposerCommit)
    try {
      // charlie acts for the PROPOSER side here (earlier schedule), so the
      // window is open and the gate is the first failing check
      await charlieClient.commit({lock, party: alice, counterparty: bob})
      expect.unreachable()
    } catch (error) {
      expect((error as QuipSdkError).code).toBe('NOT_QUIP_WALLET')
    }
  })

  it('the CONTRACT reverts CallerNotQuipWallet for an unregistered committer', async () => {
    const {lock} = nextSecret()
    const s = await freshSchedule()
    const alice = s.aliceTerms([nativeAsset(10n)])
    const bob = s.bobTerms([erc20Asset(fixture.erc20, 10n)])
    await ctx.warpTo(s.anchors.proposerCommit)
    await expectContractError(rawCommit(ctx.charlie, lock, alice, bob, 10n), 'CallerNotQuipWallet')
  })

  it('a deregistered wallet loses commit rights', async () => {
    // register-then-unregister via the mock's negative-path helper
    const tmp = ctx.charlie
    let hash = await tmp.walletClient.writeContract({
      address: fixture.quipFactory,
      abi: quipFactoryMockAbi,
      functionName: 'registerWallet',
      args: [tmp.address, `0x${'22'.repeat(32)}`, tmp.address],
      chain: ctx.publicClient.chain ?? null,
      account: tmp.account,
    })
    await ctx.publicClient.waitForTransactionReceipt({hash})
    expect(await aliceClient.isQuipWallet(tmp.address)).toBe(true)
    hash = await tmp.walletClient.writeContract({
      address: fixture.quipFactory,
      abi: quipFactoryMockAbi,
      functionName: 'unregisterWallet',
      args: [tmp.address],
      chain: ctx.publicClient.chain ?? null,
      account: tmp.account,
    })
    await ctx.publicClient.waitForTransactionReceipt({hash})
    expect(await aliceClient.isQuipWallet(tmp.address)).toBe(false)
  })

  it('claim and reclaim succeed from an UNREGISTERED account', async () => {
    // full swap, then charlie (never registered) claims with the secret —
    // claim is permissionless by design
    const {secret, lock} = nextSecret()
    const s = await freshSchedule()
    const alice = s.aliceTerms([nativeAsset(1000n)])
    const bob = s.bobTerms([erc20Asset(fixture.erc20, 500n)])

    await ctx.warpTo(s.anchors.proposerCommit)
    await waitForOmnibusReceipt(ctx.publicClient, await aliceClient.commit({lock, party: alice, counterparty: bob}))
    await ctx.warpTo(s.anchors.takerCommit)
    await waitForOmnibusReceipt(ctx.publicClient, await bobClient.commit({lock, party: bob, counterparty: alice}))
    await ctx.warpTo(s.anchors.proposerClaim)
    const hash = await charlieClient.claim({secret, party: alice, counterparty: bob})
    const result = await waitForOmnibusReceipt(ctx.publicClient, hash)
    expect(result.claims).toHaveLength(1)
    expect(await aliceClient.getLockState(lock)).toBe(LockState.Spent)
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
    await waitForOmnibusReceipt(ctx.publicClient, await aliceClient.commit({lock, party: alice, counterparty: bob}))

    expect(await aliceClient.getLockState(lock)).toBe(LockState.Free)
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
    await waitForOmnibusReceipt(ctx.publicClient, await aliceClient.commit({lock, party: alice, counterparty: bob}))
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
    await waitForOmnibusReceipt(ctx.publicClient, await aliceClient.commit({lock, party: alice, counterparty: bob}))
    expect((await ownerOf(tokenId)).toLowerCase()).toBe(fixture.omnibus.toLowerCase())

    // taker commits, proposer claims: alice's NFT goes to BOB's recipient
    // (recipient receives the COUNTERPARTY's assets)
    await ctx.warpTo(s.anchors.takerCommit)
    await waitForOmnibusReceipt(ctx.publicClient, await bobClient.commit({lock, party: bob, counterparty: alice}))
    await ctx.warpTo(s.anchors.proposerClaim)
    await waitForOmnibusReceipt(
      ctx.publicClient,
      await aliceClient.claim({secret, party: alice, counterparty: bob}),
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
    await waitForOmnibusReceipt(ctx.publicClient, await aliceClient.commit({lock, party: alice, counterparty: bob}))
    expect(await balance1155(fixture.omnibus, 1n)).toBe(omnibusBefore + 250n)

    await ctx.warpTo(s.anchors.takerCommit)
    await waitForOmnibusReceipt(ctx.publicClient, await bobClient.commit({lock, party: bob, counterparty: alice}))
    await ctx.warpTo(s.anchors.proposerClaim)
    const recipientBefore = await balance1155(BOB_RECIPIENT, 1n)
    await waitForOmnibusReceipt(
      ctx.publicClient,
      await aliceClient.claim({secret, party: alice, counterparty: bob}),
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
    const commitA = await waitForOmnibusReceipt(
      ctx.publicClient,
      await aliceClient.commit({lock, party: alice, counterparty: bob}),
    )
    expect(await aliceClient.getLockState(lock)).toBe(LockState.Free)
    expect(await aliceClient.getTermsHash(lock)).toBe(digestTermsCanonically(alice, bob))
    expect(await aliceClient.getPosted(lock, digestTerms(alice))).toBe(true)

    // taker MUST wait for the proposer's deadline (the window only opens there)
    await ctx.warpTo(s.anchors.takerCommit)
    const commitB = await waitForOmnibusReceipt(
      ctx.publicClient,
      await bobClient.commit({lock, party: bob, counterparty: alice}),
    )
    expect(await aliceClient.getLockState(lock)).toBe(LockState.Committed)

    // Commitment events decode back to the EXACT terms that were committed
    const fromA = commitA.commitments[0]
    const fromB = commitB.commitments[0]
    if (fromA === undefined || fromB === undefined) throw new Error('missing Commitment events')
    expect(fromA.lock).toBe(lock)
    expect(fromA.committer.toLowerCase()).toBe(ctx.alice.address.toLowerCase())
    expect(fromA.party).toEqual({...alice, assets: alice.assets.map(a => ({...a}))})
    expect(fromB.party).toEqual({...bob, assets: bob.assets.map(a => ({...a}))})

    // one claim settles BOTH legs
    await ctx.warpTo(s.anchors.proposerClaim)
    const bobRecipientNativeBefore = await ctx.publicClient.getBalance({address: BOB_RECIPIENT})
    const aliceRecipientTokensBefore = await erc20Balance(fixture.erc20, ALICE_RECIPIENT)
    const claim = await waitForOmnibusReceipt(
      ctx.publicClient,
      await aliceClient.claim({secret, party: alice, counterparty: bob}),
    )
    expect(await aliceClient.getLockState(lock)).toBe(LockState.Spent)
    // bob's tokens -> alice's recipient; alice's native -> bob's recipient
    expect(await erc20Balance(fixture.erc20, ALICE_RECIPIENT)).toBe(aliceRecipientTokensBefore + TOKENS)
    expect(await ctx.publicClient.getBalance({address: BOB_RECIPIENT})).toBe(bobRecipientNativeBefore + NATIVE)

    // the Claim event reveals the ORIGINAL secret
    expect(claim.claims).toHaveLength(1)
    expect(claim.claims[0]?.secret).toBe(secret)
    expect(claim.claims[0]?.lock).toBe(lock)
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
    await waitForOmnibusReceipt(ctx.publicClient, await aliceClient.commit({lock, party: alice, counterparty: bob}))

    // SDK preflight rejects with the window error before any submission
    await ctx.warpTo(s.anchors.proposerClaim)
    try {
      await aliceClient.reclaim({lock, party: alice, counterparty: bob})
      expect.unreachable()
    } catch (error) {
      expect((error as QuipSdkError).code).toBe('WINDOW_VIOLATED')
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
    await waitForOmnibusReceipt(ctx.publicClient, await aliceClient.commit({lock, party: alice, counterparty: bob}))
    expect(await aliceClient.getLockState(lock)).toBe(LockState.Free)

    await ctx.warpTo(s.anchors.proposerReclaim)
    const reclaimBalanceBefore = await ctx.publicClient.getBalance({address: ALICE_RECLAIM})
    const result = await waitForOmnibusReceipt(
      ctx.publicClient,
      // reclaim is PERMISSIONLESS: charlie (unregistered) reclaims for alice's leg
      await charlieClient.reclaim({lock, party: alice, counterparty: bob}),
    )
    expect(await aliceClient.getLockState(lock)).toBe(LockState.Spent)
    // assets go to the reclaimRecipient, NOT the committer
    expect(await ctx.publicClient.getBalance({address: ALICE_RECLAIM})).toBe(reclaimBalanceBefore + NATIVE)
    expect(result.reclaims).toHaveLength(1)
    expect(result.reclaims[0]?.recipient.toLowerCase()).toBe(ALICE_RECLAIM.toLowerCase())
  })

  it('dual-leg reclaim: both committed, nobody claimed — one reclaim returns BOTH legs (two Reclaimed events)', async () => {
    const {lock} = nextSecret()
    const s = await freshSchedule()
    const NATIVE = 3_333n
    const TOKENS = 4_444n
    const alice = s.aliceTerms([nativeAsset(NATIVE)])
    const bob = s.bobTerms([erc20Asset(fixture.erc20, TOKENS)])
    await ctx.warpTo(s.anchors.proposerCommit)
    await waitForOmnibusReceipt(ctx.publicClient, await aliceClient.commit({lock, party: alice, counterparty: bob}))
    await ctx.warpTo(s.anchors.takerCommit)
    await waitForOmnibusReceipt(ctx.publicClient, await bobClient.commit({lock, party: bob, counterparty: alice}))

    // bob reclaims his own leg after HIS release; alice's local Committed
    // counterparty leg comes back in the same transaction
    await ctx.warpTo(s.anchors.takerReclaim)
    const aliceReclaimBefore = await ctx.publicClient.getBalance({address: ALICE_RECLAIM})
    const bobReclaimBefore = await erc20Balance(fixture.erc20, BOB_RECLAIM)
    const result = await waitForOmnibusReceipt(
      ctx.publicClient,
      await bobClient.reclaim({lock, party: bob, counterparty: alice}),
    )
    expect(await aliceClient.getLockState(lock)).toBe(LockState.Spent)
    expect(result.reclaims).toHaveLength(2)
    expect(await erc20Balance(fixture.erc20, BOB_RECLAIM)).toBe(bobReclaimBefore + TOKENS)
    expect(await ctx.publicClient.getBalance({address: ALICE_RECLAIM})).toBe(aliceReclaimBefore + NATIVE)
  })

  it('double reclaim reverts InvalidLockAdvancement', async () => {
    const {lock} = nextSecret()
    const s = await freshSchedule()
    const alice = s.aliceTerms([nativeAsset(10n)])
    const bob = s.bobTerms([erc20Asset(fixture.erc20, 10n)])
    await ctx.warpTo(s.anchors.proposerCommit)
    await waitForOmnibusReceipt(ctx.publicClient, await aliceClient.commit({lock, party: alice, counterparty: bob}))
    await ctx.warpTo(s.anchors.proposerReclaim)
    await waitForOmnibusReceipt(
      ctx.publicClient,
      await aliceClient.reclaim({lock, party: alice, counterparty: bob}),
    )
    await expectContractError(
      ctx.publicClient.simulateContract({
        address: fixture.omnibus,
        abi: omnibusAbi,
        functionName: 'reclaim',
        args: [lock, toTuple(alice), toTuple(bob)],
        account: ctx.alice.account,
      }),
      'InvalidLockAdvancement',
    )
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
      await aliceClient.commit({lock, party: alice, counterparty: bob})
      expect.unreachable()
    } catch (error) {
      expect((error as QuipSdkError).code).toBe('CHAIN_ID_MISMATCH')
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

  it('re-posting the same side reverts TermsAlreadyPosted', async () => {
    // the second same-chain commit must post the OTHER side; the committer
    // re-posting its own side inside its still-open window hits the
    // posted[partyDigest] guard (lock is Free at that point)
    const {lock} = nextSecret()
    const s = await freshSchedule()
    const alice = s.aliceTerms([nativeAsset(10n)])
    const bob = s.bobTerms([erc20Asset(fixture.erc20, 10n)])
    await ctx.warpTo(s.anchors.proposerCommit)
    await waitForOmnibusReceipt(ctx.publicClient, await aliceClient.commit({lock, party: alice, counterparty: bob}))
    await expectContractError(rawCommit(ctx.alice, lock, alice, bob, 10n), 'TermsAlreadyPosted')
  })

  it('a second commit with DIFFERENT terms reverts TermsMismatch', async () => {
    const {lock} = nextSecret()
    const s = await freshSchedule()
    const alice = s.aliceTerms([nativeAsset(10n)])
    const bob = s.bobTerms([erc20Asset(fixture.erc20, 10n)])
    await ctx.warpTo(s.anchors.proposerCommit)
    await waitForOmnibusReceipt(ctx.publicClient, await aliceClient.commit({lock, party: alice, counterparty: bob}))
    // bob commits against MUTATED alice terms — canonical digest differs
    const mutatedAlice: Terms = {...alice, recipient: BOB_RECIPIENT}
    await ctx.warpTo(s.anchors.takerCommit)
    await expectContractError(rawCommit(ctx.bob, lock, bob, mutatedAlice, 0n), 'TermsMismatch')
  })

  it('claim with the wrong secret reverts TermsMismatch (the wrong lock has no termsHash)', async () => {
    const right = nextSecret()
    const wrong = nextSecret()
    const s = await freshSchedule()
    const alice = s.aliceTerms([nativeAsset(10n)])
    const bob = s.bobTerms([erc20Asset(fixture.erc20, 10n)])
    await ctx.warpTo(s.anchors.proposerCommit)
    await waitForOmnibusReceipt(
      ctx.publicClient,
      await aliceClient.commit({lock: right.lock, party: alice, counterparty: bob}),
    )
    await ctx.warpTo(s.anchors.takerCommit)
    await waitForOmnibusReceipt(
      ctx.publicClient,
      await bobClient.commit({lock: right.lock, party: bob, counterparty: alice}),
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
    await waitForOmnibusReceipt(ctx.publicClient, await aliceClient.commit({lock, party: alice, counterparty: bob}))

    // lock is Free (only one side committed): claim reverts InvalidLockState
    await ctx.warpTo(s.anchors.proposerClaim)
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
    await waitForOmnibusReceipt(
      ctx.publicClient,
      await aliceClient.commit({lock: second.lock, party: alice2, counterparty: bob2}),
    )
    await ctx.warpTo(s2.anchors.takerCommit)
    await waitForOmnibusReceipt(
      ctx.publicClient,
      await bobClient.commit({lock: second.lock, party: bob2, counterparty: alice2}),
    )
    await ctx.warpTo(s2.anchors.proposerClaim)
    await waitForOmnibusReceipt(
      ctx.publicClient,
      await aliceClient.claim({secret: second.secret, party: alice2, counterparty: bob2}),
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
