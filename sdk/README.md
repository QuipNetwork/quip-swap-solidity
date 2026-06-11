# Quip Swap SDK

TypeScript SDK for the Quip Swap **Omnibus** protocol: non-custodial, hashlocked same-chain and cross-chain swaps of Native / ERC-20 / ERC-721 / ERC-1155 assets between QuipWallets.

The SDK gives browser apps, Node.js backends, QuipWallet front-ends, and cross-chain coordinators safe, typed access to the `Omnibus` singleton:

- **Pure protocol helpers** — asset builders, terms construction and validation, pairing/window math, Solidity-exact hashing, secure secret generation. No RPC required.
- **Chain access** — a typed client (reads + preflighted, simulated writes), approval planning, receipt decoding, event queries.
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

## The QuipWallet gate on commit

Only contracts deployed by the QuipFactory may commit:

```solidity
modifier onlyQuipWallet() {
  if (QUIP_FACTORY.vaultIdOf(msg.sender) == bytes32(0)) revert CallerNotQuipWallet();
  _;
}
```

- The committer is the **QuipWallet contract address** — never its owner's EOA. Assets must belong to the wallet; approvals must be issued by the wallet.
- `claim` and `reclaim` have **no** gate — any account (EOA, relayer, contract) may call them.
- Preflight check: `await client.isQuipWallet(account)` reads `vaultIdOf` on the contract's `QUIP_FACTORY` and is run automatically before every `commit`. This is the most common integration failure; the SDK error (`NOT_QUIP_WALLET`) explains it before any gas is spent.
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

Every SDK error is a `QuipSdkError` with a stable `code`, and on-chain reverts carry the decoded custom-error name:

```ts
import {QuipSdkError} from '@quip.network/quip-swap-sdk'

try {
  await client.commit({lock, party, counterparty})
} catch (err) {
  if (err instanceof QuipSdkError) {
    err.code              // 'NOT_QUIP_WALLET' | 'WINDOW_VIOLATED' | 'CONTRACT_REVERT' | ...
    err.contractErrorName // 'CallerNotQuipWallet' | 'WindowViolated' | ... (when decodable)
    err.cause             // the original Viem error, always preserved
  }
}
```

Decoded contract errors cover `IOmnibus` (`TermsMismatch`, `InvalidLockState`, `IncorrectNativeAmountReceived`, `InvalidLockAdvancement`, `TermsAlreadyPosted`, `TermsNotPosted`, `FeeExceedsMax`, `CallerNotQuipWallet`, `ZeroQuipFactory`), `TermsLib` (`ZeroAmount`, `ZeroChainId`, `ChainIdMismatch`, `DisordedDeadlines`, `InvalidNativeAsset`, `InvalidERC20Asset`, `InvalidERC721Asset`, `InvalidERC1155Asset`, `EmptyAssets`, `ZeroDeadline`, `UnexpectedAmountReceived`, `WindowViolated`, `ZeroAddressRecipient`, `InvalidRange`), and OpenZeppelin's `OwnableUnauthorizedAccount`/`OwnableInvalidOwner` on admin paths. Timing failures surface as `WindowViolated`; ordering failures as `DisordedDeadlines`.

Note on receipts: a transaction **hash is not finality**. Use `waitForOmnibusReceipt(publicClient, hash, {confirmations, timeout})` to wait, check status, and decode events; pick confirmation counts per your finality policy. Events can be duplicated or reorganized — `Reclaimed` legitimately appears twice in a dual-leg reclaim, and a log observed once is not final.

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

## Security limitations

- SDK validation is a preflight convenience; only the contract enforces the protocol.
- The SDK does not custody keys, store secrets, or run a bridge. Secret storage and relaying are the application's responsibility.
- Cross-chain swaps are not atomic; risk is bounded by the schedule and the off-chain commitment check, both of which the application must respect.
- Fee-on-transfer/deflationary tokens fail commit by design (`UnexpectedAmountReceived`).
- Nonstandard ERC-20s exist; a satisfied approval plan is necessary, not sufficient.

## Deployment registry

The built-in registry is **empty**. No verified deployment of the active two-argument-constructor Omnibus is known to this SDK, and addresses are never invented. Supply `{chainId, omnibusAddress}` explicitly via `resolveDeployment` / `createOmnibusClient`.

**Stale-deploy-script caveat:** the repository's `script/DeployOmnibus.s.sol` and `script/DeployTestnet.s.sol` encode constructor args as `abi.encode(OMNIBUS_OWNER)` — one argument — while the active constructor is `constructor(address initialOwner, address quipFactory)`. Any CreateX init-code hash or deterministic address derived from those scripts as written is **wrong** for the active contract. The SDK therefore does not derive deterministic addresses; the scripts need a verified QuipFactory address before they can be fixed.
