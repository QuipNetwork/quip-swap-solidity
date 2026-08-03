# Quip Swap

Non-custodial, hashlocked same-chain and cross-chain swaps built around the **Omnibus** singleton contract, with ERC-7913 keyed commit authorization plus a factory-gated quip-wallet route.

## Repository layout

```text
src/                  Production contracts (Omnibus, TermsLib, interfaces)
test/                 Foundry test suite (behaviors, scenarios, attack tests,
                      harnesses, mocks, real-verifier integration)
script/               Deployment scripts (Omnibus via CreateX CREATE3;
                      constructor (initialOwner, walletFactory) from
                      OMNIBUS_OWNER + WALLET_FACTORY)
sdk/                  TypeScript SDK (Bun + Viem + Vitest) — see sdk/README.md
```

## Protocol summary

- `Omnibus` is a singleton (Ownable2Step, ERC-721/1155 receiver) holding hashlocked escrows.
- A swap is two `Terms` (one per side), each with three lifecycle timestamps that **strictly interleave** across sides. The side with the earlier `commitmentDeadline` is the proposer and commits first.
- All three entry points are **permissionless**. `commit` authenticates its PAYLOAD instead of its caller: every commit carries a `CommitAuth {signer, signature}` where `signer` is an ERC-7913 keyed identity — `verifier(20 bytes) ‖ key`; any blob of 20 bytes or fewer (including bare addresses) is rejected as malformed. Two routes, discriminated by `signature`:
  - **non-empty — KEYED route:** the declared verifier (checked against an owner-managed active-verifier list) verifies the signature over a raw tagged digest binding chainid, the Omnibus address, the lock, both sides' terms, and the identity itself.
  - **empty — WALLET route:** `msg.sender` must be a wallet deployed by the quip `WalletFactory` (`vaultIdOf(msg.sender) != 0` on the factory baked in at construction; `NotQuipWallet` otherwise). No signature is verified — a vetted wallet only reaches `commit` from its PQ-authenticated execute flow, so factory membership stands in for the endorsement.
- The keyed signature is a **soft guard**: it proves the declared identity endorsed exactly this payload; it does not gate WHICH identity may post a side. Clients that care who posted the counterpart side verify the `signer` blob from the `Commitment` event off-chain — **but on the wallet route the emitted `signer` is UNPROVEN attribution** (nothing verified it), so it must never be treated as an endorsement there.
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

Per-chain deploy is a single step: **`make deploy`** — Omnibus deploys through the canonical [CreateX](https://github.com/pcaversaccio/createx) factory (pre-deployed on essentially every EVM chain; no per-chain bootstrap) via CREATE3. The salt is CreateX-permissioned to the ops EOA (entropy `QUIP:Omnibus:v1.0.0-alpha.2`), so the address is a function of (CreateX, deployer EOA, salt): independent of constructor args, identical across chains, and unclaimable by anyone else. Keyed commit authorization uses an ERC-7913 verifier; verifier deployment is a separate concern, and activation is a post-deploy owner action: `make activate-verifier` (calls `setVerifierActivity(verifier, true)`, checked via `verifierActive(verifier)`). The wallet route's `WalletFactory` proxy is baked as an immutable at construction. Env: `DEPLOYER_PK`, `OMNIBUS_OWNER`, `WALLET_FACTORY` (both non-zero). The salt entropy label is a **salt version, not a release gate**: it is deliberately identical on testnet and mainnet, because that is what gives the Omnibus one address on every chain. Bump it only for an intentional redeploy of *every* chain — a bump abandons the old address everywhere. Prior deployments persist at their old addresses.

### Why the deploy script is all assertions

A wrong caller **does not revert** inside CreateX. It fails the sender-prefix match, silently takes a different guard branch, and deploys *successfully* at an unrelated address. Every safety property below exists because that failure is silent:

- **The deployer EOA is compiled in** (`Constants.DEPLOYER`), not read from the environment. A prediction derived from the live signer would follow a wrong key to its wrong address, and the post-deploy `deployed == expected` check would then **pass**. `DEPLOYER_PK` must derive it; the script aborts before broadcasting otherwise.
- **Deploys run under `FOUNDRY_PROFILE=prod`** (metadata stripped, dedicated `out-prod/`), asserted by the script. Keep `FOUNDRY_PROFILE` out of `.env` — forge loads it, and a value there would apply to `forge test` too.
- **An occupied address is checked semantically**, never skipped: a CREATE3 address ignores init code, so "has code" says nothing about what is there. The script reads the `WALLET_FACTORY` and `DOMAIN_SEPARATOR` immutables and reverts on a mismatch.
- **Safe / multisig routing is not supported**, by construction. CreateX keys its guard off `msg.sender`, so a Safe-executed deploy lands at a completely different address. This design binds the address to an EOA key; that key is address-load-bearing, and losing it means those addresses are unreachable on any chain not yet deployed to.

Two free gates must both pass before any broadcast:

```shell
make test-fork RPC=API_URL_BASE_SEPOLIA               # executes the REAL CreateX bytecode
make deploy-dry RPC=API_URL_BASE_SEPOLIA              # must print the address in sdk/src/address.json
make deploy-dry-wrong-signer RPC=API_URL_BASE_SEPOLIA # and confirm the negative: this MUST fail
```

If either disagrees with the registry, the salt construction is wrong — stop and fix it before spending gas. Recovery from a mistake is bumping the entropy label (new salt → new, unoccupied address); squatting cannot burn a salt, so this only ever covers your own errors.
