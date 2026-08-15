# Prototype trusted-client CLI contract

The Step 14 CLI uses one executable and keeps Alice and Bob in separate client
boundaries:

```text
quip-swap <alice|bob> <command> --state-dir <party-directory> [--input <json-file|->] [--json]
```

`--state-dir` always names only the selected party's directory. Structured command
inputs come from a JSON file or standard input (`--input -`). Secrets are never
accepted as command-line arguments. `--json` emits exactly one JSON object to stdout;
operator diagnostics go to stderr. Task 14.8.4 will implement the executable.

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
