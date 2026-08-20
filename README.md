# Quip Swap Solidity

This branch contains the v1.1 protocol prototype: same-chain and cross-chain
escrow wrappers, PQ commit authorization, asset admission and custody, a
TypeScript SDK, and deterministic local demos.

It is a prototype, not a production release. Read
[security assumptions](docs/security-assumptions.md) before using it with
assets of value.

## Quick start

Prerequisites: Foundry, Bun, and dependencies under `dependencies/`.

```sh
forge build
forge test
forge fmt --check
cd sdk
bun install --frozen-lockfile
bun run check
cd ..
```

Run the current demos:

```sh
cd sdk
bun run demo:full
bun run demo:same-chain
bun run demo:cross-chain:recovery
bun run demo:console
cd ..
```

See [the demo guides](docs/demo/README.md) for prerequisites, expected results,
manual console operation, and artifact validation.

## Current integration surface

- `src/protocol/`: terms, hashing, state machines, settlement, and wrappers.
- `src/authorization/`: registered-direct and QuipWallet authorization.
- `src/assets/`: asset allowlisting and escrow accounting.
- `sdk/`: current API and prototype trusted-client CLI.
- `script/DeployProtocol.s.sol`: deterministic prototype deployment.

```ts
import {
  createProtocolClient,
  crossChainWrapperAbi,
} from '@quip.network/quip-swap-sdk'
```

The old Omnibus implementation remains only for regression and comparison.
Legacy SDK callers must use its explicit compatibility entry point:

```ts
import {createOmnibusClient} from '@quip.network/quip-swap-sdk/legacy'
```

## Documentation

- [Architecture](ARCHITECTURE.md)
- [Protocol flow](docs/protocol-flow.md)
- [Security assumptions](docs/security-assumptions.md)
- [Remaining issues](docs/issues.md)
- [Asset compatibility](docs/asset-support.md)
- [Prototype deployment](script/DEPLOYMENT.md)
- [SDK overview](sdk/README.md)
- [SDK usage](sdk/USAGE.md)
- [CLI reference](sdk/CLI.md)
- [Demo guides](docs/demo/README.md)
- [Legacy documentation](docs/legacy/)

The normative protocol design is maintained in
`../../interlock-ec/dev/v1.1/protocol/`.
