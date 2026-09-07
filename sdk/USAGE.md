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
same-chain settlement calls, and state reads. Same-chain callers first use
`selectSameChainClaim` or `selectSameChainReclaim`, then call
`executeSameChainSettlement` for each required side and asset batch. Read
`protocol.getSameChainSettlementProgress(terms, lock)` to determine required
and completed side bits.
Always verify the receipt and expected protocol events before advancing local
state.

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

## Cross-chain timing configuration

Before either party signs, call `validateProtocolTerms(terms, policy)` (the
trusted workflow does this during preparation and restoration). It requires
`counterpartySide.claimDeadline + policy.counterpartyToPartyDelay <= partySide.claimDeadline`,
alongside the existing reclaim margins. Low-level hashing and signing helpers
are not substitutes for this validation.

Read `FINAL_CLAIM_DELAY()` from both verified cross-chain wrapper deployments.
Use a reviewed `counterpartyToPartyDelay` at least as large as either immutable
value, covering finality, observation, relay, inclusion, and timestamp skew.
The exported prototype policies are examples, not evidence of a reviewed
production bound. The deployment manifest now requires `finalClaimDelay` and
binds it into its configuration hash.

This schedule supports Alice revealing on the counterparty leg, followed by
Bob's final claim on the party leg. Keep the settlement secret confidential
until that accepted reveal after both commits are safe. See the
[timing argument and assumptions](../docs/protocol-flow.md#cross-chain-final-claim-window).

## Legacy API

Omnibus helpers are compatibility-only:

```ts
import {createOmnibusClient} from '@quip.network/quip-swap-sdk/legacy'
```

Do not mix legacy and current protocol calls in one workflow.
