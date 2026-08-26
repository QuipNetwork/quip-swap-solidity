# v1.1 prototype deployment

This procedure deploys the five-contract prototype through canonical CreateX
with component-specific, sender-permissioned CREATE3 salts under
`v1.1.0-alpha.4`.

It is not yet a production deployment procedure. Read
[`../docs/security-assumptions.md`](../docs/security-assumptions.md).

Retired Omnibus deployment tooling is isolated under `script/legacy/` and is
not part of this procedure.

## Required configuration

- `DEPLOYER_PK`: broadcasting key.
- `PROTOCOL_OWNER`: nonzero initial `AssetSupportRegistry` owner. The current
  script requires it to equal the deployer.
- `TRUSTED_VERIFIER`: deployed SHRINCS 256s-Keccak verifier reporting the
  expected version and profile.
- `RPC`: Make variable naming an RPC URL variable loaded from `.env`, for
  example `API_URL_BASE_SEPOLIA`.
- Canonical CreateX must already exist at the configured address.

Never commit private keys or RPC credentials.

## Dry run and broadcast

```sh
make deploy-protocol-dry RPC=API_URL_BASE_SEPOLIA
make deploy-protocol RPC=API_URL_BASE_SEPOLIA
```

Deployment order is:

1. `AssetSupportRegistry`
2. `DirectAuthorization`
3. `SwapHTLC` implementation
4. `CrossChainWrapper`
5. `SameChainWrapper`

The same deployer and versioned salts predict the same five addresses across
chains. Constructor configuration can still differ by chain and must be
verified independently.

## Required verification

Before publishing an address, record and verify on every chain:

- chain ID, CreateX address, deployer, version, and salt;
- runtime bytecode identity for every component;
- asset-registry owner;
- direct authorization's verifier address, runtime code hash, version, and
  profile;
- both wrappers' `DIRECT_AUTHORIZATION`; and
- both wrappers' `ASSET_SUPPORT` and `HTLC_IMPLEMENTATION`.

Generate the SDK configuration vector with `buildPrototypeDeploymentManifest`
and preserve it with Foundry broadcast artifacts and independent RPC results.
The `ProtocolDeployment` event emitted by the script after `stopBroadcast` is a
script log, not a durable on-chain registry entry.

## Current rerun limitation

The script skips a predicted address when it already contains code. Its current
post-check verifies the dependency graph but not every runtime bytecode
identity. Treat reruns and partial deployments as unsafe until bytecode checks
and wrong-code tests are added. Address equality alone is not release
verification.

## Verifier requirement

Reject proxy, upgradeable, or metamorphic verifier deployments unless their
implementation and upgrade controls are explicitly part of the reviewed trust
model. The current authorization path does not recheck every pinned verifier
property on every signature use.

## Asset registry ownership

Configure and independently verify all initial asset entries before transferring
ownership. Ownership transfer uses OpenZeppelin's two-step flow and is separate
from deterministic deployment. Define production multisig/timelock, monitoring,
emergency delisting, and ownership-renunciation policy before deployment.

## Release gate

Do not add addresses to a public SDK registry until:

- the full source revision and dependency lock are fixed;
- every bytecode and immutable check passes on every chain;
- real-verifier integration and gas tests pass;
- asset and timing policies are approved; and
- broadcast artifacts, manifests, and independent verification results are
  archived.
