# Quip Swap SDK

TypeScript integration for the current v1.1 prototype. It provides protocol
types and hashing, generated ABIs, Viem contract calls, receipt decoding, and
the finality-aware trusted cross-chain workflow.

```ts
import {
  createProtocolClient,
  waitForProtocolReceipt,
} from '@quip.network/quip-swap-sdk'
```

Applications must provide verified deployment addresses and configured Viem
clients. The SDK does not discover deployments or manage signing keys.

## Development

From `sdk/`:

```sh
bun install --frozen-lockfile
bun run check
bun run test:integration
bun run test:cross-chain
```

Generate ABIs after a contract build with `bun run generate:abi`.

See [usage](USAGE.md), [CLI reference](CLI.md), and the
[demo guides](../docs/demo/README.md).

The retired Omnibus API is available only from the explicit compatibility
entry point:

```ts
import {createOmnibusClient} from '@quip.network/quip-swap-sdk/legacy'
```
