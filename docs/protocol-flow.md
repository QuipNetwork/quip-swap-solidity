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
2. Alice discovers her local wrapper's live fee, PQ-authorizes her local
   commit, and submits the exact native escrow plus that fee. The wrapper keeps
   the fee and funds the deterministic side HTLC only with signed escrow.
3. Alice's transaction verifies and publishes `BobCommitSecret` atomically with
   escrow. The preimage is public as soon as the transaction is visible.
4. Bob's trusted client authenticates Alice's transaction and waits for its
   configured finality threshold.
5. Bob independently discovers his local wrapper fee and PQ-authorizes his
   commit using the published preimage. His wrapper keeps its fee and creates
   and funds Bob's distinct side HTLC.
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

## Cross-chain final-claim window

Let `B` be the counterparty-side claim deadline, `A` the party-side claim
deadline, and `D > 0` the reviewed counterparty-to-party delivery budget in
seconds. Both cross-chain wrappers require `B + FINAL_CLAIM_DELAY <= A` at
commit admission. The SDK requires `B + counterpartyToPartyDelay <= A` before
workflow authorization. Its configured budget must cover both wrappers' values
and the reviewed route assumptions. An earlier reveal deadline alone is not
enough, and a margin before reclaim does not keep a claim callable.

Claims require `timestamp < claimDeadline`. If Alice's accepted revealing claim
occurs at `t < B` and a funded executor can include Bob's final claim on Chain A
by timestamp `t + D`, then `t + D < B + D <= A`: the final claim is still open.
At integer-second equality, a reveal at `B - 1` delivered after the full budget
lands at `A - 1`. Tests exercise both payouts at this boundary and reject the
unsafe `A = 300, B = 320, D = 10` schedule and a margin one second too short.

This is a conditional liveness argument, not a cross-chain finality guarantee.
`D` must include source finality, observation and relay latency, destination
inclusion, and relative timestamp skew. Secret confidentiality must hold until
Alice's accepted counterparty-side reveal after both commits are safe. The
opposite first-reveal direction and secrets leaked through failed or late
transactions are outside this argument. Both positive directional claim-window
inequalities cannot hold at once. Same-chain settlement is unaffected.

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

1. Alice's authorized commit pays one live fee, moves
   `Unused -> PartyCommitted`, creates her deterministic side HTLC, and funds
   it from her principal.
2. Bob's authorized commit pays a second live fee, requires that exact source state, and moves
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
the principal. Native value is transported by the caller and must exactly
equal the selected side's signed native assets plus the wrapper's current fee.

Claims and reclaims do not use delegation policy. They are permissionless
because their payouts are immutable.

## Commitment-fee lifecycle

Each wrapper owner configures a native `commitmentFee`, capped at `0.01 ether`.
The value is live and mutable: it is not part of `ProtocolTerms`, the
authorization signature, or a per-trade snapshot. A client must read it
immediately before submission and explicitly retry after a fee-change revert.

Each accepted local commit accrues exactly one fee in addition to exact HTLC
escrow. A same-chain trade therefore pays two fees to one wrapper. A
cross-chain trade pays the independently configured fee on each chain. Once a
commit is accepted, its fee is protocol revenue even if the trade later
reclaims, never receives the other leg, or has an incomplete payout. The owner
may withdraw only `accruedFees`; HTLC escrow and unaccounted native value are
not withdrawable through the fee function. Transaction gas is paid separately
to the network and is never protocol revenue.

## Observation rule

An event or transaction hash is not finality. Trusted clients bind observations
to the expected chain, wrapper, transaction, canonical block, `TradeID`, lock,
side, and principal, and apply a configured confirmation/finality policy before
advancing cross-chain state.
