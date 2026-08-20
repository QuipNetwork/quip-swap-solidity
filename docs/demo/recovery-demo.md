# Cross-chain recovery demo

From `sdk/`, run:

```sh
bun run demo:cross-chain:recovery
```

The runner executes snapshot-isolated recovery branches on chains 31337 and
31338. It verifies:

- `(Reclaimed, Reclaimed)` when neither party claims;
- `(Reclaimed, Claimed)` when the revealing claim lands but final claim does not;
- claim-winning and reclaim-winning local terminal races;
- dropped, replaced, reverted, and reorganized observations do not advance
  trusted finality.

The redacted artifact is
`../demo-artifacts/cross-chain-recovery-demo.json`. Pass another path as the
final argument when needed. Because the chains are ephemeral, restart the demo
after failure rather than continuing partial state.
