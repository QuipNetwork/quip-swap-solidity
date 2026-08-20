# SDK usage

The package root targets the current protocol. The examples below omit key
management and address discovery; applications must supply both securely.

## Create a client

```ts
import {createPublicClient, createWalletClient, http} from 'viem'
import {createProtocolClient} from '@quip.network/quip-swap-sdk'

const publicClient = createPublicClient({chain, transport: http(rpcUrl)})
const walletClient = createWalletClient({account, chain, transport: http(rpcUrl)})

const protocol = createProtocolClient({
  addresses: {
    assetSupportRegistry,
    directAuthorization,
    crossChainWrapper,
    sameChainWrapper,
  },
  publicClient,
  walletClient,
})
```

Read calls work without `walletClient`. Write calls require a wallet client with
an account.

## Submit and verify a transaction

```ts
import {waitForProtocolReceipt} from '@quip.network/quip-swap-sdk'

const hash = await protocol.claimCrossChain(terms, false, lock, secret)
const {receipt, events} = await waitForProtocolReceipt(
  publicClient,
  hash,
  protocol.addresses,
  3,
)
```

The client exposes direct and wallet commit authorization, lazy direct
registration, registry operations, asset allowlisting, cross-chain and
same-chain claim/reclaim calls, and state reads. Always verify the receipt and
the expected protocol events before advancing local state.

## Trusted cross-chain coordination

`prepareTrustedCrossChainWorkflow` creates canonical terms, both exact commit
authorization payloads, independent nonces, the settlement secret, and the
Bob-commit secret. The owning client must persist the returned secrets before
broadcasting.

The workflow does not monitor chains. Callers must feed it authenticated,
canonical observations and the configured confirmation count. In particular,
Bob must not enable his commit until Alice's commit is final. Alice's commit
publishes the Bob-commit preimage on-chain; no private handoff is required.

For the separate-process prototype client, use the [CLI](CLI.md). For protocol
ordering and recovery, see [protocol flow](../docs/protocol-flow.md).

## Legacy API

Omnibus helpers are compatibility-only:

```ts
import {createOmnibusClient} from '@quip.network/quip-swap-sdk/legacy'
```

Do not mix legacy and current protocol calls in one workflow.
