# Gas Update 2 — Sync stale write-flow docs after the prepareTx reorder

Standalone documentation-only fix for the `sdk/` TypeScript SDK. Follow-up
to `gas_fix.md`, which reordered `prepareTx` so the balance preflight runs
FIRST (before gas estimation) — but left `sdk/src/client.ts` docstrings
describing the OLD order. By this project's own documentation standard, an
inaccurate docstring is a bug. NO behavior changes in this task: if any
code change appears necessary, stop and report instead.

The contracts in `src/` are the source of truth and MUST NOT be modified.

After the fix: run `bun run check` from `sdk/` (typecheck + unit tests are
sufficient for a doc-only change) and do not report the task complete
unless it actually passed.

---

## The correct order (reference)

For every write, the flow is now:

```text
protocol preflights (structural, pairing, chain id, quip-wallet for
commit, window, optional on-chain lock state)
  → prepareTx:
      stage 1: balance preflight (bare call value only; the stage
               skipPreflightChecks disables; no-op for value-less calls)
      stage 2: gas — estimate node-side (the pre-submission revert check;
               skipped entirely when opts.gas is set) and apply the
               safety multiplier
  → writeContract (send-time InsufficientFundsError maps to BALANCE_TOO_LOW)
```

`sdk/src/gas.ts` already documents this correctly — treat its module
header and `prepareTx` docstring as the authoritative wording and make
`client.ts` agree with them.

## Changes (all in `sdk/src/client.ts`)

1. **`commit` docstring, numbered preflight list.** Currently ends:
   "9. gas is estimated node-side (a would-be revert surfaces here,
   decoded) and buffered by the safety multiplier; 10. the balance
   preflight runs; 11. submit." Reorder the tail to match reality:
   the balance preflight (bare `msg.value` only) runs first inside
   `prepareTx`, THEN gas is estimated (the would-be-revert check) and
   buffered, then submit. Keep the step numbering contiguous after the
   edit.
2. **`claim` docstring.** "then estimate+buffer gas, balance preflight,
   submit" → "then balance preflight, estimate+buffer gas (the
   pre-submission revert check), submit".
3. **`reclaim` docstring.** Same correction as `claim`.
4. **`submitWrite` docstring.** Currently: "prepare (estimate gas
   node-side — a would-be revert surfaces here decoded — apply the safety
   multiplier, run the balance preflight) and submit". Correct to the
   stage order: "prepare (balance preflight on the bare call value, then
   node-side gas estimation — a would-be revert surfaces here decoded —
   with the safety multiplier applied) and submit with the prepared
   gas/fees/nonce".
5. **Inline step comments in the write bodies.** `commit` has
   "9-11. estimate (revert check) + buffer + balance preflight + submit";
   `claim` has "7-9. ..." and `reclaim` has "5-7. ..." with the same
   wording. Update each to "balance preflight + estimate (revert check) +
   buffer + submit" and keep the step numbers consistent with the
   corrected docstring lists.
6. **Sweep for stragglers.** Search `sdk/src/` and `sdk/README.md` for any
   remaining text that places the balance preflight AFTER estimation or
   implies the balance check covers gas costs (it checks the bare call
   value only). The module header of `client.ts` ("then `prepareTx`
   (node-side gas estimation … plus a safety-buffered gas limit and a
   balance preflight)") lists estimation before the balance check —
   reword it to the correct order while you are there. Do not change any
   wording in `gas.ts`; it is already correct.
