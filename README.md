# Quip Swap

Non-custodial, hashlocked same-chain and cross-chain swaps built around the **Omnibus** singleton contract, with ERC-7913 keyed commit authorization.

## Repository layout

```text
src/                  Production contracts (Omnibus, TermsLib, interfaces)
test/                 Foundry test suite (behaviors, scenarios, attack tests,
                      harnesses, mocks, real-verifier integration)
script/               Deployment scripts (Omnibus via CREATE3;
                      constructor (address initialOwner) from OMNIBUS_OWNER)
sdk/                  TypeScript SDK (Bun + Viem + Vitest) — see sdk/README.md
```

## Protocol summary

- `Omnibus` is a singleton (Ownable2Step, ERC-721/1155 receiver) holding hashlocked escrows.
- A swap is two `Terms` (one per side), each with three lifecycle timestamps that **strictly interleave** across sides. The side with the earlier `commitmentDeadline` is the proposer and commits first.
- All three entry points are **permissionless**. `commit` authenticates its PAYLOAD instead of its caller: every commit carries a `CommitAuth {signer, signature}` where `signer` is an ERC-7913 keyed identity — `verifier(20 bytes) ‖ key` — checked against an owner-managed active-verifier list; any blob of 20 bytes or fewer (including bare addresses) is rejected as malformed. The signature covers a raw tagged digest binding chainid, the Omnibus address, the lock, both sides' terms, and the identity itself.
- The signature is a **soft guard**: it proves the declared identity endorsed exactly this payload; it does not gate WHICH identity may post a side. Clients that care who posted the counterpart side verify the `signer` blob from the `Commitment` event off-chain.
- **Funding model:** in every route the transaction SENDER funds the committed leg + fee; the identity only authorizes. "Relayed" means the sender pays.
- `claim` (settlement, reveals the secret) and `reclaim` (post-deadline recovery) are unchanged and identity-free — claim is secret-gated, reclaim recipients are terms-pinned.
- All timing windows are half-open `[lower, upper)`.
- **Optimistic mode:** each side's `Terms` carries a `bool optimistic`. When BOTH sides sign `true` (bilateral opt-in — mixed flags revert `OptimismMismatch`), the LOWER bounds of the commit and claim windows are waived: no forced sequencing waits, either side may commit first, and a same-chain swap can commit + commit + claim in a single block. **What is never waived:** the claim upper bounds and `reclaimRelease` — the reaction gap that prevents cross-chain reveal-then-reclaim theft. The interleaved deadline schedule stays required and acts as the timed fallback if the fast path stalls. ⚠️ Cross-chain takers: with the forced waits gone, off-chain commitment verification and watching for the reveal are your only protections — a negligent taker forfeits both legs (see `TIMING_MODEL.md` §7).

## SVM (Solana) compatibility

Token and recipient identifiers are **bytes32** universal identifiers (EVM addresses low-20-byte aligned), so a swap leg on Solana can carry 32-byte pubkeys; the EVM side and SDK are implemented, the Solana program is future work. [`SVM_COMPATIBILITY.md`](SVM_COMPATIBILITY.md) is the canonical spec: addressing and chain-id conventions, what's supported on Solana, and the ⚠️ **token due-diligence** section every party should read (a token that escrows fine but becomes untransferable at claim time — blacklists, pauses, transfer hooks — can make a swap one-sided; this applies on EVM today).

## Smart contracts (Foundry)

```shell
forge build       # build contracts
forge test        # run the Solidity test suite
forge fmt --check # check formatting
```

Or via make: `make build`, `make test`, `make fmt-check`, `make coverage`. Run `make help` for everything.

## TypeScript SDK

The `sdk/` directory contains a publishable TypeScript SDK providing typed access to Omnibus — asset/terms builders, universal (bytes32) address helpers + SVM chain constants, Solidity-exact hashing, secret generation, a preflighted client, approval planning, event decoding, and same-chain / cross-chain workflow helpers.

> Use client-bound receipt helpers or pass the Omnibus address when decoding receipts (`client.waitForReceipt(hash)` or `waitForOmnibusReceipt(..., {address})`); the raw `decode*Events` decoders are low-level and expect pre-scoped logs.

```shell
make sdk-install            # bun install
make sdk-generate           # forge build + generate the ABI
make sdk-typecheck          # strict tsc
make sdk-test               # unit + mocked-client tests (no chain)
make sdk-test-integration   # single-chain Anvil integration + Solidity/TS
                            # differential tests (starts its own Anvil)
make sdk-test-cross-chain   # two-chain end-to-end tests (slower; two Anvils)
make sdk-build              # build the dist/ bundle
```

See [`sdk/README.md`](sdk/README.md) for the full SDK guide (timing model, commit authorization, cross-chain coordination, buffer selection, error handling).

## Full verification

```shell
make check   # fmt-check + forge build + forge test + SDK typecheck/tests/build
             # + single-chain integration tests
             # (cross-chain E2E excluded for speed: make sdk-test-cross-chain)
```

## Deployment

Per-chain order: **Deployer → Omnibus (`make deploy`)**. Commit authorization uses an ERC-7913 verifier; verifier deployment is a separate concern, and activation is a post-deploy owner action: `setVerifierActivity(verifier, true)`, checked via `verifierActive(verifier)`. Env: `DEPLOYER_PK`, `DEPLOYER_ADDRESS`, `OMNIBUS_OWNER` (non-zero). Omnibus deploys via CREATE3 (salt `QUIP:Omnibus:v1.0.0-alpha.1`), so its address is independent of constructor args and identical across chains. Salts follow semver: prerelease suffixes (`-alpha.N`, `-beta.N`, `-rc.N`) are testnet deploys; the bare release (`v1.0.0`) is reserved for mainnet. Prior deployments persist at their old addresses.
