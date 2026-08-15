# v1.1 prototype deployment

The prototype stack is deployed through canonical CreateX using component-specific,
sender-permissioned CREATE3 salts under version `v1.1.0-alpha.1`. The same deployer
therefore receives the same six protocol addresses on every supported chain even
though constructor configuration is checked independently on each chain.

Required environment:

- `DEPLOYER_PK`: broadcasting operations key;
- `PROTOCOL_OWNER`: the deployer EOA, used as the initial owner of both
  governance registries so policy bootstrap is atomic;
- `TRUSTED_VERIFIER`: already-deployed pinned SHRINCS 256s-Keccak verifier; and
- the selected RPC URL.

Run a dry run with `make deploy-protocol-dry RPC=API_URL_BASE_SEPOLIA`, then broadcast
with `make deploy-protocol RPC=API_URL_BASE_SEPOLIA`. The script deploys, in order:

1. `AssetSupportRegistry`
2. `TimingPolicyRegistry`
3. `PQIdentityRegistry`
4. `PQAuthorizationGateway`
5. `CrossChainWrapper`
6. `SameChainWrapper`

It then registers both canonical Base Sepolia/OP Sepolia cross-chain policy orderings
and the local same-chain policy. Existing code and policies are accepted only after
the same immutable configuration checks, making a rerun idempotent.

After every chain is configured and independently checked, ownership may be moved
with each registry's two-step ownership transfer. This post-deployment governance
operation is intentionally separate from deterministic deployment.

The emitted `ProtocolDeployment` data and console output are the deployment record.
Applications can reproduce the addresses, policy identifiers, and a chain-specific
configuration vector with `buildPrototypeDeploymentManifest` from the SDK. Preserve
that manifest with the broadcast artifacts; do not add an address to a public SDK
registry until its bytecode and configuration have been independently verified.
