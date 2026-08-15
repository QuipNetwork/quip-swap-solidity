# Prototype trusted-client CLI contract

The Step 14 CLI uses one executable and keeps Alice and Bob in separate client
boundaries:

```text
quip-swap <alice|bob> <command> --state-dir <party-directory> [--input <json-file|->] [--json]
```

`--state-dir` always names only the selected party's directory. Structured command
inputs come from a JSON file or standard input (`--input -`). Secrets are never
accepted as command-line arguments. `--json` emits exactly one JSON object to stdout;
operator diagnostics go to stderr. The trusted-workflow command layer is implemented;
the operator-facing formatter and executable assembly follow in the remaining demo tasks.

The commands are `prepare-trade`, `status`, `mark-alice-pending`,
`mark-alice-included-non-final`, `mark-alice-final`, `release-bob-secret`,
`submit-bob-commit`, `observe-reveal`, `handoff-final-claim`, `mark-complete`, and
`enter-recovery`. `status` is the only read-only command. Every other command writes
only the selected party's state. Cross-party transfer, such as progression-secret
release, must be an explicit command and must not grant either client direct access
to the other party's state directory.

Every command returns the `quip-swap-cli.v1` envelope defined in `cliSurface.ts`:

- `schema`, `command`, `party`, `mutatesState`, and monotonic party-local `sequence`;
- optional `tradeId`;
- either `ok: true`, JSON `result`, and `warnings`; or
- `ok: false` and a stable `error { code, message, details? }`.

Big integers, hashes, addresses, and transaction identifiers are encoded as strings.
No normal result or error field may contain a secret preimage.

Each party directory publishes matched public and secret generations through an
atomically replaced `current` pointer. Generation files are created with mode `0600`;
the containing directories use mode `0700`. Alice initially owns both preimages.
Bob's file may acquire the progression preimage only through `release-bob-secret`
and the settlement preimage only after a finalized revealing claim. Restoration
recomputes `TradeID`, `GateContextID`, settlement `Lock`, and `commitLock` before
accepting the state. The prototype files are intentionally not encrypted.

Deterministic fixed preimages require `unsafe-demo` mode, are accepted only for local
chain IDs `31337` and `31338`, and are explicitly marked as public test secrets.
The demo supplies one named `ProtocolRandomness` object so settlement secret,
progression secret, both side nonces, and both action nonces cannot be confused by
positional ordering. Outside this mode the workflow generates six fresh independent
nonzero values.
