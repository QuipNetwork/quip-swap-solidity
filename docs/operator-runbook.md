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
| 2 | `pending` | Alice's commit publishes `BobCommitSecret`; Bob remains disabled while it is non-final. |
| 3 | `included-non-final` | Alice's commit is included, but the non-finality warning remains and Bob remains disabled. |
| 4 | `final` | Alice's canonical commit satisfies the configured finality policy. |
| 5 | `on-chain-secret-observed` | Bob verifies the preimage from Alice's finalized commit and enables his commit path. |
| 6 | `bob-commit` | Bob's PQ-authorized, secret-gated commit is accepted. |
| 7 | `revealing-claim-final` | Alice's revealing claim is final and exposes the settlement preimage on-chain. |
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

The protocol commands below use `--summary-json`. It reports the action result,
asset changes, locks, and only preimages already published by a successful
on-chain submission. Use `--json` instead when the complete automation envelope
is required.


#### 2.1. Alice create terms

Alice creates terms with generous manual-operation windows and export the public offer.

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
  bun run src/bin/quip-swap.ts prepare-trade --party alice --state-root "$ALICE_ROOT" --config "$ALICE_CONFIG" --summary-json
```

#### 2.2. Bob imports terms

Bob imports Alice's public offer into his own client state.

```sh
bun run src/bin/quip-swap.ts import-offer --party bob --state-root "$BOB_ROOT" --config "$BOB_CONFIG" --summary-json \
  < "$ALICE_ROOT/public/offer.json"
```

  Run `import-offer` only once. If the CLI says the exact offer is already
  imported, continue with `accept-trade`. If it says the offer is already
  imported and accepted, skip both commands. Alice's commit is independent of
  this Bob-local review state.


#### 2.3. Bob validates terms

Bob validates the imported trade.

```sh
bun run src/bin/quip-swap.ts accept-trade --party bob --state-root "$BOB_ROOT" --config "$BOB_CONFIG" --summary-json
```

  Run `accept-trade` only once. If the CLI says the trade is already accepted, continue with Bob's later observation and commit steps. This acceptance is a
  local client decision and is never transferred to Alice or submitted on-chain.


### 3. Alice.commit

#### 3.1. submit-alice-commit
Alice submits her funded commit on chain 31337 using the same canonical terms held by both parties. The transaction also verifies and publishes the trade-bound Bob-commit preimage atomically with Alice's escrow.

```sh
jq -n '{schema:"quip-swap-alice-commit.v1",confirmed:true}' |
  bun run src/bin/quip-swap.ts submit-alice-commit --party alice --state-root "$ALICE_ROOT" --config "$ALICE_CONFIG" --summary-json
```

#### 3.2. Alice -> observe-alice-commit

Alice observes that her commit exists but is not final yet.
```sh
bun run src/bin/quip-swap.ts observe-alice-commit --party alice --state-root "$ALICE_ROOT" --config "$ALICE_CONFIG" --summary-json
```

#### 3.3. Bob -> observe-alice-commit

Bob independently observes Alice's still-non-final commit and verify its published Bob-commit preimage. Bob's client records the warning but does not enable that preimage for submission yet.

```sh
bun run src/bin/quip-swap.ts observe-alice-commit --party bob --state-root "$BOB_ROOT" --config "$BOB_CONFIG" --summary-json
```

#### 3.4. Mine Alice confirmation blocks

Mine two additional blocks on chain 31337 to reach three confirmations.

```sh
cast rpc --rpc-url http://127.0.0.1:8545 anvil_mine 0x2
```

#### 3.5. Alice observes her commit's finality

Alice records that her commit is now final.

```sh
bun run src/bin/quip-swap.ts observe-alice-commit --party alice --state-root "$ALICE_ROOT" --config "$ALICE_CONFIG" --summary-json
```
#### 3.6. Bob observes Alice commit's finality

Bob independently records that Alice's commit is now final. This command extracts the authenticated on-chain preimage into Bob's private workspace and enables `submit-bob-commit`.

```sh
bun run src/bin/quip-swap.ts observe-alice-commit --party bob --state-root "$BOB_ROOT" --config "$BOB_CONFIG" --summary-json
```
### 4. Bob.commit

#### 4.1. submit-bob-commit

Bob submits his funded commit on chain 31338.

```sh
bun run src/bin/quip-swap.ts submit-bob-commit --party bob --state-root "$BOB_ROOT" --config "$BOB_CONFIG" --summary-json --yes
```

#### 4.2. Bob observe-bob-commit

Bob observes and validates his submitted commit.

```sh
bun run src/bin/quip-swap.ts observe-bob-commit --party bob --state-root "$BOB_ROOT" --config "$BOB_CONFIG" --summary-json
```

#### 4.3. Alice observe-bob-commit

Alice independently observes and validates Bob's commit.

```sh
bun run src/bin/quip-swap.ts observe-bob-commit --party alice --state-root "$ALICE_ROOT" --config "$ALICE_CONFIG" --summary-json
```
### 5. Alice.claim


#### 5.1. submit-revealing-claim
Alice reveals the settlement preimage by claiming Bob's asset on chain
  31338.

```sh
bun run src/bin/quip-swap.ts submit-revealing-claim --party alice --state-root "$ALICE_ROOT" --config "$ALICE_CONFIG" --summary-json --yes
```

#### 5.2. Bob observes the non-final reveal

Bob observes the revealing claim before it is final.

```sh
bun run src/bin/quip-swap.ts observe-reveal --party bob --state-root "$BOB_ROOT" --config "$BOB_CONFIG" --summary-json
```

#### 5.3. Mining

Mine two additional blocks on chain 31338 to finalize the revealing claim.

```sh
cast rpc --rpc-url http://127.0.0.1:8546 anvil_mine 0x2
```

#### 5.4. Bob observe-reveal

Bob records the final reveal and recovers its authenticated settlement preimage.

```sh
bun run src/bin/quip-swap.ts observe-reveal --party bob --state-root "$BOB_ROOT" --config "$BOB_CONFIG" --summary-json
```

### 6. Bob.claim


#### 6.1. Bob submit-final-claim
Bob uses the preimage to claim Alice's asset on chain 31337.

```sh
bun run src/bin/quip-swap.ts submit-final-claim --party bob --state-root "$BOB_ROOT" --config "$BOB_CONFIG" --summary-json --yes
```

#### 6.2. Alice checks status

Show Alice's independently reconstructed cross-chain status.

```sh
bun run src/bin/quip-swap.ts status --party alice --state-root "$ALICE_ROOT" --config "$ALICE_CONFIG" --summary-json
```
#### 6.3. Bob checks status

Show Bob's independently reconstructed cross-chain status.

```sh
bun run src/bin/quip-swap.ts status --party bob --state-root "$BOB_ROOT" --config "$BOB_CONFIG" --summary-json
```

Both status commands must report `success`, `complete: true`, and `Claimed`
on both chains. The chain-31337 recipient balance must be 10 demo tokens, the
chain-31338 recipient balance 20 demo tokens, and both wrapper balances zero.

### 7. cleanups
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
- **Alice pending or included but non-final:** Alice's transaction has already
  published `BobCommitSecret`, but Bob's client must not enable or submit it.
  Wait for canonical finality; after a reorganization, roll the observation
  back and warn the operator.
- **Alice final but Bob has not enabled progression:** rerun Bob's
  `observe-alice-commit` against the canonical Alice receipt; never bypass the
  finality check or import a preimage from an unauthenticated source.
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
bash scripts/run-clean-foundry-build.sh
forge fmt --check
forge test
bash scripts/run-current-coverage.sh
cd sdk
bun run generate:abi
bun run typecheck
bun run test
bun run build
bun run test:integration
bun run test:cross-chain
bun run demo:same-chain
bun run demo:cross-chain:recovery
bun run demo:full
bun run demo:console
cd ..
```

All commands must pass, and a final `bun run demo:full` artifact must match the
terminal states and asset outcomes described above.

## Run and replay the current same-chain demo

This is the standalone demonstration of the current v1.1
`SameChainWrapper`. It is separate from `bun run smoke`, which exercises the
legacy Omnibus implementation and is not evidence for the current wrapper.

- Enter the SDK directory so package commands and relative artifact paths resolve
  consistently.

```sh
cd sdk
```

- Run the current same-chain success, rejection, and recovery flows and write the
  default owner-only artifact at `../demo-artifacts/same-chain-demo.json`.

```sh
bun run demo:same-chain
```

- Alternatively, run the same deterministic logical flow and select a replay
  artifact path explicitly.

```sh
bun run demo:same-chain ../demo-artifacts/same-chain-replay.json
```

The runner prints eleven green progress steps. Its final summary must report
three ordered transitions
`Unused -> PartyCommitted -> BothCommitted -> Claimed`, fourteen rejected
controls, both `party-only-reclaim` and `both-reclaim`, a successful atomic
rollback check, and `secretsPersisted: false`.

The versioned `quip-swap-same-chain-demo.v1` artifact contains deployment
metadata, canonical terms and TradeID, the settlement lock, redacted accepted
authorization decisions, ordered receipt summaries, custody snapshots and
balance deltas, negative controls, recovery outcomes, and the terminal result.
It excludes settlement preimages, PQ signatures, private keys, PQ public-key
bytes or hashes, and recovery-key material.

- Validate the default persisted artifact without starting Anvil or executing
  another swap.

```sh
bun run demo:same-chain:validate ../demo-artifacts/same-chain-demo.json
```

- Validate an explicitly named replay artifact in the same way.

```sh
bun run demo:same-chain:validate ../demo-artifacts/same-chain-replay.json
```

Validation recomputes the TradeID from the persisted terms and rejects missing
or reordered transitions, mismatched protocol identifiers, incomplete
authorization and rejection evidence, malformed recovery outcomes, nonterminal
success traces, terminal custody mismatches, and forbidden sensitive fields.
Transaction hashes may differ between fresh Anvil runs; the ordered logical
transitions, authorization decisions, controls, recovery outcomes, and final
custody must agree.

## Run the two-chain recovery demo

- Enter the SDK directory so the package command resolves its local toolchain.

```sh
cd sdk
```

- Run four snapshot-isolated live recovery branches on chains 31337 and 31338.

```sh
bun run demo:cross-chain:recovery
```

The command demonstrates `(Reclaimed, Reclaimed)` when neither party claims,
`(Reclaimed, Claimed)` when the revealing claim lands but the final claim is
omitted, and both claim-winning and reclaim-winning local terminal races. It
also verifies that dropped, replaced, reverted, and reorganized observations do
not advance trusted finality. The redacted artifact is written to
`../demo-artifacts/cross-chain-recovery-demo.json`; pass another path as the
first argument to select a different output file.
