# Quip Swap SDK — Usage

Task-oriented guide to integrating the Quip Swap SDK into a dapp or backend. For build/test/repo orientation see [`README.md`](README.md); for protocol theory see the root [`../README.md`](../README.md), [`../ARCHITECTURE.md`](../ARCHITECTURE.md), and [`../QUIP_LIFECYCLE.md`](../QUIP_LIFECYCLE.md).

The SDK is **intended to be non-custodial**: by design it does not hold keys, store secrets, auto-approve tokens, or hide wallet signing. Its SDK-side validation mirrors the contract checks to fail early with actionable errors, but it never replaces on-chain enforcement, and (like any software) it may have bugs — treat it as a convenience layer over the contracts, not a security guarantee.

---

## 1. Install

```bash
bun add @quip.network/quip-swap-sdk viem
# or: npm install @quip.network/quip-swap-sdk viem
```

`viem` (`^2.0.0`) is a **peer dependency** — your app brings its own copy.

> **Placeholder package name.** `@quip.network/quip-swap-sdk` is the package's declared name (`package.json`), but it is **not yet published to a registry** (version `0.1.0`, `UNLICENSED`). Until it is, consume it from within this repo (`sdk/`, built with `bun run build`) or via your own workspace/link setup. See "Not yet available" in [`README.md`](README.md).

## 2. Bring your own clients (and why there is no `.env`)

The SDK takes viem `PublicClient` / `WalletClient` instances **you** construct. It never reads RPC URLs, private keys, or environment variables, and ships no `.env`. This is deliberate:

- **No embedded secrets or endpoints** — credential and transport choices stay in the host app.
- **Same code everywhere** — it works identically in the browser (WalletConnect/injected), in Node, and in backend services; only the transport you pass differs.
- **No baked-in addresses** — the deployment registry is intentionally empty (`knownDeployments` is an empty `Map`), so you supply the `Omnibus` address per chain. The SDK never invents addresses.

```ts
import {createPublicClient, createWalletClient, custom, http} from 'viem'
import {base} from 'viem/chains'
import {createOmnibusClient, resolveDeployment} from '@quip.network/quip-swap-sdk'

const publicClient = createPublicClient({chain: base, transport: http(RPC_URL)})

// browser:
const walletClient = createWalletClient({chain: base, transport: custom(window.ethereum)})
// backend (local account):
// const walletClient = createWalletClient({chain: base, transport: http(RPC_URL), account})

// the registry is empty by design — pass your verified address as the override:
const {omnibusAddress} = resolveDeployment(8453n, {chainId: 8453n, omnibusAddress: '0x...'})

const client = createOmnibusClient({address: omnibusAddress, publicClient, walletClient})
```

`createOmnibusClient(args: CreateOmnibusClientArgs): OmnibusClient` — `args` is `{address, publicClient, walletClient?}`. The `walletClient` is optional: reads work without it; writes (`commit`/`claim`/`reclaim`/`admin.*`) throw `MISSING_WALLET_CLIENT` / `MISSING_ACCOUNT` if it (or its account) is absent.

Useful reads on the client (all `Promise`-returning): `getVersion()`, `getCommitmentFee()`, `getMaxFee()`, `getAccruedFees()`, `getQuipFactory()`, `getOwner()`, `getPendingOwner()`, `getLockState(lock)`, `getTermsHash(lock)`, `getPosted(lock, termsDigest)`, `isQuipWallet(account)`. Owner-only writes live under `client.admin` (`setCommitmentFee`, `withdrawFees`, `transferOwnership`, `acceptOwnership`).

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
import {planSameChainSwap, getSameChainSwapStatus, generateSecret} from '@quip.network/quip-swap-sdk'

const plan = planSameChainSwap(aliceTerms, bobTerms) // validates + normalizes roles (returns SameChainSwapPlan)
const {secret, lock} = generateSecret()              // the PROPOSER holds the secret

// 1. proposer commits in [0, proposer.commitmentDeadline)          lock: Unused -> Free
await proposerClient.commit({lock, party: plan.proposerTerms, counterparty: plan.takerTerms})

// 2. WAIT — the taker's window only opens at proposer.commitmentDeadline

// 3. taker commits (posts the OTHER side)                          lock: Free -> Committed
await takerClient.commit({lock, party: plan.takerTerms, counterparty: plan.proposerTerms})

// 4. anyone with the secret claims in the proposer-claim window    lock: Committed -> Spent
await anyClient.claim({secret, party: plan.proposerTerms, counterparty: plan.takerTerms})
```

`commit(args: CommitArgs, opts?)`, `claim(args: ClaimArgs, opts?)`, and `reclaim(args: ReclaimArgs, opts?)` each return a `Promise<Hash>`. `CommitArgs`/`ReclaimArgs` are `{lock, party, counterparty, verifyOnChainState?}`; `ClaimArgs` is `{secret, party, counterparty, verifyOnChainState?}` (the lock is derived from the secret).

`commit` is **QuipWallet-gated**: only factory-deployed QuipWallets may commit (`Omnibus.commit` is `onlyQuipWallet`). The client preflights this via `vaultIdOf` and rejects a non-wallet sender with `NOT_QUIP_WALLET` before any transaction — the committer must be the QuipWallet **contract** address, not its owner's EOA. (`claim`/`reclaim` are ungated.) You can check eligibility up front with `await client.isQuipWallet(account)`.

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

```ts
import {validateCrossChainSchedule, verifyRemoteCommitment, extractRevealedSecret,
        waitForOmnibusReceipt} from '@quip.network/quip-swap-sdk'

// 0. validate roles + buffer BEFORE any transaction
validateCrossChainSchedule({
  proposerTerms: aliceTermsOnA,   // the SECRET HOLDER's leg — MUST be the proposer
  takerTerms: bobTermsOnB,
  minimumBufferSeconds: 1800n,    // REQUIRED — there is no safe default
}) // returns CrossChainSchedule {proposerTerms, takerTerms, reactionBufferSeconds, minimumGapSeconds}

// 1. Alice commits on Chain A                         (Unused -> Committed; no Free state cross-chain)
await aliceClientA.commit({lock, party: aliceTermsOnA, counterparty: bobTermsOnB})

// 2. Bob MUST verify Alice's remote commitment off-chain before committing:
const status = await verifyRemoteCommitment(aliceClientA, lock, aliceTermsOnA, bobTermsOnB)
if (!(status.committed && status.proposerPosted && status.termsHashMatches)) throw new Error('do not commit')

// 3. Bob commits on Chain B in [alice.commitmentDeadline, bob.commitmentDeadline)
await bobClientB.commit({lock, party: bobTermsOnB, counterparty: aliceTermsOnA})

// 4. Alice claims Bob's leg ON CHAIN B — the Claim event REVEALS the secret
const aliceClaimHash = await aliceClientB.claim({secret, party: aliceTermsOnA, counterparty: bobTermsOnB})

// 5. Bob (or a relayer) extracts the revealed secret from the Chain B receipt:
const {receipt} = await waitForOmnibusReceipt(bobPublicClientB, aliceClaimHash)
const revealed = extractRevealedSecret(receipt.logs, lock) // Hex32 | undefined

// 6. Bob claims Alice's leg ON CHAIN A in [alice.claimDeadline, alice.reclaimRelease)
if (revealed) await bobClientA.claim({secret: revealed, party: bobTermsOnB, counterparty: aliceTermsOnA})
```

- **`validateCrossChainSchedule({proposerTerms, takerTerms, minimumBufferSeconds})`** enforces strict interleaving, that the secret-holder is the proposer, and a minimum gap between **every** adjacent pair of the six schedule timestamps. `minimumBufferSeconds` is mandatory and has **no default** — choose it from chain finality/reorg risk, RPC reliability, relayer responsiveness, and your safety margin. A buffer fine on a fast-finality L2 may be reckless on a congested L1.
- **`verifyRemoteCommitment(remoteClient, lock, proposerTerms, takerTerms)`** is the **mandatory off-chain check** Chain B cannot do for you (it cannot read Chain A). Returns `{committed, lockState, proposerPosted, termsHashMatches}`. A taker that skips it risks escrowing against a proposer who never committed.
- **This is NOT atomic.** The buffer is the taker's reaction window between the latest possible secret reveal and the close of their claim window (`proposer.reclaimRelease - proposer.claimDeadline`). If either side stalls past their windows, each side reclaims its own leg.

## 6. Reading results & events

`waitForOmnibusReceipt(publicClient, hash, options?: {confirmations?, timeout?}): Promise<OmnibusReceipt>` waits for the receipt, **throws `TRANSACTION_REVERTED` if the tx mined but reverted**, and decodes events. `OmnibusReceipt` is `{transactionHash, receipt, commitments, claims, reclaims}`.

```ts
const {commitments, claims, reclaims} = await waitForOmnibusReceipt(publicClient, hash, {confirmations: 3})
```

- `CommitmentEvent` → `{lock, party, committer, blockNumber, transactionHash, logIndex}`
- `ClaimEvent` → `{recipient, lock, secret, blockNumber, transactionHash, logIndex}`
- `ReclaimedEvent` → `{caller, lock, recipient, blockNumber, transactionHash, logIndex}`

Decode directly from a logs array with `decodeCommitmentEvents(logs)`, `decodeClaimEvents(logs)`, `decodeReclaimedEvents(logs)`, or pull the revealed secret for a lock with `extractRevealedSecret(logs, lock): Hex32 | undefined`.

For **historical queries** use the address-scoped helpers — `getCommitmentEvents(args)`, `getClaimEvents(args)`, `getReclaimedEvents(args)`, and the live subscription `watchClaimEvents({...args, onClaim})` — where `args: EventQueryArgs = {publicClient, address, lock?, fromBlock?, toBlock?}`. These filter by the `Omnibus` `address`; the raw `decode*` helpers do not (see the receipt-logs footgun).

## 7. Error handling

Every SDK error is a `QuipSwapError` with a stable `code` (`QuipSwapErrorCode`); on-chain reverts also carry the decoded Solidity error name in `contractErrorName`, and the original viem error is always preserved in `cause`.

```ts
import {QuipSwapError} from '@quip.network/quip-swap-sdk'

try {
  await client.commit({lock, party, counterparty})
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

Any contract revert reaching the SDK is decoded generically as `code: 'CONTRACT_REVERT'` with `contractErrorName` set to the Solidity error (e.g. `WindowViolated`, `TermsMismatch`, `IncorrectNativeAmountReceived`, `CallerNotQuipWallet`). **Caveat:** `contractErrorName` is only populated when the RPC returns revert data — a provider that strips it yields `code: 'GAS_ESTIMATION_FAILED'` with no name. Branch on `code` first; treat `contractErrorName` as best-effort detail.

## 8. What the SDK does NOT do

This is the application's job, not the library's:

- **Secret storage / lifecycle** — generation is provided; persistence, secure handling, and availability at claim time are yours.
- **Counterparty discovery & terms negotiation** — agreeing on assets and the interleaved schedule happens out of band.
- **Wallet / key management & signing UX** — you pass a viem `WalletClient`; the SDK never holds keys.
- **Bridging / cross-chain messaging / relaying** — cross-chain settlement is a coordinated flow you (or a relayer) drive; the SDK provides validation and the off-chain commitment check, not transport.

## 9. Audience notes

- **External integrators:** the **workflow helpers** (`planSameChainSwap`, `getSameChainSwapStatus`, `validateCrossChainSchedule`, `verifyRemoteCommitment`) are the supported high-level entry points. Prefer them over hand-rolling client calls.
- **Teams calling the client directly:** `getSameChainSwapStatus` is a convenience whose conclusions should be **cross-checked against the client preflights** — the client (and ultimately the contract) is the enforcement point. The status helper reads state for display/coordination; it is not an authorization.

## 10. Common footguns

Each entry is *pitfall → why → do this instead*. These describe the SDK and protocol **as they behave today** — they are usage guidance, not bugs to fix.

- **`msg.value` must be EXACT.** Commit requires `msg.value == totalNative(party) + commitmentFee` exactly; the contract reverts `IncorrectNativeAmountReceived` on both over- and under-payment. Never pad the native value the way you pad gas. **Do:** let the SDK compute and send the value; never add a buffer to it.

- **The commitment fee can change between read and submit.** It is owner-mutable. The SDK re-reads it immediately before building the commit tx, but a fee change in that gap can still cause `IncorrectNativeAmountReceived`. **Do:** surface a retry path on that revert rather than treating it as fatal.

- **Deadlines must strictly interleave; there is NO freshness check.** The SDK validates ordering, not that deadlines are in the future — the taker legitimately commits after the proposer's deadline has elapsed. **Do:** build the schedule from the chain's current `block.timestamp` with comfortable gaps; reusing past timestamps or too-tight gaps is on you.

- **The taker cannot commit until the proposer's commitment deadline passes.** The taker's commit window is `[proposer.commitmentDeadline, taker.commitmentDeadline)`; an early taker commit reverts/preflights `WindowViolated`. This surprises people expecting back-to-back commits. **Do:** gate the taker commit on reaching `proposer.commitmentDeadline` (poll `getSameChainSwapStatus` for `awaiting-taker-commit`).

- **The secret holder must be the proposer (cross-chain).** Assign the secret to the taker and `validateCrossChainSchedule` rejects it. **Why:** a secret-holding taker could claim the counterparty leg while letting their own leg expire — the cross-chain "free option." **Do:** make the secret holder the side with the earlier `commitmentDeadline`.

- **The secret becomes PUBLIC the moment the proposer claims.** The reveal claim emits the secret in the `Claim` event. **Do:** treat it as public immediately after; the taker's reaction buffer exists precisely so they can use the revealed secret before their own window closes.

- **Reclaim is permissionless; recipients are fixed.** Anyone can submit `claim`/`reclaim`; funds always go to the `recipient` / `reclaimRecipient` encoded in the terms — submitting does **not** redirect funds to the caller. **Do:** not assume "only I can claim/reclaim" or that being the sender pays you.

- **One same-chain claim settles BOTH legs.** Do not call `claim` twice for a same-chain swap — the second reverts `InvalidLockState` (the lock is already `Spent`). **Do:** treat the first successful claim as final settlement of the whole swap.

- **A tx hash is not success.** A mined transaction can still have reverted. **Do:** always resolve the receipt and check status — `waitForOmnibusReceipt` throws `TRANSACTION_REVERTED` for you — before treating a step as done.

- **Setting an explicit `gas` disables the revert check.** Passing `opts.gas` skips gas estimation — which is also the SDK's pre-submission revert check — so a call that would revert is signed and broadcast anyway and burns its gas (the protocol preflights still run). **Do:** leave `gas` unset so estimation catches reverts first; if you only want a bigger buffer use `gasMultiplier`; pass an explicit `gas` only for a call you have already confirmed will succeed.

- **ERC-721 amount is canonicalized to `1n` by the builder.** If you hand-build an ERC-721 `Asset` with a different `amount`, both sides must use the identical value or the digests diverge and the swap won't match (`TermsMismatch`). **Do:** always use `erc721Asset(target, tokenId)`.

- **ERC-20 `id` must be `0`.** A non-zero `id` on an ERC-20 asset is rejected (`InvalidERC20Asset` / SDK `INVALID_ERC20_ASSET`). **Do:** use `erc20Asset(target, amount)`, which sets `id` to `0n`.

- **USDT-style approvals.** Some non-standard ERC-20s revert on `approve` when the current allowance is non-zero. **Do:** reset the allowance to `0` first, then approve the required amount (or use `submitApproval` with an `erc20Mode` and handle the reset in your flow).

- **Receipt logs are multi-contract.** A claim/reclaim receipt contains logs from every token moved, not just `Omnibus`. The raw `decode*Events(logs)` helpers match by event signature only and do **not** filter by emitter, so a same-signature event from another contract in the same transaction would be decoded as if it were `Omnibus`'s (this also affects `extractRevealedSecret`). **Do:** for historical reads use the address-scoped `getCommitmentEvents` / `getClaimEvents` / `getReclaimedEvents` (they take an `address`); when decoding a raw receipt, scope to the `Omnibus` address yourself. *(If the receipt-path decoders gain an `address` parameter in a future version, prefer it.)*

- **Reorgs.** Events and receipts observed once are not final, and `Reclaimed` legitimately appears twice in a dual-leg reclaim. **Do:** honour your confirmation/finality policy — pass `{confirmations}` to `waitForOmnibusReceipt` and don't treat a single observation as settled.
