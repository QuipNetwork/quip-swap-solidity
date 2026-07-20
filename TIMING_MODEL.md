# Cross-Chain Timing Model (bridgeless)

> ## ⚠️ Implementation reconciliation (authoritative)
>
> This document predates the shipped contracts and describes a **design exploration**, not
> the code. Where the two disagree, **`src/TermsLib.sol` and `src/Omnibus.sol` are
> authoritative.** Concrete divergences as implemented:
>
> | Topic | This doc (design) | Implemented (`src/`) |
> |-------|-------------------|----------------------|
> | Boundaries per side | Each side defines 3 of a single 6-boundary global schedule (`commitA⁻ < commitB⁻ < claimA⁻ < reclaimA⁺ < reclaimB⁺ < E`); one field nulled per side | **Each side carries its own three strictly-increasing deadlines**: `commitmentDeadline < claimDeadline < reclaimRelease`, validated per side by `validateTerms` and interleaved across sides by `validateTermPairing` |
> | Terminal expiry `E` | Present; closes the last reclaim so the partition is fully bounded | **Not implemented.** Reclaims are **open-ended**: `reclaim` enforces `enforceWithin(party.reclaimRelease, type(uint256).max, ts)` — `[reclaimRelease, ∞)` |
> | `taker.claimDeadline` | `0` (unused) | **Required, nonzero, ordered** — but used *only* for the pairing's strict ordering, never as a live window bound. The taker's claim is bounded by the proposer's `claimDeadline`/`reclaimRelease` |
> | `proposer.deadline` (`E`) | the taker's terminal field | **No `deadline` field exists** in `Terms` |
> | Refund recipient | implied = committer | explicit **`reclaimRecipient`** field on every side |
> | Addressing | `address` recipients/targets | **`bytes32` universal identifiers** (EVM addresses in the low 20 bytes; foreign-chain pubkeys use all 32) — see `SVM_COMPATIBILITY.md` |
> | Optimistic mode | Not present | New **`bool optimistic`** field on every side (7th of the 8 top-level `abi.encode` values in `digestTerms`, between `reclaimRelease` and `assets`). When BOTH sides sign `true`, the **LOWER bounds** of the commit and claim windows are waived; **all upper bounds and `reclaimRelease` stay enforced unconditionally**. Flags must be equal across the pair (`OptimismMismatch` at commit). See the subsection below. |
>
> ### Optimistic mode (implemented)
>
> Both sides may opt in to `optimistic = true` (bilateral: each commit signature binds BOTH
> terms digests, and `validateTermPairing` additionally rejects mixed flags). The effect is
> to waive ONLY the **forced sequencing waits** — the lower bounds of W1 (taker commit),
> W2 (proposer claim/reveal), and W3 (taker claim) drop to `0`:
>
> - **Same-chain:** commit + commit + claim can land at a single timestamp (even bundled
>   into one transaction — `commit` is permissionless), in **either commit order**
>   (`Unused -> Free` may be posted by the taker). Safety is carried entirely by the lock
>   state machine: claim/reclaim exclusivity via `Spent`, and both settlement and refund
>   are atomic across both legs. Nothing is lost by dropping the clock sequencing here.
> - **Cross-chain:** the taker need not wait for the proposer's commit deadline (off-chain
>   funding verification is then its ONLY ordering guarantee — see the ⚠️ warning in §7),
>   and the proposer may reveal the instant both legs are funded. The **reaction gap is
>   untouched**: the reveal deadline (`proposer.claimDeadline`, upper) and the reclaim gate
>   (`reclaimRelease`, lower — never waived) survive, so the taker's post-reveal claim
>   window only ever WIDENS (`[reveal, proposer.reclaimRelease)` instead of
>   `[claimDeadline, reclaimRelease)`). Reveal-then-reclaim theft remains blocked by
>   `reclaimRelease` (pinned by `test_optimistic_crossChain_proposerCannotRevealThenReclaim`).
>
> The deadline **values** remain required, non-zero, and strictly interleaved even when
> optimistic (`validateTerms` / `validateTermPairing`, ordering checked BEFORE the flag):
> roles are still derived from `commitmentDeadline` ordering, and the timed schedule is the
> live **fallback path** if the fast path stalls — so size the gaps generously (§8) and
> never tighten a schedule because the happy path is expected to settle instantly.
>
> **Why unbounded reclaim is safe (and chosen):** the "one action per window" partition is
> still preserved where it matters — claim and reclaim are mutually exclusive by the
> half-open window boundary *and* by the `Spent` lock state, so no asset is ever both
> claimed and reclaimed. Dropping the terminal `E` only removes the design's *stranding*
> edge: an actor that misses its reclaim window can still recover later instead of losing
> the funds forever. Cross-chain, the two reclaims sit on disjoint chains; same-chain, the
> first reclaim refunds **both** legs atomically to their respective `reclaimRecipient`s.
> The design's terminal-sweep trade-off is therefore moot as implemented.
>
> Sections below describe the original 6-boundary/`E` model and are kept for design
> rationale; treat the **bridging mechanisms (§5), enforcement split (§6), and clock-skew /
> gap-sizing guidance (§8)** as still current — those reason about trust assumptions, not the
> exact field layout.

A **per-chain** decomposition of the swap's window/boundary model. The single global
schedule we derived during design only tells half the story: in a bridgeless
cross-chain swap, **no contract can observe the other chain**, so each chain enforces
only its *local* schedule, and the two halves are bridged by (a) the hashlock and
(b) off-chain party verification of *whether the counterparty funded*.

> Notation: **A** = proposer, **B** = taker. **H** = hashlock, **s** = preimage
> (`hash(s) == H`); **A knows s**. **Chain‑A** custodies A's assets; **Chain‑B**
> custodies B's assets. Both `Terms` are submitted to *both* chains, so every chain
> holds the agreed absolute timestamp *values* — but never the other chain's *events*.

---

## 0. The governing invariant — one action per window

The schedule is a **fully-bounded partition of absolute time**: every action gets a
window closed on *both* ends, and **no two actions are ever simultaneously valid**. This
is the timing-attack defense. Two consequences drive the whole model:

1. **Every window is `[release, deadline]` — closed both sides.** Including the claims
   and the reclaims. A window that is open-ended (relying on a single bound + external
   state) does not hold the invariant.
2. **The partition is enforced by per-chain clock checks, not by trust.** Every boundary
   value is present on both chains, so each chain checks `block.timestamp` against the
   whole agreed partition locally. The *time* invariant is enforced. What a chain
   *cannot* verify is whether the counterparty actually **funded** (an event on the
   other chain) — that, plus the secret, are the only non-time couplings (§5).

> **Optimistic-mode caveat (implemented):** the *sequencing* half of this invariant — the
> lower bounds that keep actions from overlapping in time — is **conditional**: both sides
> may jointly waive it (see the banner subsection). The *theft-prevention* half — the claim
> upper bounds and the `reclaimRelease` gate that create the reaction gap — is
> **unconditional** and survives in every mode.

---

## 1. Asset custody → which action runs on which chain

| Asset | Lives on | Committed by | Claimed by | Reclaimed by |
|-------|----------|--------------|------------|--------------|
| A's assets | **Chain‑A** | A (commit) | **B** (with `s`) | A (refund) |
| B's assets | **Chain‑B** | B (commit) | **A** (reveals `s`) | B (refund) |

Each chain runs its own 3-action lifecycle on its *own* custodied asset:

```
Chain‑A (A's assets):   A‑commit  →  B‑claim   →  A‑reclaim
Chain‑B (B's assets):   B‑commit  →  A‑claim   →  B‑reclaim
                                       ▲ reveals s
```

The **reveal** happens on **Chain‑B** (A claims B's assets there, exposing `s`).
B then pulls `s` off Chain‑B and uses it to claim A's assets on **Chain‑A**.

---

## 2. Six boundaries, one global partition

Holding "one action per window" with *both-ended* windows requires **six** boundaries:
the five lifecycle boundaries plus a terminal expiry **`E`** that closes the last
window.

| Boundary | Natively defined by | Closes window | Opens window |
|----------|---------------------|---------------|--------------|
| `commitA⁻`  | A — commit deadline   | A‑commit  | B‑commit |
| `commitB⁻`  | B — commit deadline   | B‑commit  | A‑claim (reveal) |
| `claimA⁻`   | A — reveal deadline   | A‑claim   | B‑claim |
| `reclaimA⁺` | A — reclaim release   | B‑claim   | A‑reclaim |
| `reclaimB⁺` | B — reclaim release   | A‑reclaim | B‑reclaim |
| `E`         | B — terminal expiry   | B‑reclaim | — |

Strict global order:

```
commitA⁻ < commitB⁻ < claimA⁻ < reclaimA⁺ < reclaimB⁺ < E
```

Each interior boundary is **dual-role** — the *deadline* of the window it closes and the
*release* of the window it opens. With `E` added, **each party natively defines exactly
three** boundaries: the schedule is now **symmetric in definition (3/3)**, even though
the claim phase stays asymmetric in *meaning* (only A's reveal carries a hard deadline;
B's claim window is bounded by A's two claim/reclaim boundaries).

---

## 3. The six windows (gates the contract actually enforces)

### 3.0 Action × party quick matrix

Each (party, action) is permitted in exactly one window:

Each cell shows the window, chain, the `lower · upper` **struct fields** that bound it,
and the effect.

| | **Commit** | **Claim** | **Reclaim** |
|---|---|---|---|
| **Proposer (A)** | **W0** · Chain‑A · `[start, commitA⁻]`<br>bounds: `—` · `A.commitmentDeadline`<br>escrow A's assets | **W2** · Chain‑B · `[commitB⁻, claimA⁻]`<br>bounds: `B.commitmentDeadline` · `A.claimDeadline`<br>claim B's assets, **reveal `s`** | **W4** · Chain‑A · `[reclaimA⁺, reclaimB⁺]`<br>bounds: `A.reclaimRelease` · `B.reclaimRelease`<br>refund A's assets |
| **Taker (B)** | **W1** · Chain‑B · `[commitA⁻, commitB⁻]`<br>bounds: `A.commitmentDeadline` · `B.commitmentDeadline`<br>escrow B's assets | **W3** · Chain‑A · `[claimA⁻, reclaimA⁺]`<br>bounds: `A.claimDeadline` · `A.reclaimRelease`<br>claim A's assets, **need `s`** | **W5** · Chain‑B · `[reclaimB⁺, E]`<br>bounds: `B.reclaimRelease` · `B.deadline`<br>refund B's assets |

> `A.` = proposer's `Terms`, `B.` = taker's `Terms`. Bounds are `lower · upper`; `—` = open
> from creation. The two zeroed fields (`A.deadline`, `B.claimDeadline`) never bound a
> window.

- **Commit / Reclaim** act on your **own** chain (where your assets sit).
- **Claim** acts on the **counterparty's** chain (you take *their* assets): proposer
  claims on Chain‑B, taker claims on Chain‑A.
- Only the two claim cells carry a secret condition — A's claim **publishes** `s`, B's
  claim **consumes** `s`.
- Note the field-sharing: each interior boundary field bounds **two** windows — e.g.
  `A.reclaimRelease` is the *upper* bound of W3 and the *lower* bound of W4.

### 3.1 Per-window gates

Every gate is `enforceAfter` / `enforceBefore` on a `uint64` already in calldata —
checked against the local chain's clock. Claims carry the hashlock as an **additional**
condition. *(Implemented as a single half-open primitive:
`TermsLib.enforceWithin(lower, upper, ts)` over `uint256` fields — lower inclusive,
upper EXCLUSIVE, deliberately so adjacent windows sharing a boundary accept the shared
instant exactly once.)*

`A.` = proposer's `Terms`, `B.` = taker's `Terms`; bound fields shown as `lower · upper`
(`—` = open from creation).

| # | Action | Chain | Window | Bound fields (lower · upper) | Gate (all conditions required) |
|---|--------|-------|--------|------------------------------|-------------------------------|
| W0 | A‑commit  | A | `[start, commitA⁻]` | `—` · `A.commitmentDeadline` | `ts < commitA⁻` |
| W1 | B‑commit  | B | `[commitA⁻, commitB⁻]` | `A.commitmentDeadline` · `B.commitmentDeadline` | `ts ≥ commitA⁻` ∧ `ts < commitB⁻` |
| W2 | A‑claim (reveal) | B | `[commitB⁻, claimA⁻]` | `B.commitmentDeadline` · `A.claimDeadline` | `ts ≥ commitB⁻` ∧ `ts < claimA⁻` ∧ B funded ∧ **reveals `s`** |
| W3 | B‑claim   | A | `[claimA⁻, reclaimA⁺]` | `A.claimDeadline` · `A.reclaimRelease` | `ts ≥ claimA⁻` ∧ `ts < reclaimA⁺` ∧ **`hash(s)==H`** |
| W4 | A‑reclaim | A | `[reclaimA⁺, reclaimB⁺]` | `A.reclaimRelease` · `B.reclaimRelease` | `ts ≥ reclaimA⁺` ∧ `ts < reclaimB⁺` ∧ unclaimed |
| W5 | B‑reclaim | B | `[reclaimB⁺, E]` | `B.reclaimRelease` · `B.deadline` | `ts ≥ reclaimB⁺` ∧ `ts < E` ∧ unclaimed |

> **Optimistic mode (implemented):** when both sides sign `optimistic = true`, the LOWER
> bound of W1 (`ts ≥ commitA⁻`), W2 (`ts ≥ commitB⁻`), and W3 (`ts ≥ claimA⁻`) is waived —
> each becomes `ts ≥ 0`. The W0–W3 upper bounds and both reclaim releases (the W4/W5
> lowers) are enforced exactly as tabled in every mode; the W4/W5 UPPER bounds
> (`reclaimB⁺`, `E`) are not implemented at all — reclaims are open-ended per the banner,
> optimistic or not. W0 is unchanged (its lower is already open).

### Why B's claim needs the window **and** the preimage (W3)

The earlier model gated B's claim only on the preimage (state) plus the upper bound. That
does **not** hold the invariant. B‑claim now requires **both**, and neither alone
suffices:

- **Time window `[claimA⁻, reclaimA⁺]`** holds *one action per window*: it keeps B‑claim
  from overlapping the reveal (W2) or A‑reclaim (W4) *on the clock*, independent of when
  the secret happens to appear.
- **Preimage `hash(s)==H`** enforces the *secret dependency*: B cannot claim without `s`,
  even if Chain‑A's clock has already opened the window (e.g. Chain‑A runs ahead of
  Chain‑B and the window opens before A has revealed).

If A reveals *early* (before `claimA⁻`), B holds `s` but **waits until `claimA⁻`** to
claim. That extra wait is acceptable and is the price of a clean partition.
*(Implemented optimistic mode drops exactly this wait: with both flags set, B claims from
the reveal onward — the preimage requirement and the `reclaimA⁺` upper bound carry the
safety alone, which is why they are never waivable.)*

### Both reclaims are bounded (W4, W5)

A‑reclaim closes at `reclaimB⁺`; B‑reclaim closes at the terminal expiry `E`. Every
window is now closed on both ends, so the partition is complete. **Trade-off:** a reclaim
not taken within its window strands those assets (the actor's own liveness risk).
*(Implemented: reclaims are open-ended, so no stranding exists and no sweep is needed.)*

---

## 4. How the global order decomposes per chain

`commitA⁻ < commitB⁻ < claimA⁻ < reclaimA⁺ < reclaimB⁺ < E` is enforced as **local clock
checks on each chain** (every value is present on both chains):

| Constraint | Enforced on |
|-----------|-------------|
| `ts < commitA⁻` (W0) | Chain‑A |
| `commitA⁻ ≤ ts < commitB⁻` (W1) | Chain‑B |
| `commitB⁻ ≤ ts < claimA⁻` (W2) | Chain‑B |
| `claimA⁻ ≤ ts < reclaimA⁺` (W3) | Chain‑A |
| `reclaimA⁺ ≤ ts < reclaimB⁺` (W4) | Chain‑A |
| `reclaimB⁺ ≤ ts < E` (W5) | Chain‑B |

The time-window partition is therefore **fully on-chain**. The *cross-chain* concerns are
narrower than the partition (§5): they are causal ("did the counterparty fund?") and
quantitative ("is the reaction gap big enough?"), **not** ordering. (Under implemented
optimistic mode the waived lower bounds move the W1/W2 *sequencing* into the causal
bucket too — the funding checks each party already performs off-chain; the upper-bound
and reclaim rows above are enforced unchanged.)

---

## 5. The bridging mechanisms (and what is *not* clock-enforced)

| Mechanism | Couples | Status |
|-----------|---------|--------|
| **Hashlock `H`** | A‑claim/reveal (Chain‑B) → B‑claim (Chain‑A) | 🔒 **Cryptographic / trustless.** Same `H` on both chains; revealing `s` on Chain‑B is what lets B claim on Chain‑A. |
| **Window partition** (all six) | every adjacent pair of actions | ✅ **Clock-enforced per chain** — with one carve-out: under **optimistic mode** the parties jointly waive the LOWER bounds (the sequencing waits); the upper bounds and reclaim releases stay clock-enforced in every mode. The boundary values are agreed and replicated; each chain checks its own `block.timestamp`. |
| **Counterparty *funding*** | A funded before B commits; B funded before A reveals | 👁 **Trusted observation.** A chain cannot see the other chain's escrow *event*. Each party reads the other chain and refuses to advance if the counterparty hasn't funded. Failure mode = funds idle but recoverable in the actor's own reclaim window. |
| **Reaction-gap *sizing*** `reclaimA⁺ − claimA⁻` | reveal (Chain‑B) → B‑claim (Chain‑A) | 👁 **Trusted parameter.** The window is clock-enforced, but whether its *width* survives cross-chain clock skew + congestion + finality is a sizing choice, not an ordering check. **THE critical safety margin.** |

The key correction over a naïve reading: **ordering is enforced; only *existence of the
counterparty's deposit* and *gap width* are trusted.**

---

## 6. Enforcement responsibility — the full split

**On-chain, locally clock-enforced (cannot be bypassed):**
- All window UPPER bounds and both reclaim releases — in every mode. The commit/claim
  LOWER bounds are enforced by default but **jointly waivable** via optimistic mode
  (bilateral opt-in, bound into both signed terms — never unilateral)
- Hashlock on both claims (`hash(s) == H`)
- Per-asset disjointness: each asset is **claimed XOR reclaimed**, never both

**Cryptographically enforced across chains:**
- Reveal → claim coupling via hashlock `H`

**Trusted / off-chain (party responsibility — NOT enforceable):**
- B verifies A's Chain‑A escrow *exists* before committing on Chain‑B
- A verifies B's Chain‑B escrow *exists* before revealing (claiming) on Chain‑B
- `reclaimA⁺ − claimA⁻` sized for B's worst-case cross-chain reaction
- All gaps absorb cross-chain **clock skew**, inclusion latency, and reorg/finality depth

---

## 7. Abort / failure flows — funds are always recoverable

| # | Scenario | Outcome |
|---|----------|---------|
| 1 | A never commits | B (having verified) never commits → nothing at stake. If B committed prematurely, B refunds in `[reclaimB⁺, E]`. |
| 2 | B never commits | A never reveals → A refunds in `[reclaimA⁺, reclaimB⁺]`. Swap aborts. |
| 3 | Both commit, A never reveals | A refunds in W4; B refunds in W5. A gains nothing by stalling. |
| 4 | Both commit, A reveals by `claimA⁻` | `s` public → B claims A's assets in `[claimA⁻, reclaimA⁺]`. **Swap completes.** |
| 5 | A reveals, **B negligent** (misses W3) | A claimed B's assets *and* reclaims A's own → B loses. **Only via B's own inaction inside its reaction window.** |
| 6 | An actor misses its own **reclaim** window | Bounded reclaims mean those assets are stranded past the window — the actor's liveness risk. *(Implemented: reclaims are open-ended; a late actor recovers whenever they act.)* |

Scenarios 5 and 6 are liveness assumptions, not theft by the counterparty: each actor (or
its watchtower) **must** act inside its window. Size the windows generously and monitor.

> ## ⚠️ CROSS-CHAIN TAKER NEGLIGENCE LOSES BOTH LEGS
>
> Scenario 5 deserves to be shouted, not footnoted: **a cross-chain taker that commits and
> then fails to claim within its reaction window forfeits the entire swap — the proposer
> ends up holding BOTH their own funds AND the counterparty's.** The proposer claims the
> taker's leg with the secret on one chain, and reclaims their own untouched leg on the
> other once `reclaimRelease` passes. Neither chain can see the other, so nothing on-chain
> can stop it — only the taker acting inside `[reveal, proposer.reclaimRelease)`.
>
> This is **inherent to HTLCs and predates optimistic mode** (pinned by
> `test_crossChain_takerNegligence_proposerTakesBothLegs`); the reclaim boundary does not
> move under optimistic mode, and the taker's reaction window only ever widens (an early
> reveal opens it sooner; its close is fixed). What optimistic mode DOES change is the
> pacing: the forced waits that used to give the taker natural checkpoints are gone, so
> **off-chain funding verification before committing and actively watching for the reveal
> (a watchtower/monitor) are the taker's ONLY protections**
> (`test_optimistic_crossChain_takerNegligenceStillPunishable`).
>
> **Same-chain swaps have NO equivalent risk:** settlement and refund are each atomic
> across both legs in a single transaction, so no reachable state leaves one party holding
> both.

---

## 8. Clock skew & gap sizing

- Each chain interprets absolute timestamps against **its own** `block.timestamp`
  (miner leeway of seconds–minutes).
- The two chains' clocks can drift with **no on-chain reconciliation** — the window
  *bounds* are enforced locally, but a window of width `w` on Chain‑A may correspond to a
  real-time interval shorter than `w` once skew is subtracted.
- Every gap — above all the reaction window `reclaimA⁺ − claimA⁻` — must exceed the
  **sum** of: max cross-chain clock skew, max inclusion latency under congestion,
  reorg/finality depth on the relevant chain, and the actor's operational reaction time.
- Default to **hours, not minutes**; never tune to the best case. (This applies **doubly**
  under optimistic *mode*: the deadlines are then the fallback schedule for a stalled fast
  path — expected instant settlement is never a reason to tighten them.)

---

## 9. Implications for `Terms` and validation

- `Terms` stays **symmetric in shape**; each chain enforces only its local subset.
- `validateTermPairing` checks the full agreed order on either chain (both `Terms`
  present) — a **well-formedness** check. It **cannot** certify the reaction window is
  *wide enough*; gap sizing is a parameter concern orthogonal to ordering.
- **(Implemented)** `Terms` also carries `bool optimistic` (see the banner subsection):
  consent is bilateral by construction (both terms digests are bound into each commit
  signature) *and* checked explicitly (`validateTermPairing` reverts `OptimismMismatch`
  on mixed flags, after the ordering check). The deadline values stay required and
  strictly interleaved regardless of the flag — they are the fallback schedule and the
  source of role assignment.
- *(Design model only)* Each role leaves exactly **one timestamp field unused** (the
  symmetry of the asymmetry): the **taker's `claimDeadline`** (B's claim is bounded by A's
  boundaries) and the **proposer's terminal `deadline`** (A‑reclaim is bounded by the
  taker's `reclaimRelease`). *(Implemented: there is no `deadline` field and the
  taker's `claimDeadline` is required non-zero — it participates in ordering only; see the
  banner table.)*

---

## 10. The shipped struct

The design-model struct this document originally proposed (terminal `deadline`, nulled
taker fields) was NOT shipped. The authoritative `Terms`/`Asset` layout — including the
explicit `reclaimRecipient`, the `optimistic` flag, and bytes32 universal identifiers —
is `src/TermsLib.sol`; the divergences are tabulated in the banner at the top of this file.
