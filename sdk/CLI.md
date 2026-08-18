# Prototype trusted-client CLI contract

The Step 14 CLI uses one executable and keeps Alice and Bob in separate client
boundaries:

```text
quip-swap <command> --party <alice|bob> --state-root <party-directory> --config <path> [--json|--summary-json]
```

`--state-root` always names only the selected party's directory. Structured command
inputs come from standard input. Secrets are never accepted as command-line
arguments. `--json` preserves the complete stable automation envelope.
`--summary-json` emits the smaller `quip-swap-summary.v1` operator view containing
the action result, transaction state, relevant amounts, locks, warnings, and only
those preimages already published on-chain. The two JSON modes are mutually
exclusive and emit exactly one uncolored object to standard output.

The public commands are defined by `cliCommandSpecs` in `cliSurface.ts`. `status` is
the only read-only command; every other command writes only the selected party's
state. Alice publishes `BobCommitSecret` in her on-chain commit. Bob's
`observe-alice-commit` authenticates and verifies that publication, but enables it
for Bob's submission only after the configured finality threshold. No private
progression-secret transfer command exists.

Every command returns the `quip-swap-cli.v1` envelope defined in `cliSurface.ts`:

- `schema`, `command`, `party`, `mutatesState`, and monotonic party-local `sequence`;
- optional `tradeId`;
- either `ok: true`, JSON `result`, and `warnings`; or
- `ok: false` and a stable `error { code, message, details? }`.

Big integers, hashes, addresses, and transaction identifiers are encoded as strings.
No normal `--json` result or error field contains a secret preimage. The explicit
`--summary-json` view may show `BobCommitSecret` after Alice broadcasts her commit
and may show `Secret` after Alice broadcasts the revealing claim; neither appears
before its publication action succeeds.

Each party directory publishes matched public and secret generations through an
atomically replaced `current` pointer. Generation files are created with mode `0600`;
the containing directories use mode `0700`. Alice initially owns both preimages.
Bob's file acquires the progression preimage only from a finalized, authenticated
Alice-commit observation and acquires the settlement preimage only after a finalized
revealing claim. Restoration
recomputes `TradeID`, `GateContextID`, settlement `Lock`, and `commitLock` before
accepting the state. The prototype files are intentionally not encrypted.

Deterministic fixed preimages require `unsafe-demo` mode, are accepted only for local
chain IDs `31337` and `31338`, and are explicitly marked as public test secrets.
The demo supplies one named `ProtocolRandomness` object so settlement secret,
progression secret, both side nonces, and both action nonces cannot be confused by
positional ordering. Outside this mode the workflow generates six fresh independent
nonzero values.
