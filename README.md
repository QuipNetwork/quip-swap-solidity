# Quip Swap Solidity

This branch contains the v1.1 protocol prototype: same-chain and cross-chain
coordination wrappers, one dedicated HTLC per committed swap side, PQ commit
authorization, asset admission, a TypeScript SDK, and deterministic local demos.

It is a prototype, not a production release. Read
[security assumptions](docs/security-assumptions.md) before using it with
assets of value.

## Quick start

Prerequisites: Foundry, Bun, and dependencies under `dependencies/`.

```sh
make dependencies
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

- `src/protocol/`: terms, hashing, state machines, settlement, wrappers, and
  the cloneable `SwapHTLC` custody implementation.
- `src/authorization/`: registered-direct and QuipWallet authorization.
- `src/assets/`: asset allowlisting and exact-transfer primitives.
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

The broader protocol design and proof materials are maintained outside this
repository. This repository documents and implements the current Solidity
prototype surface.
