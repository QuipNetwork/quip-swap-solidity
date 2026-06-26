# Quip Swap SDK

A TypeScript SDK for the Quip Swap **Omnibus** protocol — hashlocked same-chain and cross-chain swaps of Native / ERC-20 / ERC-721 / ERC-1155 assets. Built on [viem](https://viem.sh) (a peer dependency), it layers pure-protocol helpers (asset/terms builders, Solidity-exact hashing, window math, secret generation — no RPC), a typed client (reads plus preflighted writes with node-side gas estimation), and workflow helpers (plan / validate / status; they never submit transactions). By design it does not custody keys or store secrets, and it never replaces on-chain enforcement (treat it as a convenience layer over the contracts, not a security guarantee). **For integration instructions and end-to-end walkthroughs, see [`USAGE.md`](USAGE.md);** for protocol theory see the root [`../README.md`](../README.md), [`../ARCHITECTURE.md`](../ARCHITECTURE.md), and [`../QUIP_LIFECYCLE.md`](../QUIP_LIFECYCLE.md).

> **⚠️ Before integrating, read the [DANGER — ways to lose funds](USAGE.md#danger) section.** Cross-chain takers can lose funds by skipping commitment verification; overriding the default buffers too tight can forfeit windows.

---

## Requirements

- **[Bun](https://bun.sh)** — the SDK's package manager and script/test runner (`bun.lock` is committed). All `bun run …` scripts below assume it.
- **[Foundry](https://book.getfoundry.sh)** (`forge` + `anvil`) — required for ABI generation and for the integration / cross-chain / smoke suites. Not needed for the unit and mocked-client tests.
- **viem `^2.0.0`** — a **peer dependency**; the consuming app supplies it. (Pinned to `^2.21.0` in dev.)
- The package is **ESM-only** (`"type": "module"`). No `engines` field is declared; build/test is done with Bun and TypeScript `^5.7`.

## Install / build

```bash
cd sdk
bun install            # install dependencies
bun run build          # bundle to dist/ (tsup → dist/index.js + dist/index.d.ts)
bun run check          # typecheck + unit/mocked tests + build (the standard gate)
```

`bun run check` runs `tsc --noEmit`, then `vitest run test/unit test/mocked-client`, then `tsup` — no chain required.

## ABI generation

The Omnibus ABI is generated from the Foundry build artifact and is **never hand-edited**:

```bash
forge build            # at the repository ROOT — produces out/Omnibus.sol/Omnibus.json
cd sdk
bun run generate:abi   # reads that artifact, writes src/generated/omnibusAbi.ts
```

`generate:abi` (`scripts/generate-abi.ts`) reads `out/Omnibus.sol/Omnibus.json`, emits `src/generated/omnibusAbi.ts` as **ABI-only** (no bytecode/metadata), `as const`, and deterministic (stable key order, fixed indentation). It exits non-zero with a clear message if the artifact is missing or malformed. **Re-run it after any contract change**; never edit the generated file by hand. From the repo root, `make sdk-generate` runs `forge build` then this script.

## Architecture (brief)

The public surface (`src/index.ts`) is three layers — import only what you need:

- **Pure protocol** (`hashing`, `terms`, `windows`, `assets`, `secrets`, `types`) — asset/terms builders and validators, the half-open `[lower, upper)` window math, Solidity-exact `digestTerms` / `generateLock`, and CSPRNG secret generation. **No RPC**; deterministic and unit-testable in isolation.
- **Client** (`client`, `gas`, `approvals`, `receipts`, `events`, `errors`, `deployments`) — `createOmnibusClient({address, publicClient, walletClient?})` exposes typed reads and **preflighted writes** (`commit` / `claim` / `reclaim`, plus owner-only `admin.*`): structural/pairing/window/chain-id/quip-wallet-gate/lock-state checks and a balance check run before gas estimation and a safety-buffered submission. Plus approval planning, receipt decoding, address-scoped event queries, and a single `QuipSwapError` type.
- **Workflows** (`workflows/sameChain`, `workflows/crossChain`, `buffers`) — `planSameChainSwap` / `getSameChainSwapStatus` and `validateCrossChainSchedule` / `verifyRemoteCommitment`. These **plan, validate, and report only — they never submit transactions.** Both validators enforce **schedule buffers** (minimum gap between lifecycle timestamps) with tunable defaults (`DEFAULT_BUFFERS`, `DEFAULT_SAME_CHAIN_BUFFER_SECONDS`, `DEFAULT_CROSS_CHAIN_BUFFER_SECONDS`); the contract checks interleaving order but never gap size, so this is the only place tight windows are caught — see USAGE → "Schedule buffers".

See [`USAGE.md`](USAGE.md) for how to use each layer.

## Running the tests

The suites live under `sdk/test/`. Unit and mocked-client tests are pure (no chain); integration, cross-chain, and smoke need **Foundry** and **start/stop their own Anvil nodes** (no manual node startup). Vitest runs with `fileParallelism: false` because the on-chain suites warp a shared block clock forward.

| Suite | What it covers | Command | Needs Foundry/Anvil |
| --- | --- | --- | --- |
| **unit** (`test/unit/`) | Pure protocol logic — hashing, asset/terms/pairing validation, window math, gas multiplier math, secret generation, and cross-chain schedule validation. No RPC. | `bun run test:unit` | No |
| **mocked-client** (`test/mocked-client/`) | Client orchestration against a hand-built fake viem client — argument shaping, exact `msg.value`, gas buffering, read→estimate→write ordering, and error-code mapping. Does **not** prove ABI-encoding equivalence (that's the differential suite). | `bun run test:mocked` | No |
| **integration** (`test/integration/omnibus.test.ts`) | Full commit/claim/reclaim lifecycle on a single Anvil node — deploys `QuipFactoryMock` + `Omnibus` + mock ERC-20/721/1155 tokens, registers wallets, and asserts real settlement with balance deltas (incl. dual-leg and reclaim-from-Free). | `bun run test:integration` | Yes (1 Anvil) |
| **differential** (`test/integration/differential.test.ts`) | Solidity↔TS oracle: TypeScript `digestTerms` / `digestTermsCanonically` / `generateLock` / `totalNative` / pairing / `enforceWithin` compared byte-for-byte against deployed `TermsLibHarness` / `OmnibusHarness`. **Why it exists:** a digest divergence would silently break real swaps (`TermsMismatch`). Runs as part of the integration runner. | `bun run test:integration` | Yes (1 Anvil) |
| **cross-chain** (`test/cross-chain/`) | Two-chain end-to-end coordination across two Anvil nodes (chain IDs 31337 / 31338) — role assignment, buffers, `verifyRemoteCommitment`, and the secret-reveal handoff. | `bun run test:cross-chain` | Yes (2 Anvils) |
| **smoke** (`scripts/smoke.ts`) | A fast end-to-end health check: drives one same-chain and one cross-chain swap **through the workflow layer** (`planSameChainSwap` + `getSameChainSwapStatus`, then `validateCrossChainSchedule` + `verifyRemoteCommitment`) against two Anvils. Fail-fast: prints `SMOKE FAILED at step N` and exits non-zero; otherwise `SMOKE PASSED`. Standalone script, not a vitest file. | `bun run smoke` | Yes (2 Anvils) |

`test/helpers/` (`anvil`, `chain`, `fixtures`) is shared test infrastructure, not a suite, and is not part of the SDK's exported surface.

**Aggregate commands**

```bash
# SDK package scripts (run inside sdk/)
bun run test          # unit + mocked-client (the default `test` script)
bun run check         # typecheck + test + build

# From the repository ROOT, via the Makefile:
make sdk-install            # bun install
make sdk-generate           # forge build + generate the ABI
make sdk-typecheck          # strict tsc --noEmit
make sdk-test               # unit + mocked-client (no chain)
make sdk-test-integration   # single-Anvil integration + differential
make sdk-test-cross-chain   # two-Anvil end-to-end
make sdk-build              # build dist/
make check                  # full repo gate: fmt-check + forge build/test
                            # + SDK typecheck/test/build + sdk-test-integration
                            # (cross-chain excluded for speed — run it separately)
```

`make check` deliberately excludes the two-Anvil cross-chain suite; run `make sdk-test-cross-chain` (or `bun run test:cross-chain`) on its own. Neither `bun run check` nor `make check` runs the `smoke` script — invoke `bun run smoke` directly as a pre-push gate.

## Project layout

```text
sdk/
├── src/
│   ├── index.ts            Public entrypoint (re-exports the surface below)
│   ├── types.ts            AssetType, LockState, Asset, Terms, Hex32, SecretLockPair
│   ├── assets.ts           Asset builders + validateAsset + totalNative
│   ├── terms.ts            createTerms, validateTerms/validateTermPairing, proposedBy
│   ├── windows.ts          Half-open [lower,upper) window helpers + validators
│   ├── hashing.ts          Solidity-exact digestTerms / digestTermsCanonically / generateLock
│   ├── secrets.ts          generateSecret (CSPRNG), secretToPair
│   ├── client.ts           createOmnibusClient — typed reads + preflighted writes + admin
│   ├── gas.ts              Gas estimation, multiplier clamp, balance preflight, TxOptions
│   ├── approvals.ts        planApprovals / submitApproval (ERC-20/721/1155)
│   ├── receipts.ts         waitForOmnibusReceipt (+ TRANSACTION_REVERTED)
│   ├── events.ts           decode*/get*/watch event helpers
│   ├── errors.ts           QuipSwapError + QuipSwapErrorCode
│   ├── deployments.ts      knownDeployments + resolveDeployment (Create3 default, override)
│   ├── workflows/
│   │   ├── sameChain.ts    planSameChainSwap, getSameChainSwapStatus
│   │   └── crossChain.ts   validateCrossChainSchedule, verifyRemoteCommitment
│   └── generated/
│       └── omnibusAbi.ts   GENERATED from Foundry — do not edit
└── test/
    ├── unit/               Pure protocol tests (no chain)
    ├── mocked-client/      Client orchestration with a fake viem client
    ├── integration/        Single-Anvil lifecycle + Solidity/TS differential
    ├── cross-chain/        Two-Anvil end-to-end
    └── helpers/            Shared Anvil/chain/fixture infrastructure
```

## Not yet available

Stated honestly so nothing here is mistaken for shipped:

- **Published package.** `@quip.network/quip-swap-sdk` (v`0.1.0`, `UNLICENSED`) is **not yet published to a registry** — install-from-npm does not work yet. Consume it from this repo (built `dist/`) or your own workspace link until it is.
- **Deployment registry addresses.** Omnibus deploys via Create3 (one canonical address across all chains), so the SDK ships that address gated to the chains where it is verified, exposed through `resolveDeployment` / `createOmnibusClient`. 
- **Packaging smoke test.** There is no automated `npm pack` / tarball-resolves-exports test; `bun run build` produces `dist/` but no suite imports the built artifact.
