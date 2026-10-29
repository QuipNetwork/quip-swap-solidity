# QUIP Swap Lifecycle

How a single swap proceeds from proposal to settlement, on one chain or across two.

This is the *temporal* view. For contract structure, storage, and the deployment model, see [ARCHITECTURE.md](./ARCHITECTURE.md).

## Table of Contents

- [Core Concepts](#core-concepts)
- [The Deadline Schedule](#the-deadline-schedule)
- [Lock State Machine](#lock-state-machine)
- [Same-Chain Lifecycle](#same-chain-lifecycle)
- [Cross-Chain Lifecycle](#cross-chain-lifecycle)
- [Terminal States](#terminal-states)
- [Timeout and Failure Paths](#timeout-and-failure-paths)
- [Security Properties](#security-properties)
- [Data Structures](#data-structures)

---

## Core Concepts

### The secret and the lock

A swap is coordinated by a hashlock. One party generates a random 32-byte `secret` and publishes only

```
lock = keccak256(secret)
```

The `lock` identifies the swap in `Omnibus` storage. Revealing the `secret` is what settles it — `claim` derives the lock from the secret it is given, so a caller cannot claim without knowing it.

The contract never checks *who* holds the secret. The protocol works because the party who generated it is the only one who can move first.

### Proposer and taker

The two sides are not symmetric. Their roles are determined entirely by their deadlines:

```solidity
proposedByParty(party, counterparty) = party.commitmentDeadline < counterparty.commitmentDeadline
```

The **proposer** is whichever side has the earlier commitment deadline. They generate the secret, commit first, and reveal first. The **taker** commits second and claims second, using the revealed secret.

Nothing in the struct labels a side; the schedule *is* the role assignment.

### Terms and the canonical digest

Each side's obligations are a `Terms` struct (chain, recipients, three deadlines, assets). The pair is bound together by an order-independent digest:

```solidity
digestTermsCanonically(party, counterparty)   // hashes both, smaller digest first
```

The first `commit` stores that value in `termsHash[lock]`; every later `commit`, `claim` and `reclaim` re-checks it (`TermsMismatch`). Both legs are therefore locked to one negotiated pairing — neither side can settle against altered terms.

Separately, `posted[lock][termsDigest]` records which *side* has actually been funded. Settlement checks it before paying out (`TermsNotPosted`), so a lock can never disburse a leg nobody escrowed.

### Authorization and fees

`commit` is permissionless in the sender: `msg.sender` **funds**, while the identity in `CommitAuth` **authorizes**. The two routes (keyed ERC-7913 signature, or quip-wallet membership) are detailed in [ARCHITECTURE.md](./ARCHITECTURE.md#authorization-model).

Each commit must send exactly `party.totalNative() + commitmentFee`. The fee accrues to the owner; the rest stays escrowed and owed to `reclaimRecipient`.

---

## The Deadline Schedule

This is the heart of the protocol. `validateTermPairing` requires the six deadlines to **strictly interleave** — proposer, taker, proposer, taker, proposer, taker:

```
P.commitmentDeadline < T.commitmentDeadline < P.claimDeadline
                     < T.claimDeadline < P.reclaimRelease < T.reclaimRelease
```

Any other ordering reverts `DisordedDeadlines` at `commit`. Each side must also independently satisfy `commitmentDeadline < claimDeadline < reclaimRelease`.

That interleave produces non-overlapping action windows. All are half-open `[lower, upper)` — `enforceWithin` admits `lower` and excludes `upper`:

```
   0        P.cD       T.cD      P.claimD    T.claimD   P.reclaimR   T.reclaimR
   ├─────────┼──────────┼───────────┼───────────┼───────────┼────────────┼──────►
   │P commits│ T commits│ P claims  │        T claims       │            │
   │◄───────►│◄────────►│◄─────────►│◄─────────────────────►│            │
                                                            │ P reclaims ────────►
                                                                         │ T reclaims ►
```

| Actor | Action | Window (as enforced in code) |
|---|---|---|
| Proposer | `commit` | `[0, P.commitmentDeadline)` |
| Taker | `commit` | `[P.commitmentDeadline, T.commitmentDeadline)` |
| Proposer | `claim` (reveals secret) | `[T.commitmentDeadline, P.claimDeadline)` |
| Taker | `claim` (uses secret) | `[P.claimDeadline, P.reclaimRelease)` |
| Proposer | `reclaim` | `[P.reclaimRelease, ∞)` |
| Taker | `reclaim` | `[T.reclaimRelease, ∞)` |

Three consequences worth internalizing:

1. **The taker commits only after the proposer's commit window has closed.** The taker therefore acts against a proposer's leg that can no longer change.
2. **The taker claims only after the proposer's claim deadline.** The proposer must reveal first, or not at all.
3. **The taker's reaction gap is `P.reclaimRelease − P.claimDeadline`.** That span is the HTLC safety buffer — the time the taker has to observe the revealed secret and act on it before the proposer can begin reclaiming. Its *ordering* is enforced on-chain; its *width* is yours to size.

> `T.claimDeadline` constrains the ordering but is not itself a bound on the taker's claim window — that window is bracketed by the **proposer's** `claimDeadline` and `reclaimRelease`.

---

## Lock State Machine

```
Unused ──same-chain 1st commit──► Free ──2nd commit──► Committed ──claim/reclaim──► Spent
   └────cross-chain commit───────────────────────────► Committed ──claim/reclaim──► Spent
                                    └────────────────reclaim──────────────────────► Spent
```

`_advanceLockTo` whitelists these transitions and reverts `InvalidLockAdvancement` on anything else. Settlement marks the lock `Spent` **before** moving assets, which is what makes reentrant settlement fail.

A same-chain pairing enters `Free` on the first commit because the second leg is still expected locally. A cross-chain pairing goes straight to `Committed`: the counterparty's commit lives on another chain and is not observable here.

---

## Same-Chain Lifecycle

Both `Terms.chainId` values equal the local chain. One `Omnibus` holds both legs, and a single `claim` settles the whole swap.

```
  Proposer                    Omnibus (chain X)                    Taker
     │                              │                                │
     │ 1. secret, lock=H(secret)    │                                │
     │    negotiate terms off-chain ├───────────────────────────────►│
     │                              │                                │
     │ 2. commit(lock, P, T, auth)  │                                │
     ├─────────────────────────────►│  Unused → Free                 │
     │    escrow P assets + fee     │  termsHash[lock] = canonical    │
     │                              │  posted[lock][P] = true         │
     │                              │                                │
     │                              │  3. commit(lock, T, P, auth)   │
     │                              │◄───────────────────────────────┤
     │                              │  Free → Committed              │
     │                              │  posted[lock][T] = true         │
     │                              │                                │
     │ 4. claim(secret, P, T)       │                                │
     ├─────────────────────────────►│  Committed → Spent             │
     │                              │  T assets → P.recipient        │
     │                              │  P assets → T.recipient        │
     │◄─────────────────────────────┤───────────────────────────────►│
     │              both legs settled in one call                    │
```

**Steps**

1. **Negotiate off-chain.** The proposer picks a secret, derives the lock, and agrees the interleaved deadline schedule and asset lists with the taker.
2. **Proposer commits** before `P.commitmentDeadline`. This writes `termsHash[lock]`, posts the proposer's side, escrows their assets, and moves the lock to `Free`.
3. **Taker commits** in `[P.commitmentDeadline, T.commitmentDeadline)`. Terms must hash to the same canonical digest. Re-posting the *same* side reverts `TermsAlreadyPosted`. Lock moves to `Committed`.
4. **Proposer claims** in `[T.commitmentDeadline, P.claimDeadline)`, revealing the secret. Because the proposer's own leg is also local, `claim` pays out **both** directions in the same transaction — the taker's assets to `P.recipient` and the proposer's to `T.recipient`. The lock is `Spent`; nothing further is possible.

The taker never needs to call `claim` on a same-chain swap: the reciprocal transfer is atomic with the proposer's.

---

## Cross-Chain Lifecycle

The two `Terms.chainId` values differ. There are two independent `Omnibus` deployments — **at the same address**, since the CREATE3 salt is chain-invariant — and no on-chain link between them. The hashlock is the only bridge.

```
  Proposer            Omnibus (chain A)      Omnibus (chain B)            Taker
     │                       │                      │                       │
     │ 1. secret, lock, terms negotiated off-chain ─┼──────────────────────►│
     │                       │                      │                       │
     │ 2. commit(lock,P,T)   │                      │                       │
     ├──────────────────────►│ Unused → Committed   │                       │
     │   escrow P on chain A │ posted[P] = true     │                       │
     │                       │                      │                       │
     │                       │                      │ 3. commit(lock,T,P)   │
     │                       │                      │◄──────────────────────┤
     │                       │                      │ Unused → Committed    │
     │                       │                      │ posted[T] = true      │
     │                       │                      │                       │
     │ 4. claim(secret,P,T) on chain B — SECRET NOW PUBLIC                   │
     ├──────────────────────────────────────────────►│ Committed → Spent    │
     │                       │                      │ T assets → P.recipient│
     │                       │                      │                       │
     │                       │  5. claim(secret,T,P) on chain A              │
     │                       │◄──────────────────────────────────────────────┤
     │                       │ Committed → Spent    │  reads secret from B   │
     │                       │ P assets → T.recipient                        │
```

**Steps**

1. **Negotiate off-chain**, as above.
2. **Proposer commits on chain A** before `P.commitmentDeadline`. `commit` requires `party.chainId == block.chainid`, so each side commits on its own chain. Lock → `Committed`.
3. **Taker commits on chain B** in `[P.commitmentDeadline, T.commitmentDeadline)`. **The taker must independently confirm the proposer's commit on chain A first** — the contract cannot see it and checks only deadlines.
4. **Proposer claims on chain B** in `[T.commitmentDeadline, P.claimDeadline)`. `claim` requires the *counterparty's* leg to be local — that is where the proposer gets paid. The taker's assets go to `P.recipient`. Since `party.chainId != block.chainid`, only that one direction settles. **The secret is now public in the chain-B transaction.**
5. **Taker claims on chain A** in `[P.claimDeadline, P.reclaimRelease)`, using the secret observed in step 4. The proposer's assets go to `T.recipient`.

Each chain's lock advances to `Spent` independently. The atomicity guarantee is economic, not enforced: step 4 is what makes step 5 possible.

---

## Terminal States

Both terminal paths end at `LockState.Spent`, which is absorbing — no transition leaves it.

### Claimed

Reached via `claim` with a valid secret, inside the claimant's window, on a `Committed` lock whose relevant sides are `posted`. Assets move to the `recipient` addresses fixed in the terms. Emits `Claim(caller, lock, secret)` — publishing the secret, which is the mechanism the counterparty depends on cross-chain.

### Reclaimed

Reached via `reclaim` after the caller's `reclaimRelease`. Assets return to the `reclaimRecipient` addresses. Emits `Reclaimed` once per leg returned.

`reclaim` returns **both** legs in one call when the counterparty's leg is local *and* the lock is `Committed` — the stalled same-chain case. Otherwise it returns only the caller's leg.

---

## Timeout and Failure Paths

| Situation | Lock state | Resolution |
|---|---|---|
| Taker never commits (same-chain) | `Free` | Proposer reclaims after `P.reclaimRelease`; only their leg was escrowed |
| Taker never commits (cross-chain) | `Committed` on A | Proposer reclaims on chain A after `P.reclaimRelease`; chain B was never touched |
| Both committed, nobody claims (same-chain) | `Committed` | Either side reclaims after their `reclaimRelease`; the first such call returns **both** legs |
| Proposer never reveals (cross-chain) | `Committed` on both | Each side reclaims on its own chain after its own `reclaimRelease`; the proposer's opens first |
| Proposer reveals, taker misses their window | `Spent` on B, `Committed` on A | **The taker loses** — see Security Properties |
| Terms don't match the stored digest | unchanged | `TermsMismatch`, no state change |
| Action outside the window | unchanged | `WindowViolated`, no state change |

---

## Security Properties

These are pinned by tests under `test/attack/`.

**Taker negligence is the real cross-chain hazard.** If the proposer reveals late in `[…, P.claimDeadline)` and the taker fails to act before `P.reclaimRelease`, the proposer can claim one leg and reclaim the other — taking both. The *ordering* that creates the taker's reaction gap is enforced on-chain, so a schedule that removes the gap is rejected at `commit` (`test_crossChain_misorderedSchedule_rejectedAtCommit`). What remains is a **parameter-sizing** problem: make `P.reclaimRelease − P.claimDeadline` wide enough to absorb chain congestion, reorgs, and the taker's monitoring latency. See `test_crossChain_takerNegligence_proposerTakesBothLegs`.

**Lock poisoning is accepted grief, not theft.** The lock is public from the first commit. Anyone can front-run with the same lock and their own cheap terms, setting `termsHash[lock]` first and making the legitimate commit revert `TermsMismatch`. It is not exploitable: the attacker must escrow real assets, payouts only ever target addresses fixed in their own terms, and the victim simply retries with a fresh secret — which the attacker cannot predict. Pinned by `test_lockPoisoning_blocksLegitCommit_butIsRecoverableAndSidesteppable`.

**Settlement is reentrancy-safe.** The lock advances to `Spent` before any transfer, so a malicious recipient re-entering `claim` or `reclaim` fails the transition whitelist rather than double-settling.

**Unfunded legs cannot be drained.** Every payout re-checks `posted[lock][digest]`, so a leg nobody escrowed can never be paid out.

**Cross-chain commits are not verifiable on-chain.** The contract enforces deadlines only. Confirming the counterparty's commit on the other chain is the taker's responsibility; getting it wrong means escrowing against nothing — recoverable via `reclaim`, but only after the wait.

**Commit signatures attribute, they do not gate.** A valid `CommitAuth` proves the declared identity endorsed *this* payload; it does not restrict which identity may post a side. Counterparty-identity policy belongs off-chain, against the `Commitment` event.

---

## Data Structures

`Terms`, `Asset`, `AssetType`, `CommitAuth` and `LockState` are defined in [ARCHITECTURE.md](./ARCHITECTURE.md#data-structures). The lifecycle-relevant fields:

| Field | Role in the lifecycle |
|---|---|
| `chainId` | Which chain this leg's assets live on; `commit` requires it to be local |
| `recipient` | Receives the **counterparty's** assets on `claim` |
| `reclaimRecipient` | Receives **this** side's assets back on `reclaim` |
| `commitmentDeadline` | Closes this side's commit window; the earlier one designates the proposer |
| `claimDeadline` | Closes the proposer's reveal window and opens the taker's |
| `reclaimRelease` | Opens this side's reclaim; the proposer's also closes the taker's claim |
