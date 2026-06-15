# Quip Swap SDK

TypeScript SDK for the Quip Swap **Omnibus** protocol: non-custodial, hashlocked same-chain and cross-chain swaps of Native / ERC-20 / ERC-721 / ERC-1155 assets between QuipWallets.

The SDK gives browser apps, Node.js backends, QuipWallet front-ends, and cross-chain coordinators safe, typed access to the `Omnibus` singleton:

- **Pure protocol helpers** — asset builders, terms construction and validation, pairing/window math, Solidity-exact hashing, secure secret generation. No RPC required.
- **Chain access** — a typed client (reads + preflighted writes with node-side gas estimation and a safety-buffered gas limit), approval planning, receipt decoding, event queries.
- **Workflow helpers** — same-chain plan/status helpers and cross-chain schedule validation/coordination.

The SDK never takes custody of private keys, never auto-approves tokens, and never hides wallet signing. SDK-side validation mirrors the contract's checks to fail early with actionable errors — it never replaces on-chain enforcement.

---

## Installation

The SDK lives inside the `quip-swap-solidity` repository under `sdk/` and uses [Bun](https://bun.sh).

```bash
cd sdk
bun install
```

`viem` is a peer dependency; applications bring their own Viem clients.

## ABI generation

The Omnibus ABI is generated from the Foundry build artifact — never hand-maintained:

```bash
forge build          # at the repository root
cd sdk
bun run generate:abi # writes src/generated/omnibusAbi.ts (ABI only, `as const`)
```

The script is deterministic, excludes bytecode/metadata, and fails with a clear error if the artifact is missing.

## Creating Viem clients

The SDK accepts existing Viem clients — browser wallets, local accounts, backends, hardware-wallet transports:

```ts
import {createPublicClient, createWalletClient, custom, http} from 'viem'
import {base} from 'viem/chains'

const publicClient = createPublicClient({chain: base, transport: http(RPC_URL)})
// browser:
const walletClient = createWalletClient({chain: base, transport: custom(window.ethereum)})
// backend (local account):
// const walletClient = createWalletClient({chain: base, transport: http(RPC_URL), account})
```

## Creating an Omnibus SDK client

```ts
import {createOmnibusClient, resolveDeployment} from '@quip.network/quip-swap-sdk'

// the built-in registry is EMPTY by design — supply your verified address:
const {omnibusAddress} = resolveDeployment(8453n, {chainId: 8453n, omnibusAddress: '0x...'})

const client = createOmnibusClient({address: omnibusAddress, publicClient, walletClient})

await client.getVersion()        // 0n
await client.getCommitmentFee()  // current fee in wei
await client.getLockState(lock)  // LockState.Unused | Free | Committed | Spent
```

## Asset builders

```ts
import {nativeAsset, erc20Asset, erc721Asset, erc1155Asset} from '@quip.network/quip-swap-sdk'

nativeAsset(10n ** 18n)            // 1 ETH (target = zero address, id = 0n)
erc20Asset(USDC, 1_000_000n)       // id is ALWAYS 0n — the contract rejects non-zero ids for ERC-20
erc721Asset(NFT, 42n)              // amount canonicalized to 1n (see below); token id 0n is VALID
erc1155Asset(ITEMS, 7n, 25n)       // token id 0n is VALID
```

Every amount must be `> 0n` — for **every** asset type, including ERC-721 (contract rule). The SDK additionally canonicalizes ERC-721 amounts to `1n`: the contract only requires a non-zero amount, but the amount is hashed into the terms digest while the transfer always moves exactly one NFT, so canonicalization prevents two digests describing the same effective transfer (marked `SDK-STRICTER-THAN-CONTRACT` in the source).

Use `validateAsset(asset)` for objects arriving from JSON/APIs/databases — it mirrors `TermsLib.validateAsset` exactly.

## Creating terms

Each side of a swap is a `Terms` value with **three lifecycle timestamps** (Unix seconds, as `bigint`):

| Field                | Meaning                                                              |
| -------------------- | -------------------------------------------------------------------- |
| `chainId`            | chain where THIS side's assets are escrowed                          |
| `reclaimRecipient`   | receives this side's own assets back on reclaim                      |
| `recipient`          | receives the **counterparty's** assets on claim                      |
| `commitmentDeadline` | commit forbidden at/after this instant                               |
| `claimDeadline`      | claiming gated by this side's schedule forbidden at/after this       |
| `reclaimRelease`     | reclaim of this side's escrow permitted at/after this                |
| `assets`             | non-empty list of assets this side escrows                           |

```ts
import {createTerms} from '@quip.network/quip-swap-sdk'

const aliceTerms = createTerms({
  chainId: 8453n,
  reclaimRecipient: aliceWallet,
  recipient: aliceWallet,
  commitmentDeadline: now + 600n,
  claimDeadline: now + 1800n,
  reclaimRelease: now + 3600n,
  assets: [nativeAsset(10n ** 18n)],
})
```

The two sides' timestamps must **strictly interleave** (`validateTermPairing`):

```text
proposer.commitmentDeadline < taker.commitmentDeadline
  < proposer.claimDeadline < taker.claimDeadline
  < proposer.reclaimRelease < taker.reclaimRelease
```

The **proposer** is the side with the smaller `commitmentDeadline`; it commits first. Note that structural validation deliberately does **not** check that deadlines are in the future — the taker legitimately commits after the proposer's deadline has elapsed; freshness is enforced per-action by the windows below.

## The timing-window model

All windows are **half-open** `[lower, upper)` — the upper bound is exclusive, so adjacent windows share a boundary and exactly one window accepts the shared instant:

| Action            | Window                                                          |
| ----------------- | --------------------------------------------------------------- |
| proposer commit   | `[0, proposer.commitmentDeadline)`                               |
| taker commit      | `[proposer.commitmentDeadline, taker.commitmentDeadline)`        |
| proposer claim    | `[taker.commitmentDeadline, proposer.claimDeadline)`             |
| taker claim       | `[proposer.claimDeadline, proposer.reclaimRelease)`              |
| reclaim (per leg) | `[leg.reclaimRelease, ∞)`                                        |

```text
0 ──────┬──────────┬───────────┬───────────┬───────────┬───────────┬──→ t
        │ p.commit │ t.commit  │ p.claim   │ t.claim   │ p.reclaim │ t.reclaim
window: │ proposer │  taker    │ proposer  │  taker    │ reclaim p │ reclaim t
        │ commits  │  commits  │  claims   │  claims   │  opens    │  opens
```

`validateCommitWindow`, `validateClaimWindow`, and `validateReclaimWindow` are pure helpers that take an **explicit timestamp** (pass the chain's `block.timestamp`, not your wall clock).

## Secrets and locks

```ts
import {generateSecret, secretToPair, generateLock} from '@quip.network/quip-swap-sdk'

const {secret, lock} = generateSecret() // crypto.getRandomValues — CSPRNG only
```

- The **lock** (`keccak256(secret)`) may be shared freely; it's published on-chain.
- The **secret** must remain private until the holder claims — the on-chain `Claim` event then reveals it publicly.
- Revealing the secret early compromises a cross-chain flow (anyone can claim inside an open window).
- Losing the secret makes claiming impossible; assets are then only recoverable via reclaim after `reclaimRelease`.
- The SDK never logs secrets, and error messages never echo them.

## The QuipWallet gate on commit (transitional)

The contract currently gates `commit` so only contracts deployed by the QuipFactory may commit:

```solidity
modifier onlyQuipWallet() {
  if (QUIP_FACTORY.vaultIdOf(msg.sender) == bytes32(0)) revert CallerNotQuipWallet();
  _;
}
```

This gate is **transitional** — the protocol is moving wallet-agnostic and the `onlyQuipWallet` modifier is planned for removal. The SDK therefore deliberately does **not** preflight or name it: there is no dedicated error code for it, so no SDK change is needed when the modifier is dropped.

- While the gate exists, a non-wallet `commit` reverts at **gas estimation** and surfaces as a `QuipSwapError` with `code: 'CONTRACT_REVERT'` and `contractErrorName === 'CallerNotQuipWallet'` — the reason is fully visible, just not via a dedicated code.
- **Caveat:** the clean `contractErrorName` depends on the RPC returning revert data; a provider that strips it yields `code: 'GAS_ESTIMATION_FAILED'` (with no name) instead.
- `client.isQuipWallet(account)` remains as an **optional, transitional** proactive check (reads `vaultIdOf` on `QUIP_FACTORY`); it is **no longer run automatically** before `commit`. Don't build durable logic on it.
- The committer is the **QuipWallet contract address** — never its owner's EOA. Assets must belong to the wallet; approvals must be issued by the wallet.
- `claim` and `reclaim` have **no** gate — any account (EOA, relayer, contract) may call them.
- In tests, `QuipFactoryMock.registerWallet` lets plain EOAs pass the gate — a test convenience, not a production pattern.

## Approval checking

```ts
import {planApprovals, submitApproval} from '@quip.network/quip-swap-sdk'

const plan = await planApprovals({publicClient, omnibusAddress, committer: quipWallet, terms})
for (const item of plan.items.filter(i => !i.satisfied)) {
  const hash = await submitApproval({
    publicClient, walletClient, omnibusAddress, item,
    erc20Mode: 'exact', // REQUIRED for ERC-20: 'exact' or 'unlimited' — never defaulted
  })
  await publicClient.waitForTransactionReceipt({hash})
}
```

- ERC-20: aggregated `allowance(committer, omnibus) >= sum(amounts)` per token.
- ERC-721: `getApproved(tokenId) == omnibus` **or** `isApprovedForAll`.
- ERC-1155: `isApprovedForAll`.
- **Fee-on-transfer caveat:** commit reconciles received balances; a token that delivers less than the declared amount reverts `UnexpectedAmountReceived` even with a satisfied approval plan.

## Write flow: gas estimation, safety buffer, and TxOptions

Every write (`commit`, `claim`, `reclaim`, `admin.*`) follows the same pipeline:

1. **Protocol preflights** — structural/pairing validation, chain-id, windows, and a lock-state check (`verifyOnChainState`, default on): claim requires the lock `Committed`, reclaim requires `Free` or `Committed`, and a commit into a `Free` lock must match the canonical `termsHash` and must not re-post an already-posted side. Failures produce precise codes (`INVALID_LOCK_STATE`, `TERMS_ALREADY_POSTED`, `TERMS_NOT_ON_CHAIN`) before any transaction exists. (The contract's `onlyQuipWallet` gate is deliberately **not** preflighted — see "The QuipWallet gate on commit".)
2. **Balance preflight** — BEFORE estimation, bare call value only: throws `BALANCE_TOO_LOW` with `{required, balance}` when the sender can't cover `totalValue`. Value-less calls (claim/reclaim/admin) skip it — gas funding is deliberately not preflighted (it's the wallet app's concern); a gas-unfunded sender's SEND-time failure is still mapped to `BALANCE_TOO_LOW`, never mislabeled `CONTRACT_REVERT`. Running this first means insufficient funds can never masquerade as a gas-estimation failure.
3. **Gas estimation** — `publicClient.estimateContractGas` executes the call node-side, so a would-be revert surfaces here as a decoded `CONTRACT_REVERT` (this replaces the earlier `simulateContract` step).
4. **Safety buffer** — `gas = floor(estimate × multiplier)`, default `1.2`, clamped to `[1.0, 2.0]`, computed with exact bigint math. Unused gas is refunded, so the buffer costs nothing at execution; it prevents out-of-gas failures from state drift between estimation and inclusion — which matters here because writes happen inside closing time windows.
5. **Submission** — `writeContract` with the prepared gas, fees, and nonce.

Every write accepts an optional final `TxOptions`:

```ts
await client.commit({lock, party, counterparty}, {
  gas: 400_000n,            // explicit limit: skips estimation AND the multiplier
  gasMultiplier: 1.5,       // or tune the buffer (clamped to [1.0, 2.0])
  maxFeePerGas: 5n * 10n ** 9n,        // EIP-1559 (exclusive with gasPrice)
  maxPriorityFeePerGas: 10n ** 9n,
  // gasPrice: ...,         // legacy pricing for non-1559 chains
  nonce: 7,                 // pin the nonce; default: viem fetches it
  skipPreflightChecks: true // skips ONLY the balance (call value) check —
                            // protocol preflights always run
})
```

Only explicitly-set fee fields are forwarded, so viem's automatic fee pricing keeps working for everything you leave unset.

## Same-chain flow

```ts
import {planSameChainSwap, getSameChainSwapStatus, generateSecret} from '@quip.network/quip-swap-sdk'

const plan = planSameChainSwap(aliceTerms, bobTerms) // validates + normalizes roles
const {secret, lock} = generateSecret()              // the PROPOSER holds the secret

// 1. proposer commits in [0, proposer.commitmentDeadline)        lock: Unused -> Free
await proposerClient.commit({lock, party: plan.proposerTerms, counterparty: plan.takerTerms})
// 2. WAIT — the taker's window only opens at proposer.commitmentDeadline
// 3. taker commits (posts the OTHER side)                        lock: Free -> Committed
await takerClient.commit({lock, party: plan.takerTerms, counterparty: plan.proposerTerms})
// 4. anyone with the secret claims in the proposer-claim window  lock: Committed -> Spent
await anyClient.claim({secret, party: plan.proposerTerms, counterparty: plan.takerTerms})

const {status} = await getSameChainSwapStatus(client, lock, plan) // 'claimable', ...
```

### Claim

- `claim` is **permissionless**: anyone with the secret may call it; the transaction makes the secret public.
- **One same-chain claim settles BOTH legs**: the counterparty's assets go to `party.recipient` and the party's assets go to `counterparty.recipient` in the same transaction.

### Reclaim

- `reclaim` is **permissionless** and pays the terms' `reclaimRecipient` regardless of caller.
- Gated only by the local leg's `reclaimRelease` (window `[release, ∞)`).
- **Dual-leg reclaim:** when the counterparty leg is local and the lock is `Committed`, one reclaim returns BOTH legs and emits **two** `Reclaimed` events.
- **Reclaim-from-Free:** if only the proposer committed (lock `Free`), reclaim is valid after the proposer's release (`Free -> Spent`).

## Cross-chain flow

A cross-chain swap is a **coordinated flow across two independent chains — not one atomic transaction**. With Alice as proposer/secret holder on Chain A, Bob as taker on Chain B:

```ts
import {validateCrossChainSchedule, verifyRemoteCommitment, extractRevealedSecret} from '@quip.network/quip-swap-sdk'

// 0. validate roles + buffers BEFORE any transaction
validateCrossChainSchedule({
  proposerTerms: aliceTermsOnA,   // the SECRET HOLDER's leg — must be the proposer
  takerTerms: bobTermsOnB,
  minimumBufferSeconds: 1800n,    // your choice — no safe default exists
})

// 1. Alice commits on Chain A (Unused -> Committed; no Free state cross-chain)
// 2. Bob MUST verify Alice's remote commitment off-chain before committing:
const status = await verifyRemoteCommitment(chainAClient, lock, aliceTermsOnA, bobTermsOnB)
if (!status.committed) throw new Error('do not commit')
// 3. Bob commits on Chain B in [alice.commitmentDeadline, bob.commitmentDeadline)
// 4. Alice claims Bob's leg ON CHAIN B — the Claim event REVEALS the secret
// 5. Bob (or a relayer) extracts the secret from the Chain B event:
const secret = extractRevealedSecret(receipt.logs, lock)
// 6. Bob claims Alice's leg ON CHAIN A in [alice.claimDeadline, alice.reclaimRelease)
```

**Role assignment is a safety invariant:** the secret holder must be the proposer. If the secret holder were the taker, the windows would let them claim the counterparty leg while retaining the option to let their own leg expire (the cross-chain "free option" — see `test/attack/CrossChainFreeOption.t.sol`). `validateCrossChainSchedule` rejects this.

**Step 2 is mandatory and cannot be enforced on-chain** — Chain B cannot read Chain A. A taker that skips it risks escrowing assets against a proposer who never committed.

## Buffer selection

The taker's post-reveal reaction buffer is `proposer.reclaimRelease - proposer.claimDeadline` — the time the taker has between the latest possible secret reveal and the close of their claim window. `validateCrossChainSchedule` requires a minimum gap between **every** pair of adjacent schedule timestamps. There is no universal safe value; choose it from:

- chain finality and reorganization risk on both chains
- RPC reliability and network congestion
- relayer responsiveness
- your operational safety margin

A buffer comfortable on a fast-finality L2 may be recklessly small on a congested L1.

## Error handling

Every SDK error is a `QuipSwapError` with a stable `code`, and on-chain reverts carry the decoded custom-error name:

```ts
import {QuipSwapError} from '@quip.network/quip-swap-sdk'

try {
  await client.commit({lock, party, counterparty})
} catch (err) {
  if (err instanceof QuipSwapError) {
    err.code              // 'WINDOW_VIOLATED' | 'INVALID_LOCK_STATE' | 'CONTRACT_REVERT' | ...
    err.contractErrorName // 'CallerNotQuipWallet' | 'WindowViolated' | ... (when decodable)
    err.cause             // the original Viem error, always preserved
  }
}
```

Decoded contract errors cover `IOmnibus` (`TermsMismatch`, `InvalidLockState`, `IncorrectNativeAmountReceived`, `InvalidLockAdvancement`, `TermsAlreadyPosted`, `TermsNotPosted`, `FeeExceedsMax`, `CallerNotQuipWallet`, `ZeroQuipFactory`), `TermsLib` (`ZeroAmount`, `ZeroChainId`, `ChainIdMismatch`, `DisordedDeadlines`, `InvalidNativeAsset`, `InvalidERC20Asset`, `InvalidERC721Asset`, `InvalidERC1155Asset`, `EmptyAssets`, `ZeroDeadline`, `UnexpectedAmountReceived`, `WindowViolated`, `ZeroAddressRecipient`, `InvalidRange`), and OpenZeppelin's `OwnableUnauthorizedAccount`/`OwnableInvalidOwner` on admin paths. Timing failures surface as `WindowViolated`; ordering failures as `DisordedDeadlines`.

Note on receipts: a transaction **hash is not finality**. Use `waitForOmnibusReceipt(publicClient, hash, {confirmations, timeout})` to wait, check status, and decode events; pick confirmation counts per your finality policy. Events can be duplicated or reorganized — `Reclaimed` legitimately appears twice in a dual-leg reclaim, and a log observed once is not final.

## Catching contract reverts

Any contract revert that reaches the SDK is decoded generically — there is no per-error SDK code to maintain, and you can still see exactly what failed. The SDK surfaces it as a `QuipSwapError` with `code: 'CONTRACT_REVERT'`, `contractErrorName` set to the Solidity error name, and `cause` preserving the original viem error:

```ts
try {
  // e.g. committing with the wrong msg.value
  await client.commit({lock, party, counterparty})
} catch (err) {
  if (err instanceof QuipSwapError && err.code === 'CONTRACT_REVERT') {
    err.contractErrorName // 'IncorrectNativeAmountReceived'
    err.cause             // the original viem ContractFunctionRevertedError
  }
}
```

This is also how the **transitional** `onlyQuipWallet` gate surfaces today: an unregistered committer reverts at gas estimation as `CONTRACT_REVERT` with `contractErrorName === 'CallerNotQuipWallet'`, rather than via a dedicated code (the gate is being removed, so the SDK does not couple to it).

**Caveat:** `contractErrorName` is only populated when the RPC returns the revert data. A provider that strips revert data yields `code: 'GAS_ESTIMATION_FAILED'` with no name, so branch on `code` first and treat `contractErrorName` as best-effort detail.

## Running the tests

```bash
cd sdk
bun install
bun run generate:abi        # requires `forge build` at the repo root first

bun run test:unit           # pure protocol logic — no chain
bun run test                # unit + mocked-client orchestration tests
bun run test:integration    # starts Anvil, deploys real artifacts, runs
                            # integration + Solidity/TS differential tests
bun run test:cross-chain    # starts TWO Anvil nodes (31337/31338), full E2E
bun run typecheck && bun run build
```

Or from the repository root: `make sdk-install sdk-generate sdk-typecheck sdk-test sdk-test-integration sdk-test-cross-chain sdk-build`, or everything at once with `make check`.

The differential tests treat the deployed `TermsLibHarness`/`OmnibusHarness` as the **oracle** — TypeScript hashing, window math, pairing decisions, and native totals are compared byte-for-byte / decision-for-decision against Solidity on a live node.

### Smoke test

```bash
cd sdk
bun run smoke
```

`bun run smoke` is a fast "is the whole stack on fire?" gate: it drives **one same-chain swap and one cross-chain swap end-to-end through the workflow layer** (`planSameChainSwap` + `getSameChainSwapStatus`, then `validateCrossChainSchedule` + `verifyRemoteCommitment`) against two real Anvil nodes (chains 31337 and 31338). It is **fail-fast** — it stops at the first broken step, prints `SMOKE FAILED at step N` with the error, and exits non-zero (the exit code is what CI keys on); on success it logs one `ok` line per step and prints `SMOKE PASSED`.

Run it as a quick pre-push / CI gate **before** the slower, exhaustive `test:integration` and `test:cross-chain` suites — it proves the layers compose and the happy path works at all, and is deliberately shallow on edge cases (those suites own them). It is a standalone script, not a vitest file: it starts and stops its own Anvil nodes on every exit path (success, failure, interrupt), so nothing leaks. **Foundry must be installed** (it runs `forge build` first and spawns `anvil`).

## Security limitations

- SDK validation is a preflight convenience; only the contract enforces the protocol.
- The SDK does not custody keys, store secrets, or run a bridge. Secret storage and relaying are the application's responsibility.
- Cross-chain swaps are not atomic; risk is bounded by the schedule and the off-chain commitment check, both of which the application must respect.
- Fee-on-transfer/deflationary tokens fail commit by design (`UnexpectedAmountReceived`).
- Nonstandard ERC-20s exist; a satisfied approval plan is necessary, not sufficient.

## Deployment registry

The built-in registry is **empty**. No verified deployment of the active two-argument-constructor Omnibus is known to this SDK, and addresses are never invented. Supply `{chainId, omnibusAddress}` explicitly via `resolveDeployment` / `createOmnibusClient`.

**Stale-deploy-script caveat:** the repository's `script/DeployOmnibus.s.sol` and `script/DeployTestnet.s.sol` encode constructor args as `abi.encode(OMNIBUS_OWNER)` — one argument — while the active constructor is `constructor(address initialOwner, address quipFactory)`. Any CreateX init-code hash or deterministic address derived from those scripts as written is **wrong** for the active contract. The SDK therefore does not derive deterministic addresses; the scripts need a verified QuipFactory address before they can be fixed.
