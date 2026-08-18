# v1.1 prototype deployment

The prototype stack is deployed through canonical CreateX using component-specific,
sender-permissioned CREATE3 salts under version `v1.1.0-alpha.3`. The same deployer
therefore receives the same four protocol addresses on every supported chain even
though constructor configuration is checked independently on each chain.

Required environment:

- `DEPLOYER_PK`: broadcasting operations key;
- `PROTOCOL_OWNER`: the deployer EOA, used as the initial owner of the asset-support registry;
- `TRUSTED_VERIFIER`: already-deployed pinned SHRINCS 256s-Keccak verifier; and
- the selected RPC URL.

Run a dry run with `make deploy-protocol-dry RPC=API_URL_BASE_SEPOLIA`, then broadcast
with `make deploy-protocol RPC=API_URL_BASE_SEPOLIA`. The script deploys, in order:

1. `AssetSupportRegistry`
2. `DirectAuthorization`
3. `CrossChainWrapper`
4. `SameChainWrapper`

Existing code is accepted only after the same immutable configuration checks, making a rerun idempotent. Timing and finality policy is configured and enforced by each client, not deployed on chain.

After every chain is configured and independently checked, ownership of the
`AssetSupportRegistry` may be moved with its two-step ownership transfer. This post-deployment
governance
operation is intentionally separate from deterministic deployment.

The emitted `ProtocolDeployment` data and console output are the deployment record.
Applications can reproduce the addresses and a chain-specific
configuration vector with `buildPrototypeDeploymentManifest` from the SDK. Preserve
that manifest with the broadcast artifacts; do not add an address to a public SDK
registry until its bytecode and configuration have been independently verified.
