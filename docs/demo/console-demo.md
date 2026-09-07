# Separate Alice/Bob console demo

Run each command from `sdk/`. Alice and Bob use separate state directories and a
new process for every action.

## Start a clean runtime

- Choose a fresh root; never reuse a prior chain or client state.

```sh
DEMO_ROOT="/tmp/interlock-v11-demo-$(date +%s)"
```

- Create it.

```sh
mkdir -p "$DEMO_ROOT"
```

- Start two Anvil chains, deploy the protocol, and create runtime configs.

```sh
bun run src/bin/quip-swap.ts bootstrap-local --party alice \
  --state-root "$DEMO_ROOT/runtime" \
  --config ../config/demo/console-bootstrap.json --summary-json
```

- Record each generated config.

```sh
ALICE_CONFIG="$DEMO_ROOT/runtime/alice.config.json"
```

```sh
BOB_CONFIG="$DEMO_ROOT/runtime/bob.config.json"
```

- Assign isolated party directories.

```sh
ALICE_ROOT="$DEMO_ROOT/alice"
```

```sh
BOB_ROOT="$DEMO_ROOT/bob"
```

- Initialize Alice.

```sh
bun run src/bin/quip-swap.ts init --party alice --state-root "$ALICE_ROOT" --config "$ALICE_CONFIG" --summary-json
```

- Initialize Bob.

```sh
bun run src/bin/quip-swap.ts init --party bob --state-root "$BOB_ROOT" --config "$BOB_CONFIG" --summary-json
```

- Use live chain time so manual operation does not inherit narrow fixed windows.

```sh
NOW=$(cast block latest --rpc-url http://127.0.0.1:8545 --field timestamp)
```

## Negotiate terms

- Alice creates canonical terms and exports the public offer.

```sh
jq -n --argjson now "$NOW" '{
  schema:"quip-swap-prepare-trade.v1",
  partyCommitmentDeadline:($now + 86400 | tostring),
  counterpartyCommitmentDeadline:($now + 172800 | tostring),
  partyClaimDeadline:($now + 864000 | tostring),
  counterpartyClaimDeadline:($now + 777600 | tostring),
  partyReclaimRelease:($now + 1209600 | tostring),
  counterpartyReclaimRelease:($now + 1123200 | tostring),
  partyAuthorizationExpiry:($now + 432000 | tostring),
  counterpartyAuthorizationExpiry:($now + 518400 | tostring)
}' | bun run src/bin/quip-swap.ts prepare-trade --party alice \
  --state-root "$ALICE_ROOT" --config "$ALICE_CONFIG" --summary-json
```

- Bob validates and imports the same public offer once.

```sh
bun run src/bin/quip-swap.ts import-offer --party bob \
  --state-root "$BOB_ROOT" --config "$BOB_CONFIG" --summary-json \
  < "$ALICE_ROOT/public/offer.json"
```

- Bob records local acceptance once. It is neither sent to Alice nor submitted
  on-chain.

```sh
bun run src/bin/quip-swap.ts accept-trade --party bob \
  --state-root "$BOB_ROOT" --config "$BOB_CONFIG" --summary-json
```

If an offer is already imported or accepted, do not repeat that command; move
to the next phase.

## Alice commits

- Alice funds chain 31337 and atomically publishes the trade-bound Bob-commit
  preimage with her commit.

```sh
jq -n '{schema:"quip-swap-alice-commit.v1",confirmed:true}' |
  bun run src/bin/quip-swap.ts submit-alice-commit --party alice \
  --state-root "$ALICE_ROOT" --config "$ALICE_CONFIG" --summary-json
```

- Alice records the non-final inclusion.

```sh
bun run src/bin/quip-swap.ts observe-alice-commit --party alice \
  --state-root "$ALICE_ROOT" --config "$ALICE_CONFIG" --summary-json
```

- Bob independently verifies the commit and published preimage, but keeps Bob's
  commit disabled while Alice's transaction is non-final.

```sh
bun run src/bin/quip-swap.ts observe-alice-commit --party bob \
  --state-root "$BOB_ROOT" --config "$BOB_CONFIG" --summary-json
```

- Mine two more chain-31337 blocks to reach three confirmations.

```sh
cast rpc --rpc-url http://127.0.0.1:8545 anvil_mine 0x2
```

- Alice records finality.

```sh
bun run src/bin/quip-swap.ts observe-alice-commit --party alice \
  --state-root "$ALICE_ROOT" --config "$ALICE_CONFIG" --summary-json
```

- Bob records canonical finality, imports the authenticated on-chain preimage,
  and enables his commit.

```sh
bun run src/bin/quip-swap.ts observe-alice-commit --party bob \
  --state-root "$BOB_ROOT" --config "$BOB_CONFIG" --summary-json
```

## Bob commits

- Bob funds chain 31338 with the finalized Bob-commit preimage.

```sh
bun run src/bin/quip-swap.ts submit-bob-commit --party bob \
  --state-root "$BOB_ROOT" --config "$BOB_CONFIG" --summary-json --yes
```

- Bob verifies his committed leg.

```sh
bun run src/bin/quip-swap.ts observe-bob-commit --party bob \
  --state-root "$BOB_ROOT" --config "$BOB_CONFIG" --summary-json
```

- Alice independently verifies Bob's committed leg.

```sh
bun run src/bin/quip-swap.ts observe-bob-commit --party alice \
  --state-root "$ALICE_ROOT" --config "$ALICE_CONFIG" --summary-json
```

## Settle

- Alice claims Bob's asset and publishes the settlement preimage on chain 31338.

```sh
bun run src/bin/quip-swap.ts submit-revealing-claim --party alice \
  --state-root "$ALICE_ROOT" --config "$ALICE_CONFIG" --summary-json --yes
```

- Bob records the reveal as non-final.

```sh
bun run src/bin/quip-swap.ts observe-reveal --party bob \
  --state-root "$BOB_ROOT" --config "$BOB_CONFIG" --summary-json
```

- Mine two more chain-31338 blocks.

```sh
cast rpc --rpc-url http://127.0.0.1:8546 anvil_mine 0x2
```

- Bob verifies finality and imports the authenticated settlement preimage.

```sh
bun run src/bin/quip-swap.ts observe-reveal --party bob \
  --state-root "$BOB_ROOT" --config "$BOB_CONFIG" --summary-json
```

- Bob permissionlessly claims Alice's asset on chain 31337.

```sh
bun run src/bin/quip-swap.ts submit-final-claim --party bob \
  --state-root "$BOB_ROOT" --config "$BOB_CONFIG" --summary-json --yes
```

- Alice verifies the final outcome.

```sh
bun run src/bin/quip-swap.ts status --party alice \
  --state-root "$ALICE_ROOT" --config "$ALICE_CONFIG" --summary-json
```

- Bob verifies the final outcome.

```sh
bun run src/bin/quip-swap.ts status --party bob \
  --state-root "$BOB_ROOT" --config "$BOB_CONFIG" --summary-json
```

Both views must report complete with `Claimed` on both chains, each leg's
dedicated HTLC address, fixed recipient balances of 10 and 20 demo tokens, and
zero terminal HTLC balances.

## Stop this runtime

- Stop only PIDs recorded by this bootstrap after verifying they are Anvil.

```sh
for pid in $(jq -r '.startedPids[]' "$DEMO_ROOT/runtime/runtime.json"); do
  [ "$(ps -p "$pid" -o comm= 2>/dev/null | tr -d ' ')" = "anvil" ] && kill "$pid"
done
```

To restart, stop the previous runtime and choose a new `DEMO_ROOT`. There is no
command that resets chain state in place. The automated separate-process replay
is `bun run demo:console`.
