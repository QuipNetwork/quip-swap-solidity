# Same-chain demo

From `sdk/`, run:

```sh
bun run demo:same-chain
```

The runner starts one temporary chain, deploys the current protocol, exercises
success, invalid actions, one-sided reclaim, atomic two-sided reclaim, and
payout rollback, then writes `../demo-artifacts/same-chain-demo.json`.

Success reports:

- schema `quip-swap-same-chain-demo.v1` and state `Claimed`;
- transitions `Unused -> PartyCommitted -> BothCommitted -> Claimed`;
- 14 rejected invalid actions;
- both recovery branches and atomic rollback evidence;
- fixed recipient payouts and empty wrapper custody;
- no persisted secret preimages.

This demo uses the prototype verifier mock; it is not evidence of production PQ
verification or gas cost.

Validate an artifact without running a new chain:

```sh
bun run demo:same-chain:validate ../demo-artifacts/same-chain-demo.json
```

A missing artifact means the run did not complete. Restart the ephemeral demo
instead of continuing partial state.
