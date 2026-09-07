# Prototype client CLI

```text
quip-swap <command> --party <alice|bob> --state-root <party-dir> \
  --config <file> [--json|--summary-json] [--yes]
```

Each invocation owns only the selected party's client directory. Structured
inputs arrive on standard input; secrets are never command-line arguments.
`bootstrap-local` is the sole exception to the one-party boundary: it creates
the local two-chain runtime and both generated configs.

Use `--summary-json` for concise operator output and `--json` for the stable
`quip-swap-cli.v1` automation envelope. They are mutually exclusive. Mutating
commands use atomic generation files and a monotonic party-local sequence.
Prototype state files are permission-restricted but not encrypted.

## Commands

| Command | Party | Input | Purpose |
| --- | --- | --- | --- |
| `bootstrap-local` | either | none | Start and deploy the local two-chain demo runtime. |
| `init` | either | none | Create an isolated party workspace. |
| `prepare-trade` | Alice | JSON | Create canonical terms and the public offer. |
| `import-offer` | Bob | JSON | Validate and import Alice's offer. |
| `accept-trade` | Bob | none | Record Bob's local acceptance. |
| `status` | either | none | Read reconstructed state without mutation. |
| `submit-alice-commit` | Alice | JSON | Authorize, fund, and publish Alice's commit. |
| `observe-alice-commit` | either | none | Verify inclusion, finality, and the published Bob preimage. |
| `submit-bob-commit` | Bob | JSON | Fund Bob's leg with the finalized preimage. |
| `observe-bob-commit` | either | none | Verify Bob's exact committed leg. |
| `submit-revealing-claim` | Alice | JSON | Claim Bob's leg and reveal settlement. |
| `observe-reveal` | Bob | none | Verify finality and recover the settlement preimage. |
| `submit-final-claim` | Bob | Confirmation JSON or `--yes` | Claim Alice's leg permissionlessly. |
| `reclaim` | either | Confirmation JSON or `--yes` | Reclaim an eligible leg to its fixed recipient. |
| `enter-recovery` | either | JSON | Record party-local recovery mode and reason. |

Alice's commit publishes `BobCommitSecret`; Bob enables it only after canonical
finality. The revealing claim similarly publishes the settlement secret. Full
JSON output must redact unpublished secrets. Summary output may show a preimage
only after the corresponding successful on-chain publication.

See the [manual console demo](../docs/demo/console-demo.md) for an exact run.

## Final-claim and reclaim confirmation

`submit-final-claim` and `reclaim` require JSON on standard input unless
`--yes` is supplied. The confirmation object must contain:

- `schema`: exactly `quip-swap-confirmation.v1`;
- `action`: exactly the invoked command, `submit-final-claim` or `reclaim`;
- `confirmed`: the boolean `true`.

The confirmation carries no secrets or signatures. The command obtains its
trade data from the selected party workspace. Inputs containing secret,
private-key, signature, or preimage field names are rejected.

From `sdk/`, using the workspace and config variables established by the
[console demo](../docs/demo/console-demo.md):

```sh
jq -n '{schema:"quip-swap-confirmation.v1",action:"submit-final-claim",confirmed:true}' |
  bun run src/bin/quip-swap.ts submit-final-claim --party bob \
  --state-root "$BOB_ROOT" --config "$BOB_CONFIG" --summary-json
```

For an eligible Alice reclaim:

```sh
jq -n '{schema:"quip-swap-confirmation.v1",action:"reclaim",confirmed:true}' |
  bun run src/bin/quip-swap.ts reclaim --party alice \
  --state-root "$ALICE_ROOT" --config "$ALICE_CONFIG" --summary-json
```

In the local deterministic prototype, `--yes` replaces the confirmation JSON:

```sh
bun run src/bin/quip-swap.ts reclaim --party alice \
  --state-root "$ALICE_ROOT" --config "$ALICE_CONFIG" --summary-json --yes
```

Confirmation does not bypass the command's state, timing, or observation checks.
