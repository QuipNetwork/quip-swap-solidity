/**
 * Holistic functional smoke test — `bun run smoke`.
 *
 * A fast "is the whole stack on fire?" gate, distinct from the exhaustive
 * integration/cross-chain vitest suites. It drives ONE same-chain swap and
 * ONE cross-chain swap to completion THROUGH THE WORKFLOW LAYER
 * (`planSameChainSwap`, `getSameChainSwapStatus`, `validateCrossChainSchedule`,
 * `verifyRemoteCommitment`) against two real Anvil nodes, asserting the
 * happy path composes end-to-end. It is deliberately shallow on edge cases
 * (the integration suites own those) and broad on "does the real flow run".
 *
 * Lifecycle (process orchestration):
 *   1. `forge build` (artifacts may be stale).
 *   2. Start two Anvils on free ports — chain 31337 (node A) and 31338 (node B).
 *   3. Deploy the standard fixture (Omnibus + mock tokens,
 *      permissionless commits) on EACH node.
 *   4. Run the flow. On the FIRST broken step: print `SMOKE FAILED at step N`
 *      plus the error, tear down BOTH anvils, exit 1 — do not continue.
 *   5. On success: per-step `ok` log, `SMOKE PASSED`, tear down, exit 0.
 *   6. Teardown runs on EVERY exit path (success / failure / uncaught) via
 *      nested try/finally and a signal handler, so no anvil orphans leak.
 *
 * Imports the SDK from `src/` (pre-build) and reuses the integration test
 * helpers (`test/helpers/*`) rather than duplicating chain/fixture setup —
 * runs under `bun` with no build step, consistent with the integration runner.
 *
 * NOT a vitest file and NOT folded into the integration runner, by design:
 * the exit code is what CI keys on.
 */
import {spawnSync} from 'node:child_process'
import {dirname, join} from 'node:path'
import {fileURLToPath} from 'node:url'
import {getAddress} from 'viem'
import type {Address, Hex} from 'viem'
import {
  createOmnibusClient,
  erc20Asset,
  extractSecretFromClaims,
  generateSecret,
  getSameChainSwapStatus,
  LockState,
  nativeAsset,
  planApprovals,
  planSameChainSwap,
  buildKeyedSigner,
  QuipSwapError,
  submitApproval,
  validateCrossChainSchedule,
  verifyRemoteCommitment,
} from '../src/index.js'
import type {CommitAuth, OmnibusClient} from '../src/index.js'
import type {Terms} from '../src/index.js'
import {startAnvil} from '../test/helpers/anvil.js'
import type {AnvilInstance} from '../test/helpers/anvil.js'
import {connectChain, deployFixture} from '../test/helpers/chain.js'
import type {ChainContext, Fixture} from '../test/helpers/chain.js'
import {erc20MockAbi} from '../test/helpers/mockAbis.js'

const sdkRoot = dirname(dirname(fileURLToPath(import.meta.url)))
const repoRoot = join(sdkRoot, '..')

const CHAIN_A_ID = 31_337
const CHAIN_B_ID = 31_338
const ZERO_BYTES32 = `0x${'00'.repeat(32)}` as Hex

/**
 * Keyed ERC-7913 auth for `addr` via the fixture's AcceptAll VerifierMock
 * (the address doubles as the key; the mock ignores signatures, so '0x').
 */
function keyedAuth(fixture: Fixture, addr: Address): CommitAuth {
  return {signer: buildKeyedSigner(fixture.verifier, addr), signature: '0x', walletBinding: ZERO_BYTES32}
}

// distinct, checksummed recipients per flow/role so balance deltas are
// unambiguous and decoded-event addresses compare byte-equal. A hex suffix
// is left-padded to a full 20-byte address, then checksummed.
const addr = (suffix: string): Address => getAddress(`0x${suffix.padStart(40, '0')}`)
const SC_ALICE_RECIPIENT = addr('5ca1ce')
const SC_BOB_RECIPIENT = addr('5cb0b0')
const SC_ALICE_RECLAIM = addr('5ca1c1')
const SC_BOB_RECLAIM = addr('5cb0b1')
const XC_ALICE_RECIPIENT = addr('cca1ce')
const XC_BOB_RECIPIENT = addr('ccb0b0')
const XC_ALICE_RECLAIM = addr('cca1c1')
const XC_BOB_RECLAIM = addr('ccb0b1')

const ONE_ETH = 10n ** 18n
const TOKEN = (n: bigint): bigint => n * 10n ** 18n

// ---------------------------------------------------------------------------
// tiny assertion + step harness (no vitest)
// ---------------------------------------------------------------------------

/** Marker so the top-level catch knows a numbered step already logged its failure. */
class StepFailure extends Error {}

/** Throws with `message` when `cond` is falsy. */
function assert(cond: unknown, message: string): asserts cond {
  if (!cond) throw new Error(message)
}

/** Asserts `fn` throws a {@link QuipSwapError} with the given code. */
function assertThrowsCode(fn: () => unknown, code: string, message: string): void {
  try {
    fn()
  } catch (error) {
    if (error instanceof QuipSwapError && error.code === code) return
    throw new Error(`${message}: expected QuipSwapError ${code}, got ${String(error)}`)
  }
  throw new Error(`${message}: expected QuipSwapError ${code}, but nothing was thrown`)
}

let stepCounter = 0

/**
 * Runs one numbered step. Logs `[scope] step N ok: label — detail` on
 * success; on failure prints the fail-fast banner and rethrows a
 * {@link StepFailure} so the runner tears down and exits non-zero.
 */
async function step(scope: string, label: string, fn: () => Promise<string | void>): Promise<void> {
  stepCounter += 1
  const n = stepCounter
  try {
    const detail = await fn()
    console.log(`[${scope}] step ${n} ok: ${label}${detail ? ` — ${detail}` : ''}`)
  } catch (error) {
    console.error(`\nSMOKE FAILED at step ${n}: [${scope}] ${label}`)
    console.error(error)
    throw new StepFailure(`step ${n}`)
  }
}

// ---------------------------------------------------------------------------
// small on-chain helpers (reuse the mock ABIs from the test fixture helper)
// ---------------------------------------------------------------------------

/** Reads an ERC-20 balance via the mock ABI. */
async function erc20BalanceOf(ctx: ChainContext, token: Address, account: Address): Promise<bigint> {
  return ctx.publicClient.readContract({address: token, abi: erc20MockAbi, functionName: 'balanceOf', args: [account]})
}

/** Mints mock ERC-20 to `to` and waits for inclusion (test setup, not workflow). */
async function mintErc20(ctx: ChainContext, token: Address, to: Address, amount: bigint): Promise<void> {
  const hash = await ctx.deployer.walletClient.writeContract({
    address: token,
    abi: erc20MockAbi,
    functionName: 'mint',
    args: [to, amount],
    chain: ctx.publicClient.chain ?? null,
    account: ctx.deployer.account,
  })
  await ctx.publicClient.waitForTransactionReceipt({hash})
}

/**
 * Satisfies every outstanding approval for `terms` from `committer` via the
 * SDK approval planner, exact-mode for ERC-20. Returns how many approvals
 * were submitted (0 for an all-native leg — exercises the satisfied path).
 */
async function ensureApprovals(
  ctx: ChainContext,
  omnibus: Address,
  committer: ChainContext['alice'],
  terms: Terms,
): Promise<number> {
  const plan = await planApprovals({
    publicClient: ctx.publicClient,
    omnibusAddress: omnibus,
    committer: committer.address,
    terms,
  })
  let submitted = 0
  for (const item of plan.items) {
    if (item.satisfied) continue
    const hash = await submitApproval({
      publicClient: ctx.publicClient,
      walletClient: committer.walletClient,
      omnibusAddress: omnibus,
      item,
      erc20Mode: 'exact',
    })
    await ctx.publicClient.waitForTransactionReceipt({hash})
    submitted += 1
  }
  return submitted
}

/** The six interleaved deadlines + per-action anchors derived from a base time. */
interface Schedule {
  readonly aliceCommit: bigint
  readonly bobCommit: bigint
  readonly aliceClaim: bigint
  readonly bobClaim: bigint
  readonly aliceReclaim: bigint
  readonly bobReclaim: bigint
  readonly atProposerCommit: bigint
  readonly atTakerCommit: bigint
  readonly atProposerClaim: bigint
  readonly atTakerClaim: bigint
}

/** Builds the canonical 1000s-step interleaved schedule (Alice proposer). */
function buildSchedule(base: bigint): Schedule {
  return {
    aliceCommit: base + 1000n,
    bobCommit: base + 2000n,
    aliceClaim: base + 3000n,
    bobClaim: base + 4000n,
    aliceReclaim: base + 5000n,
    bobReclaim: base + 6000n,
    atProposerCommit: base + 500n,
    atTakerCommit: base + 1500n,
    atProposerClaim: base + 2500n,
    atTakerClaim: base + 3500n,
  }
}

function makeAliceTerms(
  chainId: number,
  sender: Address,
  s: Schedule,
  recipient: Address,
  reclaim: Address,
  assets: Terms['assets'],
): Terms {
  return {
    chainId: BigInt(chainId),
    sender,
    reclaimRecipient: reclaim,
    recipient,
    commitmentDeadline: s.aliceCommit,
    claimDeadline: s.aliceClaim,
    reclaimRelease: s.aliceReclaim,
    assets,
  }
}

function makeBobTerms(
  chainId: number,
  sender: Address,
  s: Schedule,
  recipient: Address,
  reclaim: Address,
  assets: Terms['assets'],
): Terms {
  return {
    chainId: BigInt(chainId),
    sender,
    reclaimRecipient: reclaim,
    recipient,
    commitmentDeadline: s.bobCommit,
    claimDeadline: s.bobClaim,
    reclaimRelease: s.bobReclaim,
    assets,
  }
}

// ---------------------------------------------------------------------------
// Flow part 1 — same-chain swap THROUGH the workflow layer (node A)
// ---------------------------------------------------------------------------

async function runSameChain(A: ChainContext, fixtureA: Fixture): Promise<void> {
  const scope = 'same-chain'
  const aliceClient = createOmnibusClient({
    address: fixtureA.omnibus,
    publicClient: A.publicClient,
    walletClient: A.alice.walletClient,
  })
  const bobClient = createOmnibusClient({
    address: fixtureA.omnibus,
    publicClient: A.publicClient,
    walletClient: A.bob.walletClient,
  })

  const base = await A.now()
  const s = buildSchedule(base)
  const NATIVE = ONE_ETH
  const TOKENS = TOKEN(500n)
  const aliceTerms = makeAliceTerms(
    CHAIN_A_ID,
    A.alice.address,
    s,
    SC_ALICE_RECIPIENT,
    SC_ALICE_RECLAIM,
    [nativeAsset(NATIVE)],
  )
  const bobTerms = makeBobTerms(
    CHAIN_A_ID,
    A.bob.address,
    s,
    SC_BOB_RECIPIENT,
    SC_BOB_RECLAIM,
    [erc20Asset(fixtureA.erc20, TOKENS)],
  )

  const {secret, lock} = generateSecret()

  // give Bob the tokens his leg offers (test setup)
  await mintErc20(A, fixtureA.erc20, A.bob.address, TOKEN(1_000_000n))

  // step: plan + role normalization. The smoke schedule uses 1000s gaps
  // (compact, for fast warping), below the default buffer — override to 1000n.
  const planOpts = {minimumBufferSeconds: 1000n}
  let plan = planSameChainSwap(aliceTerms, bobTerms, planOpts)
  await step(scope, 'planSameChainSwap normalizes roles', async () => {
    plan = planSameChainSwap(aliceTerms, bobTerms, planOpts)
    assert(plan.proposerTerms === aliceTerms, 'expected Alice (smaller commitmentDeadline) to be the proposer')
    assert(plan.takerTerms === bobTerms, 'expected Bob to be the taker')
    assert(BigInt(plan.canonicalDigest) !== 0n, 'canonicalDigest must be non-zero')
    return 'Alice=proposer, Bob=taker, canonicalDigest non-zero'
  })

  // step: status before any commit
  await step(scope, 'status before commit', async () => {
    await A.warpTo(s.atProposerCommit)
    const {status} = await getSameChainSwapStatus(aliceClient, lock, plan)
    assert(status === 'awaiting-proposer-commit', `expected awaiting-proposer-commit, got ${status}`)
    return `status ${status}`
  })

  // step: proposer (Alice, native) commits → Free
  await step(scope, 'proposer commits', async () => {
    const submitted = await ensureApprovals(A, fixtureA.omnibus, A.alice, aliceTerms)
    assert(submitted === 0, 'a native-only proposer leg should need no approvals')
    const hash = await aliceClient.commit({lock, party: aliceTerms, counterparty: bobTerms, auth: keyedAuth(fixtureA, A.alice.address)})
    await aliceClient.waitForReceipt(hash)
    const lockState = await aliceClient.getLockState(lock)
    assert(lockState === LockState.Free, `expected Free, got ${LockState[lockState]}`)
    const {status} = await getSameChainSwapStatus(aliceClient, lock, plan)
    assert(status === 'awaiting-taker-window', `expected awaiting-taker-window, got ${status}`)
    return `lock Free, status ${status}`
  })

  // step: advance past proposer deadline → taker window opens
  await step(scope, 'taker window opens', async () => {
    await A.warpTo(s.atTakerCommit)
    const {status} = await getSameChainSwapStatus(aliceClient, lock, plan)
    assert(status === 'awaiting-taker-commit', `expected awaiting-taker-commit, got ${status}`)
    return `status ${status}`
  })

  // step: taker (Bob, ERC-20) approves + commits → Committed
  await step(scope, 'taker commits', async () => {
    const submitted = await ensureApprovals(A, fixtureA.omnibus, A.bob, bobTerms)
    assert(submitted === 1, `expected one ERC-20 approval, got ${submitted}`)
    const hash = await bobClient.commit({lock, party: bobTerms, counterparty: aliceTerms, auth: keyedAuth(fixtureA, A.bob.address)})
    await bobClient.waitForReceipt(hash)
    const lockState = await aliceClient.getLockState(lock)
    assert(lockState === LockState.Committed, `expected Committed, got ${LockState[lockState]}`)
    const {status} = await getSameChainSwapStatus(aliceClient, lock, plan)
    assert(status === 'awaiting-claim-window', `expected awaiting-claim-window, got ${status}`)
    return `lock Committed, status ${status}`
  })

  // step: advance into the claim window → claimable
  await step(scope, 'claim window opens', async () => {
    await A.warpTo(s.atProposerClaim)
    const {status} = await getSameChainSwapStatus(aliceClient, lock, plan)
    assert(status === 'claimable', `expected claimable, got ${status}`)
    return `status ${status}`
  })

  // step: claim settles BOTH legs → Spent
  await step(scope, 'claim settles both legs', async () => {
    const aliceRecipientTokensBefore = await erc20BalanceOf(A, fixtureA.erc20, SC_ALICE_RECIPIENT)
    const bobRecipientEthBefore = await A.publicClient.getBalance({address: SC_BOB_RECIPIENT})

    const hash = await aliceClient.claim({secret, party: aliceTerms, counterparty: bobTerms})
    const receipt = await aliceClient.waitForReceipt(hash)

    const lockState = await aliceClient.getLockState(lock)
    assert(lockState === LockState.Spent, `expected Spent, got ${LockState[lockState]}`)
    const {status} = await getSameChainSwapStatus(aliceClient, lock, plan)
    assert(status === 'settled', `expected settled, got ${status}`)

    // Bob's tokens → Alice's recipient; Alice's ETH → Bob's recipient
    const aliceRecipientTokensAfter = await erc20BalanceOf(A, fixtureA.erc20, SC_ALICE_RECIPIENT)
    const bobRecipientEthAfter = await A.publicClient.getBalance({address: SC_BOB_RECIPIENT})
    assert(
      aliceRecipientTokensAfter - aliceRecipientTokensBefore === TOKENS,
      "Bob's tokens did not reach Alice's recipient",
    )
    assert(bobRecipientEthAfter - bobRecipientEthBefore === NATIVE, "Alice's ETH did not reach Bob's recipient")

    const revealed = extractSecretFromClaims(receipt.claims, lock)
    assert(revealed === secret, 'revealed secret from Claim event does not match the original')
    return `lock Spent, status settled, both legs settled, secret revealed`
  })
}

// ---------------------------------------------------------------------------
// Flow part 2 — cross-chain swap THROUGH the workflow layer (nodes A + B)
// ---------------------------------------------------------------------------

async function runCrossChain(A: ChainContext, fixtureA: Fixture, B: ChainContext, fixtureB: Fixture): Promise<void> {
  const scope = 'cross-chain'
  // Alice's leg is on node A; Bob's leg is on node B. Each client is bound to
  // the node holding the leg it acts on.
  const aliceOnA = createOmnibusClient({
    address: fixtureA.omnibus,
    publicClient: A.publicClient,
    walletClient: A.alice.walletClient,
  })
  const bobOnA = createOmnibusClient({
    address: fixtureA.omnibus,
    publicClient: A.publicClient,
    walletClient: A.bob.walletClient,
  })
  const aliceOnB = createOmnibusClient({
    address: fixtureB.omnibus,
    publicClient: B.publicClient,
    walletClient: B.alice.walletClient,
  })

  // one shared schedule; base from the LATER node clock so every warp is forward
  const nowA = await A.now()
  const nowB = await B.now()
  const base = (nowA > nowB ? nowA : nowB) + 10n
  const s = buildSchedule(base)
  const NATIVE = ONE_ETH
  const TOKENS = TOKEN(750n)
  const aliceTerms = makeAliceTerms(
    CHAIN_A_ID,
    A.alice.address,
    s,
    XC_ALICE_RECIPIENT,
    XC_ALICE_RECLAIM,
    [nativeAsset(NATIVE)],
  )
  const bobTerms = makeBobTerms(
    CHAIN_B_ID,
    B.bob.address,
    s,
    XC_BOB_RECIPIENT,
    XC_BOB_RECLAIM,
    [erc20Asset(fixtureB.erc20, TOKENS)],
  )

  const {secret, lock} = generateSecret()

  // Bob's tokens live on node B
  await mintErc20(B, fixtureB.erc20, B.bob.address, TOKEN(1_000_000n))

  /** Keep both chains' clocks coordinated against the shared schedule. */
  async function warpBoth(ts: bigint): Promise<void> {
    await A.warpTo(ts)
    await B.warpTo(ts)
  }

  // step: validate schedule (accept) + reject the role-inverted copy
  await step(scope, 'validateCrossChainSchedule accepts valid roles, rejects inverted', async () => {
    const result = validateCrossChainSchedule({
      proposerTerms: aliceTerms,
      takerTerms: bobTerms,
      minimumBufferSeconds: 1000n,
    })
    assert(result.reactionBufferSeconds === s.aliceReclaim - s.aliceClaim, 'unexpected reaction buffer')
    // the safety crux: a secret-holding TAKER must be rejected
    assertThrowsCode(
      () =>
        validateCrossChainSchedule({
          proposerTerms: bobTerms,
          takerTerms: aliceTerms,
          minimumBufferSeconds: 1000n,
        }),
      'SECRET_HOLDER_NOT_PROPOSER',
      'role-inverted schedule must be rejected',
    )
    return 'valid accepted, role-inverted rejected'
  })

  // step: Alice commits her leg on node A (Unused → Committed, no Free cross-chain)
  await step(scope, 'Alice commits on node A', async () => {
    await warpBoth(s.atProposerCommit)
    const submitted = await ensureApprovals(A, fixtureA.omnibus, A.alice, aliceTerms)
    assert(submitted === 0, 'a native-only leg should need no approvals')
    const hash = await aliceOnA.commit({lock, party: aliceTerms, counterparty: bobTerms, auth: keyedAuth(fixtureA, A.alice.address)})
    await aliceOnA.waitForReceipt(hash)
    const lockState = await aliceOnA.getLockState(lock)
    assert(lockState === LockState.Committed, `expected Committed on A, got ${LockState[lockState]}`)
    return 'node A lock Committed'
  })

  // step: the mandatory off-chain remote-commitment check (what the contract can't do)
  await step(scope, 'verifyRemoteCommitment on node A', async () => {
    const status = await verifyRemoteCommitment(bobOnA, lock, aliceTerms, bobTerms)
    assert(status.committed, 'remote commitment not reported committed')
    assert(status.proposerPosted, 'proposer side not reported posted')
    assert(status.termsHashMatches, 'on-chain termsHash does not match the pairing')
    return 'committed + posted + termsHash match'
  })

  // step: Bob commits his leg on node B
  await step(scope, 'Bob commits on node B', async () => {
    await warpBoth(s.atTakerCommit)
    const submitted = await ensureApprovals(B, fixtureB.omnibus, B.bob, bobTerms)
    assert(submitted === 1, `expected one ERC-20 approval on B, got ${submitted}`)
    const bobOnB = createOmnibusClient({
      address: fixtureB.omnibus,
      publicClient: B.publicClient,
      walletClient: B.bob.walletClient,
    })
    const hash = await bobOnB.commit({lock, party: bobTerms, counterparty: aliceTerms, auth: keyedAuth(fixtureB, B.bob.address)})
    await bobOnB.waitForReceipt(hash)
    const lockState = await aliceOnB.getLockState(lock)
    assert(lockState === LockState.Committed, `expected Committed on B, got ${LockState[lockState]}`)
    return 'node B lock Committed'
  })

  // step: Alice claims Bob's leg ON NODE B (this reveals the secret on B)
  let extractedSecret: Hex | undefined
  await step(scope, 'Alice claims Bob leg on node B (reveals secret)', async () => {
    await warpBoth(s.atProposerClaim)
    const aliceRecipientTokensBefore = await erc20BalanceOf(B, fixtureB.erc20, XC_ALICE_RECIPIENT)
    const hash = await aliceOnB.claim({secret, party: aliceTerms, counterparty: bobTerms})
    const receipt = await aliceOnB.waitForReceipt(hash)
    const lockState = await aliceOnB.getLockState(lock)
    assert(lockState === LockState.Spent, `expected Spent on B, got ${LockState[lockState]}`)
    const aliceRecipientTokensAfter = await erc20BalanceOf(B, fixtureB.erc20, XC_ALICE_RECIPIENT)
    assert(
      aliceRecipientTokensAfter - aliceRecipientTokensBefore === TOKENS,
      "Bob's tokens did not reach Alice's recipient on B",
    )
    extractedSecret = extractSecretFromClaims(receipt.claims, lock)
    return 'node B lock Spent, Bob tokens → Alice recipient'
  })

  // step: extract the revealed secret (the cross-chain mechanism)
  await step(scope, 'extract revealed secret from node B Claim event', async () => {
    assert(extractedSecret !== undefined, 'no Claim event secret found on node B')
    assert(extractedSecret === secret, 'extracted secret does not equal the original')
    return 'extracted secret matches original'
  })

  // step: Bob claims Alice's leg ON NODE A using the extracted secret
  await step(scope, 'Bob claims Alice leg on node A', async () => {
    assert(extractedSecret !== undefined, 'extracted secret missing')
    await warpBoth(s.atTakerClaim)
    const bobRecipientEthBefore = await A.publicClient.getBalance({address: XC_BOB_RECIPIENT})
    const hash = await bobOnA.claim({secret: extractedSecret, party: bobTerms, counterparty: aliceTerms})
    await bobOnA.waitForReceipt(hash)
    const lockState = await aliceOnA.getLockState(lock)
    assert(lockState === LockState.Spent, `expected Spent on A, got ${LockState[lockState]}`)
    const bobRecipientEthAfter = await A.publicClient.getBalance({address: XC_BOB_RECIPIENT})
    assert(bobRecipientEthAfter - bobRecipientEthBefore === NATIVE, "Alice's ETH did not reach Bob's recipient on A")
    return 'node A lock Spent, Alice ETH → Bob recipient'
  })

  // step: both legs terminal
  await step(scope, 'both legs Spent', async () => {
    const aState = await aliceOnA.getLockState(lock)
    const bState = await aliceOnB.getLockState(lock)
    assert(aState === LockState.Spent && bState === LockState.Spent, 'both legs must be Spent')
    return 'node A Spent, node B Spent'
  })
}

// ---------------------------------------------------------------------------
// runner: process lifecycle (forge build → two anvils → flow → teardown)
// ---------------------------------------------------------------------------

let anvilA: AnvilInstance | undefined
let anvilB: AnvilInstance | undefined

/** Stops both anvils; safe to call repeatedly / on any exit path. */
function teardown(): void {
  anvilA?.stop()
  anvilB?.stop()
  anvilA = undefined
  anvilB = undefined
}

// kill anvils if the process is interrupted, so nothing leaks
for (const signal of ['SIGINT', 'SIGTERM'] as const) {
  process.once(signal, () => {
    teardown()
    process.exit(1)
  })
}

async function main(): Promise<void> {
  // 1. fresh artifacts (mirrors the integration runner)
  console.log('[smoke] forge build ...')
  const build = spawnSync('forge', ['build'], {cwd: repoRoot, stdio: 'inherit'})
  if (build.status !== 0) {
    throw new Error('forge build failed; cannot run the smoke test')
  }

  // 2. two anvils on free ports
  anvilA = await startAnvil({chainId: CHAIN_A_ID})
  console.log(`[smoke] node A ready at ${anvilA.rpcUrl} (chain ${anvilA.chainId})`)
  anvilB = await startAnvil({chainId: CHAIN_B_ID})
  console.log(`[smoke] node B ready at ${anvilB.rpcUrl} (chain ${anvilB.chainId})`)

  // 3. connect + deploy the fixture on each node
  const A = connectChain(anvilA.rpcUrl, CHAIN_A_ID)
  const B = connectChain(anvilB.rpcUrl, CHAIN_B_ID)
  const fixtureA = await deployFixture(A)
  const fixtureB = await deployFixture(B)
  console.log('[smoke] fixtures deployed on both nodes\n')

  // 4. the flow (fail-fast inside each step)
  await runSameChain(A, fixtureA)
  console.log('')
  await runCrossChain(A, fixtureA, B, fixtureB)
}

main()
  .then(() => {
    console.log('\nSMOKE PASSED')
    teardown()
    process.exit(0)
  })
  .catch((error: unknown) => {
    // numbered-step failures already printed their banner; only surface
    // non-step (setup) failures here
    if (!(error instanceof StepFailure)) {
      console.error('\nSMOKE FAILED:', error instanceof Error ? error.message : error)
    }
    teardown()
    process.exit(1)
  })
