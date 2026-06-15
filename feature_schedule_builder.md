# Feature — Conservative Deadline Defaults (schedule builder)

New helper for the `sdk/` TypeScript SDK: build a correctly-interleaved,
conservatively-spaced six-timestamp swap schedule from a single buffer, so
callers don't hand-compute deadlines. The Solidity contracts in `src/` are
the source of truth and MUST NOT be modified. Conventions as elsewhere in
the SDK: `QuipSwapError` with codes from the `QuipSwapErrorCode` union, full
TSDoc (`@param`/`@returns`/`@throws`/`@see`/`@example`), bigint everywhere
(all timestamps and durations are bigint Unix SECONDS), readonly inputs, no
unsafe casts, no secret logging.

Scope decisions (locked — do not expand):
- SINGLE buffer, UNIFORM gaps. One duration separates every adjacent pair
  of the six ordered timestamps. No presets, no per-stage buffers.
- BUILD ONLY. This feature constructs schedules; it does NOT add a
  validator. `validateCrossChainSchedule` already validates, and a built
  schedule must pass it unchanged (see "Consistency" below).

After implementation: run `bun run check` from `sdk/` and do not report the
task complete unless it passed.

---

## Background (why this is shaped the way it is)

A swap needs two `Terms`, each carrying three lifecycle timestamps
(`commitmentDeadline < claimDeadline < reclaimRelease`). Across both sides
the six values must STRICTLY INTERLEAVE — the proposer (earlier schedule)
precedes the taker at every stage:

```text
proposer.commitmentDeadline
  < taker.commitmentDeadline
  < proposer.claimDeadline
  < taker.claimDeadline
  < proposer.reclaimRelease
  < taker.reclaimRelease
```

(this is exactly `TermsLib.validateTermPairing`). Each gap is a reaction
window in which a party must observe an on-chain event and land a
transaction; too-tight gaps lose swaps to reorgs, RPC outages, congestion,
or slow relayers. "Conservative" means spacing those gaps generously. The
existing `validateCrossChainSchedule` deliberately REQUIRES the caller to
pass `minimumBufferSeconds` (no default) — this builder is the companion
that helps a caller PRODUCE a schedule meeting a chosen buffer, while
keeping the "the caller chooses the number" principle: the buffer is still
an explicit argument, there is no magic safe constant baked in.

---

## API

Add a new module `sdk/src/schedule.ts` (exported from `index.ts`).

```ts
/** Arguments for {@link buildSwapSchedule}. */
export interface BuildSwapScheduleArgs {
  /**
   * The schedule anchor in Unix SECONDS — the first timestamp
   * (proposer.commitmentDeadline) is placed at `startTime + bufferSeconds`,
   * NOT at startTime itself (the proposer needs time to actually commit
   * before their own deadline). Typically the current chain time; pass an
   * explicit value, never read a clock inside the helper.
   */
  readonly startTime: bigint
  /**
   * The uniform gap, in SECONDS, between every adjacent pair of the six
   * ordered timestamps — AND between `startTime` and the first timestamp.
   * REQUIRED; there is no production-safe default. Choose from chain
   * finality, reorg risk, RPC reliability, congestion, relayer latency,
   * and your operational margin. Must be > 0.
   */
  readonly bufferSeconds: bigint
  /**
   * Identifies which side is the PROPOSER (secret holder / earlier
   * schedule) — this determines interleaving order. The proposer's three
   * timestamps occupy positions 1, 3, 5; the taker's occupy 2, 4, 6.
   */
  readonly proposer: SchedulePartyInput
  /** The taker (counterparty / later schedule). */
  readonly taker: SchedulePartyInput
}

/**
 * The non-timestamp fields of one side's terms. The builder fills in the
 * three lifecycle timestamps; the caller supplies everything else.
 */
export interface SchedulePartyInput {
  readonly chainId: bigint
  readonly reclaimRecipient: Address
  readonly recipient: Address
  readonly assets: readonly Asset[]
}

/** The built, interleaved schedule. */
export interface BuiltSwapSchedule {
  /** The proposer's complete terms (timestamps at positions 1, 3, 5). */
  readonly proposerTerms: Terms
  /** The taker's complete terms (timestamps at positions 2, 4, 6). */
  readonly takerTerms: Terms
  /** The six ordered timestamps, for inspection/UX. */
  readonly timeline: {
    readonly proposerCommitmentDeadline: bigint
    readonly takerCommitmentDeadline: bigint
    readonly proposerClaimDeadline: bigint
    readonly takerClaimDeadline: bigint
    readonly proposerReclaimRelease: bigint
    readonly takerReclaimRelease: bigint
  }
  /** Echo of the uniform gap used (== bufferSeconds). */
  readonly bufferSeconds: bigint
}

export function buildSwapSchedule(args: BuildSwapScheduleArgs): BuiltSwapSchedule
```

(Import `Address` from viem; `Asset`/`Terms` from `./types.js`.)

## Behavior

1. Validate inputs: `bufferSeconds > 0n` (else `QuipSwapError`
   `INVALID_RANGE` with a clear message), `startTime > 0n`. Reuse the
   existing asset/recipient structural checks if convenient, but the full
   `validateTerms` runs in step 4 anyway.
2. Compute the six timestamps as a uniform arithmetic sequence. With
   `b = bufferSeconds` and `t0 = startTime`:

   ```text
   proposer.commitmentDeadline = t0 + 1*b
   taker.commitmentDeadline     = t0 + 2*b
   proposer.claimDeadline       = t0 + 3*b
   taker.claimDeadline          = t0 + 4*b
   proposer.reclaimRelease      = t0 + 5*b
   taker.reclaimRelease         = t0 + 6*b
   ```

   This placement guarantees, by construction:
   - each side's own ordering `commitment < claim < reclaim` (positions
     1<3<5 and 2<4<6);
   - the full interleaving (1<2<3<4<5<6);
   - every adjacent gap exactly `b`, including the taker's post-reveal
     reaction buffer (`proposer.reclaimRelease - proposer.claimDeadline`
     = positions 5 - 3 = 2*b ... NOTE: re-derive this carefully — see the
     reaction-buffer note below — and write a test pinning the value).
3. Assemble `proposerTerms` and `takerTerms` by combining each
   `SchedulePartyInput` with its three computed timestamps.
4. Defensively run the SDK's own `validateTerms` on each side AND
   `validateTermPairing(proposerTerms, takerTerms)` before returning, so a
   builder bug can never emit a schedule the contract would reject. Also
   assert `proposedBy(proposerTerms, takerTerms) === 'party'` (the builder
   must actually place the proposer earlier); throw a `QuipSwapError` if
   any of these fail (they should be unreachable — treat a failure as an
   internal invariant violation with a descriptive message).
5. Return `BuiltSwapSchedule`.

### Reaction-buffer note (get this exactly right)

The taker's post-reveal reaction buffer is
`proposer.reclaimRelease - proposer.claimDeadline`. With the placement
above that is `(t0+5b) - (t0+3b) = 2*b`. Confirm whether you want the
RAW per-gap buffer to be `b` (adjacent timeline gaps) while the
reaction buffer is naturally `2*b`, OR whether the reaction buffer
specifically should equal `b`. Per the locked "uniform gaps" decision,
keep adjacent timeline gaps uniform at `b` and let the reaction buffer be
`2*b` as a consequence — document this explicitly in the TSDoc and pin it
in a test, because it is the single most safety-relevant interval and a
reader must not be surprised by it. Do NOT silently special-case it.

## Consistency requirement

A schedule from `buildSwapSchedule(...)` with buffer `b` MUST pass
`validateCrossChainSchedule({proposerTerms, takerTerms, minimumBufferSeconds: b})`
WITHOUT modification (for the cross-chain case where the two legs are on
different chains). Add a test that builds a schedule and feeds it straight
into `validateCrossChainSchedule` and asserts it is accepted. This is the
contract between the two helpers: the builder produces what the validator
demands.

Note the builder is chain-agnostic — it works for same-chain and
cross-chain swaps alike (it only sets timestamps). It does NOT enforce
different chainIds; that is `validateCrossChainSchedule`'s job for the
cross-chain path.

## Tests (`sdk/test/unit/schedule.test.ts`)

- the six timestamps are strictly increasing and equal `t0 + k*b`;
- `validateTermPairing` accepts the built pair; `proposedBy` returns the
  proposer;
- the reaction buffer equals `2*b` (pin the documented value);
- `bufferSeconds <= 0n` throws `INVALID_RANGE`; `startTime <= 0n` throws;
- a built schedule passes `validateCrossChainSchedule` with
  `minimumBufferSeconds = b` (different chainIds) and is REJECTED with
  `minimumBufferSeconds = b + 1n` (proves the gap is exactly `b`);
- supplied non-timestamp fields (chainId, recipients, assets) are carried
  through unchanged onto the correct side;
- caller-supplied `assets` arrays are not mutated.

## Docs

Add a short "Building a schedule" subsection to `sdk/README.md`: show
`buildSwapSchedule` producing terms, then those terms flowing into
`validateCrossChainSchedule` and `client.commit`. State plainly that
`bufferSeconds` is the caller's safety dial (bigger = safer but slower) and
that no safe default is assumed.
