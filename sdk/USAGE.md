# Quip Swap SDK — Usage

Task-oriented guide to integrating the Quip Swap SDK into a dapp or backend. For build/test/repo orientation see [`README.md`](README.md); for protocol theory see the root [`../README.md`](../README.md), [`../ARCHITECTURE.md`](../ARCHITECTURE.md), and [`../QUIP_LIFECYCLE.md`](../QUIP_LIFECYCLE.md).

The SDK is **intended to be non-custodial**: by design it does not hold keys, store secrets, auto-approve tokens, or hide wallet signing. Its SDK-side validation mirrors the contract checks to fail early with actionable errors, but it never replaces on-chain enforcement, and (like any software) it may have bugs — treat it as a convenience layer over the contracts, not a security guarantee.

---

<a id="danger"></a>

## ⚠️ DANGER — ways to lose funds (read before integrating)

The genuine fund-loss paths, loudest first. Each entry is terse — follow the link for depth (full prose lives in [§6 Security & risks](#6-security--risks)). The SDK preflights what it can, but these are the cases it (and the contract) cannot fully prevent for you.

> **⚠️ DANGER — cross-chain taker drain.** A taker who commits before verifying the proposer has actually committed can **permanently lose the escrowed assets** — the proposer holds the secret and can claim the taker's leg while risking nothing. *Avoid:* run `verifyRemoteCommitment` against the proposer's chain, gate your commit on the result, and apply your own confirmation depth. → [§5 callout](#5-cross-chain-swap-end-to-end), [§6 item 1](#6-security--risks).

> **⚠️ DANGER — overriding buffers below the defaults.** Too-tight `minimumBufferSeconds` (same-chain or cross-chain) can cause a **missed claim/reaction window and forfeited funds**; the contract never checks gap SIZE, so the SDK default is the only guard. *Avoid:* keep the default, or override only after evaluating finality, congestion, reorg risk, and relayer latency. → [§5 "Schedule buffers"](#schedule-buffers).

> **⚠️ DANGER — secret loss.** Lose the secret before the claim and the swap **cannot complete** — only `reclaim` after `reclaimRelease` recovers the funds. The SDK never persists it; custody is yours. → [§6 item 2](#6-security--risks).

> **⚠️ DANGER — missed reaction window.** After the secret is revealed, the taker must claim within `[proposer.claimDeadline, proposer.reclaimRelease)` or **forfeit** the swap. *Avoid:* watch the counterparty chain for the reveal rather than polling slowly. → [§6 item 3](#6-security--risks).

> **⚠️ DANGER — reorgs / finality.** A commitment or a revealed secret observed once is **not final** — a reorg can undo it. *Avoid:* honor a confirmation policy before treating any observation as settled. → [§6 item 4](#6-security--risks).

> **⚠️ DANGER — exact `msg.value` / explicit `gas`.** Commit reverts unless `msg.value` is EXACT — let the SDK compute it, never pad it — and passing an explicit `opts.gas` disables the pre-submission revert check. → [§11 Common footguns](#11-common-footguns).

## 1. Install

```bash
bun add @quip.network/quip-swap-sdk@beta viem
# or: npm install @quip.network/quip-swap-sdk@beta viem
```

`viem` (`^2.0.0`) is a **peer dependency** — your app brings its own copy.

> **Prerelease package.** `@quip.network/quip-swap-sdk` is published to npm as a PRERELEASE only (`0.1.0-beta.x`, license AGPL-3.0-or-later) under the `beta` dist-tag — install with `npm install @quip.network/quip-swap-sdk@beta` (a bare install may resolve an older `latest`). There is no stable release yet. See "Not yet available" in [`README.md`](README.md).

## 2. Bring your own clients (and why there is no `.env`)

The SDK takes viem `PublicClient` / `WalletClient` instances **you** construct. It never reads RPC URLs, private keys, or environment variables, and ships no `.env`. This is deliberate:

- **No embedded secrets or endpoints** — credential and transport choices stay in the host app.
- **Same code everywhere** — it works identically in the browser (WalletConnect/injected), in Node, and in backend services; only the transport you pass differs.
- **Address resolution** — **you supply the `Omnibus` address; the SDK does not ship one.** `knownDeployments` is empty, so pass your address as a `{chainId, omnibusAddress}` override to `resolveDeployment(chainId, override)` (or hand it straight to `createOmnibusClient`). With no override the SDK has no address to return and fails fast with `UNKNOWN_DEPLOYMENT`; it never invents, derives, or ships one.

```ts
import {createPublicClient, createWalletClient, custom, http} from 'viem'
import {base} from 'viem/chains'
import {createOmnibusClient, resolveDeployment} from '@quip.network/quip-swap-sdk'

const publicClient = createPublicClient({chain: base, transport: http(RPC_URL)})

// browser:
const walletClient = createWalletClient({chain: base, transport: custom(window.ethereum)})
// backend (local account):
// const walletClient = createWalletClient({chain: base, transport: http(RPC_URL), account})

// the SDK ships no Omnibus address — you pass your own via the override
// (resolveDeployment throws UNKNOWN_DEPLOYMENT if you don't):
const {omnibusAddress} = resolveDeployment(8453n, {chainId: 8453n, omnibusAddress: '0x...'})

const client = createOmnibusClient({address: omnibusAddress, publicClient, walletClient})
```

`createOmnibusClient(args: CreateOmnibusClientArgs): OmnibusClient` — `args` is `{address, publicClient, walletClient?}`. The `walletClient` is optional: reads work without it; writes (`commit`/`claim`/`reclaim`/`admin.*`) throw `MISSING_WALLET_CLIENT` / `MISSING_ACCOUNT` if it (or its account) is absent.

Useful reads on the client (all `Promise`-returning): `getVersion()`, `getCommitmentFee()`, `getMaxFee()`, `getAccruedFees()`, `getOwner()`, `getPendingOwner()`, `getLockState(lock)`, `getTermsHash(lock)`, `getPosted(lock, termsDigest)`, `isVerifierActive(verifier)`, `getWalletFactory()`, `isQuipWallet(account)`, `getCommitDigest(lock, party, counterparty, signerHash)`. Owner-only writes live under `client.admin` (`setCommitmentFee`, `withdrawFees`, `transferOwnership`, `acceptOwnership`, `setVerifierActivity`).

## 3. Core building blocks

### Asset builders

```ts
import {nativeAsset, erc20Asset, erc721Asset, erc1155Asset, validateAsset} from '@quip.network/quip-swap-sdk'

nativeAsset(10n ** 18n)        // function nativeAsset(amount: bigint): Asset    — target = zero addr, id = 0n
erc20Asset(USDC, 1_000_000n)   // function erc20Asset(target, amount): Asset     — id is ALWAYS 0n
erc721Asset(NFT, 42n)          // function erc721Asset(target, tokenId): Asset   — amount canonicalized to 1n
erc1155Asset(ITEMS, 7n, 25n)   // function erc1155Asset(target, tokenId, amount): Asset
```

Every amount must be `> 0n` for **every** asset type (contract rule). ERC-721 `tokenId 0n` is valid; the builder canonicalizes the **amount** to `1n` (see the footgun below). Use `validateAsset(asset): void` on any `Asset` arriving from JSON/APIs/DB — it mirrors `TermsLib.validateAsset` exactly and throws a `QuipSwapError` on bad input.

### Terms and the three lifecycle timestamps

Each side of a swap is a `Terms` built with `createTerms(args: CreateTermsArgs): Terms`:

```ts
import {createTerms} from '@quip.network/quip-swap-sdk'

const aliceTerms = createTerms({
  chainId: 8453n,            // chain where THIS side's assets are escrowed
  reclaimRecipient: alice,   // receives this side's own assets back on reclaim
  recipient: alice,          // receives the COUNTERPARTY's assets on claim
  commitmentDeadline: now + 600n,
  claimDeadline: now + 1800n,
  reclaimRelease: now + 3600n,
  assets: [nativeAsset(10n ** 18n)],
})
```

The two sides' six timestamps must **strictly interleave** (enforced by `validateTermPairing(a, b)` and on-chain):

```text
proposer.commitmentDeadline < taker.commitmentDeadline
  < proposer.claimDeadline   < taker.claimDeadline
  < proposer.reclaimRelease  < taker.reclaimRelease
```

The **proposer** is the side with the smaller `commitmentDeadline`; it commits first. `proposedBy(party, counterparty)` returns `'party' | 'counterparty'`. Structural validation deliberately does **not** check that deadlines are in the future (see footgun).

### Secret generation — and the rule that the SDK never stores it

```ts
import {generateSecret} from '@quip.network/quip-swap-sdk'

const {secret, lock} = generateSecret() // generateSecret(): SecretLockPair = {secret, lock}
```

- `generateSecret()` uses a CSPRNG (`crypto.getRandomValues`) and returns `{secret, lock}` where `lock === keccak256(secret)`.
- The **lock** is public — it's published on-chain. The **secret** must stay private until the holder claims.
- **The SDK never persists or logs the secret.** Keeping it safe (and available at claim time) is entirely the application's responsibility. Lose it and the assets are only recoverable via reclaim after `reclaimRelease`.

## 4. Same-chain swap (end-to-end)

```ts
import {planSameChainSwap, getSameChainSwapStatus, generateSecret, buildKeyedSigner} from '@quip.network/quip-swap-sdk'

const plan = planSameChainSwap(aliceTerms, bobTerms) // validates (structure, order, chain, BUFFERS) + normalizes roles
const {secret, lock} = generateSecret()              // the PROPOSER holds the secret

// each side's identity is an ERC-7913 keyed signer: verifier(20 bytes) ‖ key.
// The signature envelope over computeCommitDigest(...) comes from the
// keyholder's own tooling — the SDK never signs.
const proposerSigner = buildKeyedSigner(verifierAddress, proposerKey)
const takerSigner = buildKeyedSigner(verifierAddress, takerKey)

// 1. proposer commits in [0, proposer.commitmentDeadline)          lock: Unused -> Free
await proposerClient.commit({
  lock, party: plan.proposerTerms, counterparty: plan.takerTerms,
  auth: {signer: proposerSigner, signature: proposerEnvelope},
})

// 2. WAIT — the taker's window only opens at proposer.commitmentDeadline

// 3. taker commits (posts the OTHER side)                          lock: Free -> Committed
await takerClient.commit({
  lock, party: plan.takerTerms, counterparty: plan.proposerTerms,
  auth: {signer: takerSigner, signature: takerEnvelope},
})

// 4. anyone with the secret claims in the proposer-claim window    lock: Committed -> Spent
await anyClient.claim({secret, party: plan.proposerTerms, counterparty: plan.takerTerms})
```

`commit(args: CommitArgs, opts?)`, `claim(args: ClaimArgs, opts?)`, and `reclaim(args: ReclaimArgs, opts?)` each return a `Promise<Hash>`. `CommitArgs` is `{lock, party, counterparty, auth, verifyOnChainState?}`; `ReclaimArgs` is `{lock, party, counterparty, verifyOnChainState?}`; `ClaimArgs` is `{secret, party, counterparty, verifyOnChainState?}` (the lock is derived from the secret).

### Commit authorization (`auth`) and the funding model

`commit` is **permissionless** — the contract authenticates the PAYLOAD, not the caller. Every commit carries a `CommitAuth {signer, signature}`; the `signer` is always an ERC-7913 keyed identity blob (`buildKeyedSigner(verifierAddress, key)`; blobs of 20 bytes or fewer, including bare addresses, revert `MalformedSigner`). The `signature` discriminates two routes:

- **Non-empty — KEYED route**: the declared verifier must be active on the contract (`isVerifierActive`). The identity signs `computeCommitDigest({lock, party, counterparty, signer, omnibusAddress})`; the `signature` is the verifier-defined envelope, produced by the keyholder's own tooling — **the SDK never signs and never decodes envelopes**.
- **Empty (`'0x'`) — WALLET route**: the transaction **sender** must be a wallet deployed by the quip `WalletFactory` (the contract checks `vaultIdOf(msg.sender) != 0` on its baked-in factory and reverts `NotQuipWallet` otherwise). No signature is verified; the wallet's own PQ-authenticated execute flow is the authorization. The client preflights this membership read and throws `NOT_QUIP_WALLET` before a transaction exists; `isQuipWallet(account)` exposes the same check directly.

The keyed signature is a **soft guard**: it proves the declared identity endorsed exactly this payload (lock + both terms + chain + contract + identity), so a relayer cannot tamper with terms in flight. It does NOT gate which identity may post a side — a client that requires the counterparty's agreed identity checks the `signer` field of the `Commitment` event off-chain before revealing the secret / committing the second leg.

> **⚠️ WALLET-ROUTE ATTRIBUTION IS UNPROVEN — do not trust it with funds.** On the wallet route even the soft guard is absent: the contract emits whatever `signer` blob the wallet supplied **without verifying it endorsed anything**. A quip wallet can post any identity blob it likes. If your flow gates on "the counterparty's agreed identity posted its side" (e.g. before revealing the secret or committing the second leg), a `Commitment` whose commit came in with an empty signature does NOT prove that identity agreed — treating it as proof lets a wallet-route commit impersonate your counterparty's identity and bait your leg. Either require your counterparty to use the keyed route, or independently verify the SENDER (`Commitment.sender`) is the counterparty's known wallet address before acting.

> **FUNDING MODEL — read this twice.** The transaction **SENDER funds the committed leg + fee**: assets are pulled from `msg.sender` and `msg.value` must equal `totalNative(party) + commitmentFee`. The identity in `auth.signer` only *authorizes*. "Relayed" therefore means "the sender pays the party's leg" — a relayer submitting someone else's signed commit is donating the escrow unless it is compensated out-of-band.

(`claim`/`reclaim` are unchanged and identity-free.)

Same-chain, the contract enforces the *window* ordering — the taker cannot commit until the proposer's commitment deadline has passed — but it does **not** verify the proposer actually committed. A taker who commits first (during the taker window, on an `Unused` lock) simply posts their own side, moving the lock `Unused → Free`; the swap can then never complete (the proposer's window has closed) and the taker's assets are stranded until their `reclaimRelease` (reclaim-from-Free). This is an economically irrational action that strands the taker's assets until reclaim, rather than a theft vector — no one can take the taker's funds — so the same-chain risk is materially lower than the cross-chain drain, but it is not zero. The genuinely dangerous, integrator-owned case is cross-chain: see the **⚠️ CRITICAL** callout in §5.

`planSameChainSwap` is the validation entry point — and it is the **only** place a dangerously tight schedule is caught, because the contract checks interleaving ORDER but never gap SIZE. It validates structure, order, chain, **and** buffer sizes (defaulting to `DEFAULT_SAME_CHAIN_BUFFER_SECONDS`, overrideable via `planSameChainSwap(a, b, {minimumBufferSeconds})`). Nothing forces it, so **both parties should run it on their own terms** before acting; skipping it means committing with unvalidated windows. See the "Schedule buffers" note at the end of §5.

**Driving / observing the flow** with `getSameChainSwapStatus(client, lock, plan): Promise<SameChainSwapStatusReport>`:

```ts
const {status, lockState, proposerPosted, takerPosted, timestamp} =
  await getSameChainSwapStatus(client, lock, plan)
```

`status` is one of eleven values: `'awaiting-proposer-commit'`, `'proposer-commit-expired'`, `'awaiting-taker-window'`, `'awaiting-taker-commit'`, `'half-committed-expired'`, `'awaiting-claim-window'`, `'claimable'`, `'late-claimable'`, `'reclaimable'`, `'reclaimable-from-free'`, `'settled'`.

> `getSameChainSwapStatus` is a **convenience for coordination/UX**. It reads `lockState` and both `posted` flags but does **not** itself compare the on-chain `termsHash` to your plan — treat its conclusions as advisory and let the client preflights (which do check `termsHash`) be the enforcement point. See "Audience notes".

### Claim and reclaim semantics

- **`claim` is permissionless** — anyone holding the secret may call it, and the transaction makes the secret public. **One same-chain claim settles BOTH legs**: the counterparty's assets go to `party.recipient` and the party's assets go to `counterparty.recipient` in the same transaction.
- **`reclaim` is permissionless** and pays the terms' `reclaimRecipient` regardless of caller; gated only by the local leg's `reclaimRelease` (window `[release, ∞)`).
- **Dual-leg reclaim:** when the counterparty leg is local and the lock is `Committed`, one reclaim returns BOTH legs and emits **two** `Reclaimed` events.
- **Reclaim-from-Free:** if only the proposer committed (lock `Free`), reclaim is valid after the proposer's release (`Free -> Spent`).

## 5. Cross-chain swap (end-to-end)

A cross-chain swap is a **coordinated flow across two independent chains — not one atomic transaction.** Alice is proposer/secret-holder on Chain A; Bob is taker on Chain B.

> **⚠️ Danger:** as the taker, verify the proposer actually committed (`verifyRemoteCommitment` against the proposer's chain) *before* you commit, gate your commit on it, and apply your own confirmation depth — skipping this can **permanently lose your escrowed assets**, and the contract cannot prevent it cross-chain. The single most likely way to lose funds with this SDK; full detail in [DANGER](#danger) and [§6](#6-security--risks).

```ts
import {validateCrossChainSchedule, verifyRemoteCommitment, extractSecretFromClaims}
  from '@quip.network/quip-swap-sdk'

// 0. validate roles + buffer BEFORE any transaction
validateCrossChainSchedule({
  proposerTerms: aliceTermsOnA,   // the SECRET HOLDER's leg — MUST be the proposer
  takerTerms: bobTermsOnB,
  // minimumBufferSeconds optional → DEFAULT_CROSS_CHAIN_BUFFER_SECONDS; pass an
  // explicit margin for your chains, e.g. DEFAULT_BUFFERS.conservativeL1
}) // returns CrossChainSchedule {proposerTerms, takerTerms, reactionBufferSeconds, minimumGapSeconds}

// keyed ERC-7913 identities (see §4):
//   aliceAuth/bobAuth = {signer: buildKeyedSigner(verifier, key), signature: <envelope>}

// 1. Alice commits on Chain A                         (Unused -> Committed; no Free state cross-chain)
//    confirm with the Chain A client — it scopes decoding to Chain A's Omnibus
await aliceClientA.waitForReceipt(
  await aliceClientA.commit({lock, party: aliceTermsOnA, counterparty: bobTermsOnB, auth: aliceAuth}),
)

// 2. ← REQUIRED: skipping this can drain the taker's assets.
//    Verify Alice's commitment ON ALICE'S CHAIN (aliceClientA is bound to Chain A)
//    before Bob commits. `committed` already folds in posted + termsHash match.
const status = await verifyRemoteCommitment(aliceClientA, lock, aliceTermsOnA, bobTermsOnB)
if (!status.committed) throw new Error('proposer has not committed — do NOT commit the taker leg')
// result is point-in-time: re-check at your own confirmation depth (a reorg can
// undo a young commit) before treating it as final.

// 3. Bob commits on Chain B in [alice.commitmentDeadline, bob.commitmentDeadline)
await bobClientB.waitForReceipt(
  await bobClientB.commit({lock, party: bobTermsOnB, counterparty: aliceTermsOnA, auth: bobAuth}),
)

// 4. Alice claims Bob's leg ON CHAIN B — the Claim event REVEALS the secret.
//    waitForReceipt on the Chain B client scopes decoding to Chain B's Omnibus.
const claimB = await aliceClientB.waitForReceipt(
  await aliceClientB.claim({secret, party: aliceTermsOnA, counterparty: bobTermsOnB}),
)

// 5. Bob (or a relayer) extracts the secret from the address-SCOPED decoded claims
//    (NOT from raw receipt.logs):
const revealed = extractSecretFromClaims(claimB.claims, lock) // Hex32 | undefined

// 6. Bob claims Alice's leg ON CHAIN A in [alice.claimDeadline, alice.reclaimRelease)
if (revealed) {
  await bobClientA.waitForReceipt(
    await bobClientA.claim({secret: revealed, party: bobTermsOnB, counterparty: aliceTermsOnA}),
  )
}
```

- **`validateCrossChainSchedule({proposerTerms, takerTerms, minimumBufferSeconds})`** enforces strict interleaving, that the secret-holder is the proposer, and a minimum gap between **every** adjacent pair of the six schedule timestamps. `minimumBufferSeconds` is mandatory and has **no default** — choose it from chain finality/reorg risk, RPC reliability, relayer responsiveness, and your safety margin. A buffer fine on a fast-finality L2 may be reckless on a congested L1.
- **`verifyRemoteCommitment(remoteClient, lock, proposerTerms, takerTerms)`** is the **mandatory off-chain check** Chain B cannot do for you (it cannot read Chain A). Returns `{committed, lockState, proposerPosted, termsHashMatches}`. A taker that skips it risks escrowing against a proposer who never committed. **Do not treat a `Commitment` event alone as proof that Bob may commit; taker readiness must come from `verifyRemoteCommitment`'s storage checks** (`lockState`, `posted`, `termsHash`) — an event can be reorged away or emitted by an impostor contract, whereas the storage reads reflect committed chain state.
- **This is NOT atomic.** The buffer is the taker's reaction window between the latest possible secret reveal and the close of their claim window (`proposer.reclaimRelease - proposer.claimDeadline`). If either side stalls past their windows, each side reclaims its own leg.

### Schedule buffers

A swap's six timestamps must satisfy two separate things: **ORDER** (strict interleaving — the contract enforces this on every commit) and **SIZE** (enough wall-clock time between adjacent stages — the contract does **not** check this; the SDK is the only place it's caught). Buffers are the SIZE check: they protect the action/reaction windows against chain finality, reorgs, RPC outages, congestion, and relayer latency.

Both validators apply a minimum-gap check across every adjacent pair: `planSameChainSwap(a, b, {minimumBufferSeconds?})` (default `DEFAULT_SAME_CHAIN_BUFFER_SECONDS`) and `validateCrossChainSchedule({..., minimumBufferSeconds?})` (default `DEFAULT_CROSS_CHAIN_BUFFER_SECONDS`). `checkScheduleBuffers(proposer, taker, min)` is exported if you want the check standalone.

Pick a value for **your** chains from the presets (starting points, not authoritative — tune them):

```ts
import {DEFAULT_BUFFERS} from '@quip.network/quip-swap-sdk'
// DEFAULT_BUFFERS = { fastL2: 300n, standard: 1800n, conservativeL1: 3600n }
validateCrossChainSchedule({proposerTerms, takerTerms, minimumBufferSeconds: DEFAULT_BUFFERS.conservativeL1})
```

- `fastL2` (~5 min) — fast-finality L2s with low reorg risk.
- `standard` (~30 min) — the general default both modes use when you omit the arg.
- `conservativeL1` (~1 hr) — congested or deep-reorg-risk L1s.

Overriding **below** these defaults can forfeit windows and lose funds — see [DANGER](#danger).

## 6. Security & risks

> The loud, scannable summary is the [DANGER](#danger) section at the top of this file; the entries below are the detailed prose it links to.

The real failure modes, in order of severity. Read them deliberately before integrating.

1. **Cross-chain taker drain (integrator's responsibility).** The loudest item. In a cross-chain swap the taker must verify the proposer actually committed — via `verifyRemoteCommitment` against the proposer's chain — *before* committing its own leg. If the taker skips this and the proposer never committed, the proposer holds the secret and can claim the taker's leg while risking nothing; the taker loses its funds. Same-chain the contract enforces only the *window* ordering (the taker cannot commit before the proposer's deadline) — it does not verify the proposer committed — but a same-chain taker-first commit merely **strands** the taker's funds (reclaim-from-Free), it does not let anyone take them; cross-chain there is no such floor, and the loss is real. See the ⚠️ CRITICAL callout in §5. This is the single most likely way to lose funds with this SDK.

2. **Secret loss (integrator's responsibility).** The proposer generates and holds the secret; the SDK never persists or logs it. If the secret is lost before the claim, the swap cannot be completed — the only recovery is `reclaim`, available after `reclaimRelease`, which returns each leg to its `reclaimRecipient`. Custody of the secret until claim is the application's job.

3. **Missed reaction window (integrator's responsibility).** Once the proposer's claim reveals the secret on one chain, the taker must claim the other leg within `[proposer.claimDeadline, proposer.reclaimRelease)`. Miss that window and the taker forfeits the swap (the proposer can reclaim). Watch the counterparty chain for the `Claim` event rather than polling on a slow interval, and size `minimumBufferSeconds` for your finality/relay latency.

4. **Reorgs / finality (integrator's responsibility).** A commitment or a revealed secret observed once is not final — a reorg can undo a young commit, and `verifyRemoteCommitment` is point-in-time. Honor a confirmation policy (re-check after N blocks) before treating any observation as settled.

SDK-guarded conditions (terms/pairing/window/chain-id/signer-blob-shape/lock-state, exact `msg.value`, address/secret validation) are preflighted and surface as typed `QuipSwapError`s; the four items above are NOT things the SDK or the contract can fully prevent for you cross-chain.

## 7. Reading results & events

There are **three tiers** for turning a transaction into typed events, ordered by how much address scoping they do for you. Receipt decoding only counts events emitted by the Omnibus address you scope to, so a same-signature event from another contract in the same transaction is never mistaken for a genuine one.

**1. Preferred — `client.waitForReceipt(hash, options?)`.** Uses the client's bound Omnibus address automatically; you never pass it again. Best for any tx you submitted through an `OmnibusClient`.

```ts
const hash = await client.commit({lock, party, counterparty, auth})
const {commitments, claims, reclaims} = await client.waitForReceipt(hash, {confirmations: 3})
```

**2. Standalone — `waitForOmnibusReceipt(publicClient, hash, options?)`.** Pass the Omnibus address explicitly to scope decoding; omitting it keeps the legacy raw behavior (decodes every matching log) and is **not** recommended for security-sensitive flows.

```ts
const {claims} = await waitForOmnibusReceipt(publicClient, hash, {address: omnibusAddress, confirmations: 3})
```

Both throw **`TRANSACTION_REVERTED`** if the tx mined but reverted, and return `OmnibusReceipt = {transactionHash, receipt, commitments, claims, reclaims}`:
- `CommitmentEvent` → `{lock, party, signer, sender, blockNumber, transactionHash, logIndex}` — `signer` is the identity blob that endorsed the commit (check it off-chain if you require a specific counterparty identity); `sender` is the address that submitted and funded it
- `ClaimEvent` → `{recipient, lock, secret, blockNumber, transactionHash, logIndex}`
- `ReclaimedEvent` → `{caller, lock, recipient, blockNumber, transactionHash, logIndex}`

Pull a revealed secret from the **scoped** decoded claims with `extractSecretFromClaims(receipt.claims, lock): Hex32 | undefined` (it also verifies the secret hashes back to the lock, so a fake `Claim(lock, wrongSecret)` is ignored).

**3. Low-level raw — `decodeCommitmentEvents(logs)` / `decodeClaimEvents(logs)` / `decodeReclaimedEvents(logs)` / `extractRevealedSecret(logs, lock)`.** These decode by event signature only and do **not** verify `log.address` — use them only on logs you have ALREADY scoped to the correct Omnibus address.

For **historical queries** use the address-scoped helpers — `getCommitmentEvents(args)`, `getClaimEvents(args)`, `getReclaimedEvents(args)`, and the live subscription `watchClaimEvents({...args, onClaim})` — where `args: EventQueryArgs = {publicClient, address, lock?, fromBlock?, toBlock?}`. These already require and filter by the `Omnibus` `address`.

**Cross-chain:** there is no single cross-chain Omnibus address — use the client for the chain where the transaction was mined. Chain A receipts go through the Chain A client (Omnibus A); Chain B receipts through the Chain B client (Omnibus B).

## 8. Error handling

Every SDK error is a `QuipSwapError` with a stable `code` (`QuipSwapErrorCode`); on-chain reverts also carry the decoded Solidity error name in `contractErrorName`, and the original viem error is always preserved in `cause`.

```ts
import {QuipSwapError} from '@quip.network/quip-swap-sdk'

try {
  await client.commit({lock, party, counterparty, auth})
} catch (err) {
  if (err instanceof QuipSwapError) {
    switch (err.code) {
      case 'WINDOW_VIOLATED':       /* outside the timing window */ break
      case 'INVALID_LOCK_STATE':    /* lock not in the required state */ break
      case 'TERMS_ALREADY_POSTED':  /* this side already committed */ break
      case 'BALANCE_TOO_LOW':       /* {required, balance} in err.details */ break
      case 'CONTRACT_REVERT':       /* err.contractErrorName, e.g. 'IncorrectNativeAmountReceived' */ break
      default: /* MISSING_WALLET_CLIENT, CHAIN_ID_MISMATCH, GAS_ESTIMATION_FAILED, ... */ break
    }
    err.contractErrorName // Solidity error name when the RPC returns revert data (best-effort)
    err.cause             // original viem error, always preserved
  }
}
```

Any contract revert reaching the SDK is decoded generically as `code: 'CONTRACT_REVERT'` with `contractErrorName` set to the Solidity error (e.g. `WindowViolated`, `TermsMismatch`, `IncorrectNativeAmountReceived`, `InvalidCommitSignature`, `VerifierNotActive`, `NotQuipWallet`). **Caveat:** `contractErrorName` is only populated when the RPC returns revert data — a provider that strips it yields `code: 'GAS_ESTIMATION_FAILED'` with no name. Branch on `code` first; treat `contractErrorName` as best-effort detail.

## 9. What the SDK does NOT do

This is the application's job, not the library's:

- **Secret storage / lifecycle** — generation is provided; persistence, secure handling, and availability at claim time are yours.
- **Counterparty discovery & terms negotiation** — agreeing on assets and the interleaved schedule happens out of band.
- **Wallet / key management & signing UX** — you pass a viem `WalletClient`; the SDK never holds keys.
- **Bridging / cross-chain messaging / relaying** — cross-chain settlement is a coordinated flow you (or a relayer) drive; the SDK provides validation and the off-chain commitment check, not transport.

## 10. Audience notes

- **External integrators:** the **workflow helpers** (`planSameChainSwap`, `getSameChainSwapStatus`, `validateCrossChainSchedule`, `verifyRemoteCommitment`) are the supported high-level entry points. Prefer them over hand-rolling client calls.
- **Teams calling the client directly:** `getSameChainSwapStatus` is a convenience whose conclusions should be **cross-checked against the client preflights** — the client (and ultimately the contract) is the enforcement point. The status helper reads state for display/coordination; it is not an authorization.

## 11. Common footguns

Each entry is *pitfall → why → do this instead*. These describe the SDK and protocol **as they behave today** — they are usage guidance, not bugs to fix.

- **`msg.value` must be EXACT.** Commit requires `msg.value == totalNative(party) + commitmentFee` exactly; the contract reverts `IncorrectNativeAmountReceived` on both over- and under-payment. Never pad the native value the way you pad gas. **Do:** let the SDK compute and send the value; never add a buffer to it. (Fund-affecting — see [DANGER](#danger).)

- **The commitment fee can change between read and submit.** It is owner-mutable. The SDK re-reads it immediately before building the commit tx, but a fee change in that gap can still cause `IncorrectNativeAmountReceived`. **Do:** surface a retry path on that revert rather than treating it as fatal.

- **Deadlines must strictly interleave; there is NO freshness check.** The SDK validates ordering, not that deadlines are in the future — the taker legitimately commits after the proposer's deadline has elapsed. **Do:** build the schedule from the chain's current `block.timestamp` with comfortable gaps; reusing past timestamps or too-tight gaps is on you.

- **The taker cannot commit until the proposer's commitment deadline passes.** The taker's commit window is `[proposer.commitmentDeadline, taker.commitmentDeadline)`; an early taker commit reverts/preflights `WindowViolated`. This surprises people expecting back-to-back commits. **Do:** gate the taker commit on reaching `proposer.commitmentDeadline` (poll `getSameChainSwapStatus` for `awaiting-taker-commit`).

- **The secret holder must be the proposer (cross-chain).** Assign the secret to the taker and `validateCrossChainSchedule` rejects it. **Why:** a secret-holding taker could claim the counterparty leg while letting their own leg expire — the cross-chain "free option." **Do:** make the secret holder the side with the earlier `commitmentDeadline`.

- **The secret becomes PUBLIC the moment the proposer claims.** The reveal claim emits the secret in the `Claim` event. **Do:** treat it as public immediately after; the taker's reaction buffer exists precisely so they can use the revealed secret before their own window closes.

- **Reclaim is permissionless; recipients are fixed.** Anyone can submit `claim`/`reclaim`; funds always go to the `recipient` / `reclaimRecipient` encoded in the terms — submitting does **not** redirect funds to the caller. **Do:** not assume "only I can claim/reclaim" or that being the sender pays you.

- **One same-chain claim settles BOTH legs.** Do not call `claim` twice for a same-chain swap — the second reverts `InvalidLockState` (the lock is already `Spent`). **Do:** treat the first successful claim as final settlement of the whole swap.

- **A tx hash is not success.** A mined transaction can still have reverted. **Do:** always resolve the receipt and check status — `waitForOmnibusReceipt` throws `TRANSACTION_REVERTED` for you — before treating a step as done.

- **Setting an explicit `gas` disables the revert check.** Passing `opts.gas` skips gas estimation — which is also the SDK's pre-submission revert check — so a call that would revert is signed and broadcast anyway and burns its gas (the protocol preflights still run). **Do:** leave `gas` unset so estimation catches reverts first; if you only want a bigger buffer use `gasMultiplier`; pass an explicit `gas` only for a call you have already confirmed will succeed. (Fund-affecting — see [DANGER](#danger).)

- **ERC-721 amount is canonicalized to `1n` by the builder.** If you hand-build an ERC-721 `Asset` with a different `amount`, both sides must use the identical value or the digests diverge and the swap won't match (`TermsMismatch`). **Do:** always use `erc721Asset(target, tokenId)`.

- **ERC-20 `id` must be `0`.** A non-zero `id` on an ERC-20 asset is rejected (`InvalidERC20Asset` / SDK `INVALID_ERC20_ASSET`). **Do:** use `erc20Asset(target, amount)`, which sets `id` to `0n`.

- **USDT-style approvals.** Some non-standard ERC-20s revert on `approve` when the current allowance is non-zero. **Do:** reset the allowance to `0` first, then approve the required amount (or use `submitApproval` with an `erc20Mode` and handle the reset in your flow).

- **Receipt logs are multi-contract.** A claim/reclaim receipt contains logs from every token moved, not just `Omnibus`. The raw `decode*Events(logs)` / `extractRevealedSecret(logs, lock)` helpers match by event signature only and do **not** filter by emitter, so a same-signature event from another contract in the same transaction would be decoded as if it were `Omnibus`'s. **Do:** confirm with `client.waitForReceipt(hash)` (or `waitForOmnibusReceipt(publicClient, hash, {address})`), which decode only logs from the Omnibus address; extract secrets from the scoped `receipt.claims` via `extractSecretFromClaims`. Reserve the raw `decode*`/`extractRevealedSecret` helpers for logs you have already scoped to the `Omnibus` address. For historical reads the address-scoped `getCommitmentEvents` / `getClaimEvents` / `getReclaimedEvents` already require an `address`.

- **Reorgs.** Events and receipts observed once are not final, and `Reclaimed` legitimately appears twice in a dual-leg reclaim. **Do:** honour your confirmation/finality policy — pass `{confirmations}` to `waitForOmnibusReceipt` and don't treat a single observation as settled.
