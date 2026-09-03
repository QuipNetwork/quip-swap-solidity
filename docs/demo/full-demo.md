# Automated cross-chain demo

From `sdk/`, run:

```sh
bun run demo:full
```

The runner builds the contracts, starts two temporary chains, deploys and funds
the protocol, executes the full swap and four invalid controls, writes
`../demo-artifacts/full-demo.json`, and stops both chains. Select another output
path by passing it as the final argument:

```sh
bun run demo:full ../demo-artifacts/replay.json
```

Success reports:

- schema `quip-swap-full-demo.v1`;
- both chain states `Claimed`;
- four rejected invalid actions;
- one funded HTLC per committed leg and empty HTLC custody after settlement;
- independent live fee quotes and payments on both chains, fee accrual unchanged
  by settlement, and exact owner withdrawal to zero accrued balance;
- 10 chain-A demo tokens paid to Bob and 20 chain-B tokens paid to Alice.

The artifact keeps native escrow, commitment fee, total transaction value, and
gas semantics separate. Its fee trace demonstrates protocol revenue only; gas
paid to validators is not included.

The invalid controls reject a disallowed submitter, a missing or wrong
Bob-commit preimage, and a wrong settlement preimage without changing state.
The owner-only artifact contains deterministic public test secrets; normal
operator traces redact them.

If the run fails, treat a missing artifact as incomplete and rerun from the
start. Do not continue an ephemeral partial chain. For separate client
processes, use the [console demo](console-demo.md).
