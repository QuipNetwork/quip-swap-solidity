# Protocol flow

This is the implementation-facing v1.1 flow for the current Solidity
prototype.

## Participants and values

Alice is `PartySide`; Bob is `CounterpartySide`. They agree on identical
`ProtocolTerms`, including principals, assets, payout destinations, deadlines,
authorization/delegation modes, both random `sideNonce` values, and Bob's
cross-chain `commitLock`.

Alice generates:

- the settlement secret used by claims; and
- `BobCommitSecret`, used only to gate cross-chain commits.

The settlement lock is derived from `TradeID` and the settlement secret. Bob's
commit lock is derived from `GateContextID` and `BobCommitSecret`. Neither raw
secret is part of the signed terms.

## Cross-chain success

1. Both parties independently validate the same terms and timing margins.
2. Alice PQ-authorizes her local commit. The wrapper creates her deterministic
   side HTLC and funds it directly from her principal.
3. Alice's transaction verifies and publishes `BobCommitSecret` atomically with
   escrow. The preimage is public as soon as the transaction is visible.
4. Bob's trusted client authenticates Alice's transaction and waits for its
   configured finality threshold.
5. Bob PQ-authorizes his commit using the published preimage. His wrapper
   creates and funds Bob's distinct side HTLC.
6. Alice observes Bob's local `Committed` state and claims Bob's leg with the
   settlement secret. The secret becomes public in calldata.
7. Bob or another funded executor waits for the configured reveal finality and
   submits the same secret to release Alice's HTLC to its signed recipient.

There is no permanent success-path delay in the contracts. Finality waiting is
an off-chain risk policy. Bob's commit and the revealing claim occur on the
same chain, so the claim is causally dependent on that commit.

```text
Alice/Chain A            Bob/Chain B
     |                         |
PQ commit + Bob preimage       |
     |---- observe/finality -->|
     |                  PQ commit + same preimage
     |                         |
     |<--- claim + settlement secret
final claim + same secret      |
     |                         |
   Claimed                   Claimed
```

## Cross-chain recovery

A committed local leg can be reclaimed permissionlessly once its signed
`reclaimRelease` is reached. Payout always goes to its `reclaimRecipient`.

Common outcomes are:

- Alice commits, Bob never commits: Alice later reclaims.
- Both commit, nobody claims: both legs later reclaim independently.
- Alice claims Bob's leg, final claim is missed: Bob's leg is `Claimed`; Alice's
  remaining leg may later be `Reclaimed`. This is an atomicity failure, not a
  successful reclaimed swap.

The protocol cannot prevent censorship, excessive reorganization, leaked
settlement secrets, or an executor missing the remaining claim window.

## Same-chain success

Both sides use one `SameChainWrapper`, one settlement lock, and canonical zero
progression locks.

1. Alice's authorized commit moves `Unused -> PartyCommitted`, creates her
   deterministic side HTLC, and funds it from her principal.
2. Bob's authorized commit requires that exact source state and moves
   `PartyCommitted -> BothCommitted`, creating and funding his separate HTLC.
3. Any caller with the settlement secret selects claim before the earlier claim
   deadline. Selection moves `BothCommitted -> ClaimPending` without a payout.
4. Any callers release each required HTLC with bounded
   `executeSettlement(..., maxAssets)` calls. Each HTLC locks its terms-fixed
   recipient on its first successful batch.
5. Completed-side bits persist across calls. The final required side moves
   `ClaimPending -> Claimed`.

## Same-chain recovery

- From `PartyCommitted`, reclaim selection is available at Alice's release and
  requires only Alice's HTLC to complete.
- From `BothCommitted`, reclaim selection is available only after both releases
  and requires both HTLCs to complete.
- Claim and reclaim selection are mutually exclusive and irreversible. Timing
  is checked at selection; selected payouts may finish later.
- Each payout call is atomic only for its own batch. A failed batch preserves
  the selected outcome and every earlier completed batch. A permanently
  failing asset can strand its own HTLC, but cannot roll back the other side.

## Authorization and submission

Every commit requires the principal's exact PQ authorization. Depending on the
signed delegation policy, the transaction may be transported by the principal,
a specific registered delegate, or any relayer. Tokens are always pulled from
the principal. Native value may be transported by the caller but must exactly
match the signed native assets.

Claims and reclaims do not use delegation policy. They are permissionless
because their payouts are immutable.

## Observation rule

An event or transaction hash is not finality. Trusted clients bind observations
to the expected chain, wrapper, transaction, canonical block, `TradeID`, lock,
side, and principal, and apply a configured confirmation/finality policy before
advancing cross-chain state.
