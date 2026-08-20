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
| `submit-final-claim` | Bob | none | Claim Alice's leg permissionlessly. |
| `reclaim` | either | none | Reclaim an eligible leg to its fixed recipient. |
| `enter-recovery` | either | JSON | Record party-local recovery mode and reason. |

Alice's commit publishes `BobCommitSecret`; Bob enables it only after canonical
finality. The revealing claim similarly publishes the settlement secret. Full
JSON output must redact unpublished secrets. Summary output may show a preimage
only after the corresponding successful on-chain publication.

See the [manual console demo](../docs/demo/console-demo.md) for an exact run.
