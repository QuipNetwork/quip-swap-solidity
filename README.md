# Quip Swap

Non-custodial, hashlocked same-chain and cross-chain swaps between QuipWallets, built around the **Omnibus** singleton contract.

## Repository layout

```text
src/                  Production contracts (Omnibus, TermsLib, interfaces)
test/                 Foundry test suite (behaviors, scenarios, attack tests,
                      harnesses, mocks)
script/               Deployment scripts (NOTE: currently stale — they encode a
                      one-argument constructor; the active Omnibus constructor
                      is (address initialOwner, address quipFactory))
sdk/                  TypeScript SDK (Bun + Viem + Vitest) — see sdk/README.md
```

## Protocol summary

- `Omnibus` is a singleton (Ownable2Step, ERC-721/1155 receiver) holding hashlocked escrows.
- A swap is two `Terms` (one per side), each with three lifecycle timestamps that **strictly interleave** across sides. The side with the earlier `commitmentDeadline` is the proposer and commits first.
- `commit` is gated to factory-deployed QuipWallets (`QUIP_FACTORY.vaultIdOf(msg.sender) != 0`); `claim` (settlement, reveals the secret) and `reclaim` (post-deadline recovery) are permissionless.
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

See [`sdk/README.md`](sdk/README.md) for the full SDK guide (timing model, QuipWallet gating, cross-chain coordination, buffer selection, error handling).

## Full verification

```shell
make check   # fmt-check + forge build + forge test + SDK typecheck/tests/build
             # + single-chain integration tests
             # (cross-chain E2E excluded for speed: make sdk-test-cross-chain)
```

## Deployment

`make deploy-testnet` / `make deploy-production` drive the scripts in `script/`. **Caveat:** both scripts currently construct `Omnibus` with `abi.encode(OMNIBUS_OWNER)` only, while the active constructor requires `(address initialOwner, address quipFactory)`. They will not deploy the active contract correctly (and no address derived from them is valid) until they are updated with a verified QuipFactory address.
