# Quip Swap

Non-custodial, hashlocked same-chain and cross-chain swaps built around the **Omnibus** singleton contract, with multi-scheme commit authorization (EOA, ERC-1271, ERC-7913 post-quantum keyed identities).

## Repository layout

```text
src/                  Production contracts (Omnibus, TermsLib, interfaces)
test/                 Foundry test suite (behaviors, scenarios, attack tests,
                      harnesses, mocks, real-verifier integration)
script/               Deployment scripts (ShrincsVerifier + Omnibus via CREATE3;
                      Omnibus constructor (address initialOwner,
                      address[] initialVerifiers) from OMNIBUS_OWNER; the
                      verifier address is predicted from its salt)
sdk/                  TypeScript SDK (Bun + Viem + Vitest) — see sdk/README.md
```

## Protocol summary

- `Omnibus` is a singleton (Ownable2Step, ERC-721/1155 receiver) holding hashlocked escrows.
- A swap is two `Terms` (one per side), each with three lifecycle timestamps that **strictly interleave** across sides. The side with the earlier `commitmentDeadline` is the proposer and commits first.
- All three entry points are **permissionless**. `commit` authenticates its PAYLOAD instead of its caller: every commit carries a `CommitAuth {signer, signature}` where `signer` is an identity blob routed by shape — a 20-byte address (self-auth when it IS `msg.sender`, otherwise EOA `ecrecover` for codeless accounts or ERC-1271 `isValidSignature` for accounts with code), or `verifier(20 bytes) ‖ key` for ERC-7913 keyed identities (post-quantum SHRINCS) checked against an owner-managed verifier allowlist. The signature covers a raw tagged digest binding chainid, the Omnibus address, the lock, both sides' terms, and the identity itself.
- The signature is a **soft guard**: it proves the declared identity endorsed exactly this payload; it does not gate WHICH identity may post a side. Clients that care who posted the counterpart side verify the `signer` blob from the `Commitment` event off-chain.
- **Funding model:** in every route the transaction SENDER funds the committed leg + fee; the identity only authorizes. "Relayed" means the sender pays.
- `claim` (settlement, reveals the secret) and `reclaim` (post-deadline recovery) are unchanged and identity-free — claim is secret-gated, reclaim recipients are terms-pinned.
- All timing windows are half-open `[lower, upper)`.

## Smart contracts (Foundry)

```shell
forge build       # build contracts
forge test        # run the Solidity test suite
forge fmt --check # check formatting
```

Or via make: `make build`, `make test`, `make fmt-check`, `make coverage`. Run `make help` for everything.

## TypeScript SDK

The `sdk/` directory contains a publishable TypeScript SDK providing typed access to Omnibus — asset/terms builders, Solidity-exact hashing, secret generation, a preflighted client, approval planning, event decoding, and same-chain / cross-chain workflow helpers.

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

Per-chain order is **cross-repo**: **Deployer → ShrincsVerifier (deployed by hashsigs-solidity, the artifact's owner) → Omnibus (`make deploy`)**. The verifier is a trustless singleton consumed as a pinned `(address, runtime codehash)` pair in `script/Constants.sol`, sourced from hashsigs' `RELEASES.md`; `DeployOmnibus` verifies `verifier.codehash` against the pin (which subsumes existence) and constructs `Omnibus(initialOwner, [verifier])` — trusted from genesis, post-asserted via `trustedVerifiers(verifier)`. Env: `DEPLOYER_PK`, `DEPLOYER_ADDRESS`, `OMNIBUS_OWNER` (non-zero). Omnibus deploys via CREATE3 (salt `QUIP:Omnibus:V2.0`), so its address is independent of constructor args and identical across chains; the V1.0 Omnibus persists on testnets at its old address. A verifier release changes both pinned constants together in one reviewed diff.
