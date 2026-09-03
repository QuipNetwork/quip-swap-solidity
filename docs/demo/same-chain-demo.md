# Same-chain demo

From `sdk/`, run:

```sh
bun run demo:same-chain
```

The runner starts one temporary chain, deploys the current protocol, exercises
success, invalid actions, one- and two-sided reclaim, failed-payout retry, and a
permanently reverting asset, then writes
`../demo-artifacts/same-chain-demo.json`.

Success reports:

- schema `quip-swap-same-chain-demo.v3` and state `Claimed`;
- transitions through `ClaimPending`, including a mined under-gassed payout and
  a successful retry;
- 14 rejected invalid actions;
- one- and two-sided reclaim with exact required/completed side bitmaps;
- preservation of one completed payout when the other side fails;
- a separate `ReclaimPending` trade where a permanently reverting asset strands
  only its own funded HTLC after two failed attempts;
- one funded HTLC per side, fixed recipient payouts, and empty HTLC custody
  after successful settlement;
- two live fee quotes and payments, two-fee accrual preserved through
  settlement, and exact owner withdrawal to zero accrued balance;
- no persisted secret preimages.

This demo uses the prototype verifier mock; it is not evidence of production PQ
verification or gas cost. Gas paid to the network is not included in the fee
trace or protocol revenue.

Validate an artifact without running a new chain:

```sh
bun run demo:same-chain:validate ../demo-artifacts/same-chain-demo.json
```

A missing artifact means the run did not complete. Restart the ephemeral demo
instead of continuing partial state.
