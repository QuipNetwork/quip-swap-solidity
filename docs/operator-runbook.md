# Prototype full-demo operator runbook

This runbook operates the deterministic local v1.1 cross-chain demo. It is a
prototype test harness, not a production deployment procedure. The runner
starts two temporary Anvil chains, deploys and funds the protocol, executes the
complete flow and its four negative controls, writes one trace artifact, and
then stops both chains.

## Prerequisites

Run all commands from the repository root:

```sh
cd quip-swap-solidity/code
```

The following commands must be on `PATH`:

```sh
forge --version
anvil --version
bun --version
```

The verified development environment used Foundry 1.7.1 and Bun 1.3.14. Install
the SDK dependencies once:

```sh
cd sdk
bun install --frozen-lockfile
cd ..
```

The Solidity dependencies must already exist under `dependencies/`. Dependency
installation and ordinary demo builds are deliberately separate: maintainers
use the canonical `foundry.toml` and `soldeer.lock` when installing or updating
dependencies, while the demo uses `config/demo/foundry.toml`. The demo
configuration contains the same compiler settings and remappings but no
`[dependencies]` table, so `forge build` does not enter Soldeer's dependency
hash/update path.

If `dependencies/` is absent, install it once with a current Foundry release:

```sh
forge soldeer install
```

## Run the full demo

From the repository root:

```sh
cd sdk
bun run demo:full
cd ..
```

No manual edits or moves of `foundry.toml` or `soldeer.lock` are required. The
runner automatically builds with:

```sh
forge build --root "$PWD" --config-path config/demo/foundry.toml
```

The default artifact is:

```text
demo-artifacts/full-demo.json
```

To select another path, pass it after the script name. Relative paths are
resolved against `sdk/`:

```sh
cd sdk
bun run demo:full ../demo-artifacts/replay.json
cd ..
```

During execution, the runner prints build and chain-start messages followed by
16 numbered protocol steps, for example:

```text
[demo 01/16] Deploying and funding both local protocol environments
[demo 02/16] Preparing terms, secrets, locks, and exact commit authorizations
...
[demo 16/16] Marking both clients complete and validating final custody and payouts
```

Progress is written to standard output in green. After success, the runner
writes one machine-readable JSON summary as the final output line. Expect:

- `schema` equal to `quip-swap-full-demo.v1`;
- one nonzero `tradeId`;
- final states `[[31337,"Claimed"],[31338,"Claimed"]]`;
- `negativeControls` equal to `4`; and
- `artifact` equal to the resolved output path.

The artifact is written with owner-only permissions. It deliberately contains
fixed public test secrets and is marked `publicTestSecrets: true`. Never reuse
its secrets, nonces, signatures, terms, or keys outside the local demo.

## Expected protocol progression

The combined artifact records three separate boundaries: trusted-client state,
commit authorization, and on-chain settlement.

| Order | Client step | Expected result |
| ---: | --- | --- |
| 1 | `prepare` for Alice and Bob | Terms, locks, TradeID, and exact commit payloads are derived. |
| 2 | `pending` | Alice's commit is submitted; Bob remains disabled. |
| 3 | `included-non-final` | Alice's commit is included, but the non-finality warning remains and Bob remains disabled. |
| 4 | `final` | Alice's canonical commit satisfies the configured finality policy. |
| 5 | `secret-release` | `BobCommitSecret` crosses only into Bob's selected client boundary. |
| 6 | `bob-commit` | Bob's PQ-authorized, secret-gated commit is accepted. |
| 7 | `revealing-claim-final` | Bob's revealing claim is final and exposes the settlement preimage on-chain. |
| 8 | `final-claim-handoff` | The final claim is handed to a selected funded permissionless executor. |
| 9 | `completion` for Alice and Bob | Both local client states become complete. |

The authorization trace must contain exactly two accepted records in the order
Alice, Bob. The settlement trace must contain exactly four successful actions:
`alice-commit`, `bob-commit`, `revealing-claim`, and `final-claim`.

The four intentional invalid actions must all revert without changing wrapper
state, custody, balances, or nonce usability:

1. commit from a disallowed submitter;
2. Bob commit without `BobCommitSecret`;
3. Bob commit with the wrong `BobCommitSecret`;
4. final claim with the wrong settlement secret.

At completion both wrappers must be `Claimed`, wrapper token custody must be
zero, Bob's recipient must hold 10 chain-A demo tokens, and Alice's recipient
must hold 20 chain-B demo tokens.

## Run the two-operator console demo

The console path uses separate Alice and Bob directories and starts a new Bun
process for every command. Run these commands from `sdk/` in order:

### 0. Reset a previous manual run

Perform this reset before restarting a manual demo. Keep `DEMO_ROOT` set to
the previous run until its processes have been stopped. The runtime file is the
authority for which processes belong to that run; do not kill unrelated Anvil
processes by name or port.

- Stop only the Anvil processes recorded by the previous bootstrap.

```sh
jq -r '.startedPids[]' "$DEMO_ROOT/runtime/runtime.json" | xargs -r kill
```

- Confirm that the previous chain-31337 RPC endpoint is no longer reachable.
  This command is expected to report a connection failure.

```sh
cast block latest --rpc-url http://127.0.0.1:8545
```

- Confirm that the previous chain-31338 RPC endpoint is no longer reachable.
  This command is also expected to report a connection failure.

```sh
cast block latest --rpc-url http://127.0.0.1:8546
```

### 1. Start a clean manual run

- Select a new, timestamped demo root. This preserves the previous run's
  diagnostics while giving the new run clean chain and client state.

```sh
DEMO_ROOT="/tmp/interlock-v11-demo-$(date +%s)"
```

- Create the fresh demo root.

```sh
mkdir -p "$DEMO_ROOT"
```

Always select and create a fresh demo root before `bootstrap-local`.
`bootstrap-local` refuses to reuse an RPC endpoint from a previous run because
reusing it would preserve old chain state. The subsequent `init` commands
create clean, independent Alice and Bob client states.

- Start both local chains, deploy the contracts, and generate both runtime
  configurations.

```sh
bun run src/bin/quip-swap.ts bootstrap-local --party alice \
  --state-root "$DEMO_ROOT/runtime" \
  --config ../config/demo/console-bootstrap.json --json
```

- Set the path to Parties' generated runtime configurations.

```sh
ALICE_CONFIG="$DEMO_ROOT/runtime/alice.config.json"
BOB_CONFIG="$DEMO_ROOT/runtime/bob.config.json"
```

- Assign Parties private client-state directories.

```sh
ALICE_ROOT="$DEMO_ROOT/alice"
BOB_ROOT="$DEMO_ROOT/bob"
```

- Initialize Parties' client state.

```sh
bun run src/bin/quip-swap.ts init --party alice --state-root "$ALICE_ROOT" --config "$ALICE_CONFIG" --json
bun run src/bin/quip-swap.ts init --party bob --state-root "$BOB_ROOT" --config "$BOB_CONFIG" --json
```

The checked-in bootstrap profile fixes the initial local timestamp. Unlike the
automated replay, a manual run can take longer than the narrow deterministic
test windows, so derive its deadlines from the live chain time.

- Record the current chain-31337 timestamp as the base for all deadlines.

```sh
NOW=$(cast block latest --rpc-url http://127.0.0.1:8545 --field timestamp)
```

### 2. Negotiations

- Have Alice create terms with generous manual-operation windows and export
  the public offer.

```sh
jq -n --argjson now "$NOW" '{
  schema:"quip-swap-prepare-trade.v1",
  partyCommitmentDeadline:($now + 86400 | tostring),
  counterpartyCommitmentDeadline:($now + 172800 | tostring),
  partyClaimDeadline:($now + 864000 | tostring),
  counterpartyClaimDeadline:($now + 950400 | tostring),
  partyReclaimRelease:($now + 1209600 | tostring),
  counterpartyReclaimRelease:($now + 1123200 | tostring),
  partyAuthorizationExpiry:($now + 432000 | tostring),
  counterpartyAuthorizationExpiry:($now + 518400 | tostring)
}' |
  bun run src/bin/quip-swap.ts prepare-trade --party alice --state-root "$ALICE_ROOT" --config "$ALICE_CONFIG" --json
```

- Have Bob import Alice's public offer into his own client state.

```sh
bun run src/bin/quip-swap.ts import-offer --party bob --state-root "$BOB_ROOT" --config "$BOB_CONFIG" --json \
  < "$ALICE_ROOT/public/offer.json"
```

  Run `import-offer` only once. If the CLI says the exact offer is already
  imported, continue with `accept-trade`. If it says the offer is already
  imported and accepted, skip both commands and continue with
  `submit-alice-commit`.

- Have Bob validate and accept the imported trade.

```sh
bun run src/bin/quip-swap.ts accept-trade --party bob --state-root "$BOB_ROOT" --config "$BOB_CONFIG" --json
```

  Run `accept-trade` only once. If the CLI says the trade is already accepted,
  continue with `submit-alice-commit`.

- Combine Bob's acceptance with Alice's confirmation and submit Alice's funded
  commit on chain 31337.

```sh
jq -n --slurpfile acceptance "$BOB_ROOT/public/acceptance.json" \
  '{schema:"quip-swap-alice-commit.v1",confirmed:true,acceptance:$acceptance[0]}' |
  bun run src/bin/quip-swap.ts submit-alice-commit --party alice --state-root "$ALICE_ROOT" --config "$ALICE_CONFIG" --json
```

### 2. Alice.commit
- Have Alice observe that her commit exists but is not final yet.

```sh
bun run src/bin/quip-swap.ts observe-alice-commit --party alice --state-root "$ALICE_ROOT" --config "$ALICE_CONFIG" --json
```

- Have Bob independently observe Alice's still-non-final commit.

```sh
bun run src/bin/quip-swap.ts observe-alice-commit --party bob --state-root "$BOB_ROOT" --config "$BOB_CONFIG" --json
```

- Mine two additional blocks on chain 31337 to reach three confirmations.

```sh
cast rpc --rpc-url http://127.0.0.1:8545 anvil_mine 0x2
```

- Have Alice record that her commit is now final.

```sh
bun run src/bin/quip-swap.ts observe-alice-commit --party alice --state-root "$ALICE_ROOT" --config "$ALICE_CONFIG" --json
```

- Have Bob independently record that Alice's commit is now final.

```sh
bun run src/bin/quip-swap.ts observe-alice-commit --party bob --state-root "$BOB_ROOT" --config "$BOB_CONFIG" --json
```
### 3. Bob.commit

- Have Alice create Bob's private progression-secret handoff.

  ```sh
bun run src/bin/quip-swap.ts release-bob-secret --party alice --state-root "$ALICE_ROOT" --config "$ALICE_CONFIG" --json --yes \
  > "$DEMO_ROOT/release.json"
```

- Extract the handoff path without printing the secret.

```sh
BOB_HANDOFF=$(jq -r '.result.handoffPath' "$DEMO_ROOT/release.json")
```

- Pass the private handoff directly into Bob's client through standard input.

```sh
bun run src/bin/quip-swap.ts import-bob-secret --party bob --state-root "$BOB_ROOT" --config "$BOB_CONFIG" --json \
  < "$BOB_HANDOFF"
```


- Have Bob submit his funded commit on chain 31338.

  Confirm that this command returns `ok: true` and a transaction hash before
  running either `observe-bob-commit` command. Observation cannot reconstruct
  a submission that never produced Bob's local transaction journal.

  ```sh
bun run src/bin/quip-swap.ts submit-bob-commit --party bob --state-root "$BOB_ROOT" --config "$BOB_CONFIG" --json --yes
```

- Have Bob observe and validate his submitted commit.

```sh
bun run src/bin/quip-swap.ts observe-bob-commit --party bob --state-root "$BOB_ROOT" --config "$BOB_CONFIG" --json
```

- Have Alice independently observe and validate Bob's commit.

```sh
bun run src/bin/quip-swap.ts observe-bob-commit --party alice --state-root "$ALICE_ROOT" --config "$ALICE_CONFIG" --json
```
### 4. Alice.claim

- Have Alice reveal the settlement preimage by claiming Bob's asset on chain
  31338.

```sh
bun run src/bin/quip-swap.ts submit-revealing-claim --party alice --state-root "$ALICE_ROOT" --config "$ALICE_CONFIG" --json --yes
```

- Have Bob observe the revealing claim before it is final.

```sh
bun run src/bin/quip-swap.ts observe-reveal --party bob --state-root "$BOB_ROOT" --config "$BOB_CONFIG" --json
```

- Mine two additional blocks on chain 31338 to finalize the revealing claim.

```sh
cast rpc --rpc-url http://127.0.0.1:8546 anvil_mine 0x2
```

- Have Bob record the final reveal and recover its authenticated settlement
  preimage.

```sh
bun run src/bin/quip-swap.ts observe-reveal --party bob --state-root "$BOB_ROOT" --config "$BOB_CONFIG" --json
```
### 5. Bob.claim

- Have Bob use the preimage to claim Alice's asset on chain 31337.

```sh
bun run src/bin/quip-swap.ts submit-final-claim --party bob --state-root "$BOB_ROOT" --config "$BOB_CONFIG" --json --yes
```

- Show Alice's independently reconstructed cross-chain status.

```sh
bun run src/bin/quip-swap.ts status --party alice --state-root "$ALICE_ROOT" --config "$ALICE_CONFIG" --json
```

- Show Bob's independently reconstructed cross-chain status.

```sh
bun run src/bin/quip-swap.ts status --party bob --state-root "$BOB_ROOT" --config "$BOB_CONFIG" --json
```

Both status commands must report `success`, `complete: true`, and `Claimed`
on both chains. The chain-31337 recipient balance must be 10 demo tokens, the
chain-31338 recipient balance 20 demo tokens, and both wrapper balances zero.

### 6. cleanups
- Stop only the Anvil processes recorded by this run.

```sh
jq -r '.startedPids[]' "$DEMO_ROOT/runtime/runtime.json" | xargs -r kill
```


## Automated replay

For an automated replay of the same separate-process flow:

- Run the complete console demo and compare it with `demo:full`.

```sh
bun run demo:console
```

It writes `../demo-artifacts/console-demo.json` and requires the same TradeID,
Alice/Bob authorization decisions, four settlement transitions, terminal
`(Claimed, Claimed)` state, fixed recipient balances, empty wrapper custody,
and redacted transaction journals as `demo:full`.

## Inspect the artifact

The file is ordinary JSON. Useful top-level sections are:

- `deployment`: chain IDs, deployed addresses, policies, funding, and approvals;
- `clientTrace`: redacted trusted-client transitions and warnings;
- `authorizationTrace`: verifier, gateway, submitter, nonce, expiry, and result;
- `settlementTrace`: transactions, events, gates, state transitions, and holdings;
- `negativeControls`: expected errors and byte-equivalent before/after snapshots;
- `deterministicSecrets`: public local-demo fixtures used for replay.

Normal operator surfaces are `clientTrace` and the runner's summary. They must
not contain either preimage. The full artifact contains them only because this
is an explicitly unsafe deterministic local demo.

## Deterministic replay

Run the demo again with a different output file:

```sh
cd sdk
bun run demo:full ../demo-artifacts/replay.json
cd ..
```

Fresh Anvil deployment addresses and transaction hashes are execution metadata
and may differ. Deterministic replay means the same terms, protocol identifiers,
client transition sequence, authorization decisions, settlement actions,
negative-control results, final states, and asset outcomes. The focused
two-chain test validates this logical fingerprint while ignoring volatile
transaction hashes:

```sh
cd sdk
bun run test:cross-chain
cd ..
```

## Failure and recovery

- **Build fails:** stop. From the repository root, reproduce it with
  `forge build --root "$PWD" --config-path config/demo/foundry.toml`; no chains
  or artifact should be treated as a completed run.
- **Soldeer reports `StripPrefixError`:** verify that the runner contains the
  demo `--config-path` build argument and that `config/demo/foundry.toml` has no
  `[dependencies]` section. Do not edit the canonical dependency files merely
  to run the demo.
- **A local chain cannot start:** ensure `anvil` is on `PATH` and local process
  creation is permitted. The runner uses free ports; no fixed RPC port is
  required.
- **Failure before Alice's commit:** discard the run and its local states. No
  escrow should exist.
- **Alice pending or included but non-final:** do not release
  `BobCommitSecret` and do not submit Bob's commit. Wait for canonical finality;
  after a reorganization, roll the observation back and warn the operator.
- **Alice final but progression not released:** retry the client-boundary
  transfer only to Bob's selected permitted submitter.
- **Bob committed but no revealing claim:** monitor the claim window and prepare
  permissionless reclaim assistance for Bob's fixed reclaim recipient.
- **Revealing claim observed but non-final:** do not treat its secret as final
  client state. Roll back on reorganization and continue monitoring.
- **Revealing claim final:** immediately retry or fee-bump the final claim using
  a selected funded permissionless executor.
- **Final claim cannot land before its window closes:** enter recovery and
  assist the fixed reclaim recipient after `reclaimRelease`.
- **A negative control changes state:** treat the run as a protocol failure;
  preserve the artifact and do not proceed as if the demo succeeded.
- **Runner exits unexpectedly:** its `finally` block normally stops both Anvil
  processes. Because the chains are ephemeral, restart the complete demo rather
  than attempting to hydrate on-chain state from a partial run.

The runner writes the artifact only after the complete flow and all validation
checks succeed. A missing artifact therefore means the run is incomplete; an
older artifact at the same path must not be mistaken for the failed run.

## Verification checkpoint

Before handing the prototype to another operator, run:

```sh
forge build --root "$PWD" --config-path config/demo/foundry.toml
cd sdk
bun run typecheck
bun run test
bun run build
bun run test:cross-chain
cd ..
```

All commands must pass, and a final `bun run demo:full` artifact must match the
terminal states and asset outcomes described above.
