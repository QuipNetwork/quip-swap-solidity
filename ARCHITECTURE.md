# Quip Swap v1.1 architecture

## Scope

The prototype implements same-chain and cross-chain swaps with native,
ERC-20, ERC-721, and ERC-1155 assets. PQ signatures authorize commits. A
trade-bound settlement secret authorizes claims; signed deadlines enable
permissionless reclaim.

The contracts never read another chain. Cross-chain safety depends on secret
handling, finality-aware observation, conservative deadlines, and a timely
final-claim executor. See [security assumptions](docs/security-assumptions.md).

The old `Omnibus` implementation under `src/legacy/` is not the current
integration or deployment surface. Its deployment tools are isolated under
`script/legacy/`.

## Components

```text
                         OFF-CHAIN CLIENT
                    terms, timing, observations
                                |
                 PQ-authorized commit request
                                |
              +-----------------+-----------------+
              |                                   |
       QuipWallet                         DirectAuthorization
       wallet mode                        registered-direct mode
              +---------------+-------------------+
                              |
                  verified commit evidence
                              |
              +---------------+----------------+
              |                                |
       SameChainWrapper                CrossChainWrapper
              |                                |
       SameChainStateMachine           CrossChainStateMachine
              +------------ Settlement --------+
              |                                |
       per-side SwapHTLC clone          per-side SwapHTLC clone
              +------- AssetHandling + allowlist
```

- `src/protocol/ProtocolTypes.sol`: terms, authorization requests, evidence,
  identities, and state enums.
- `src/protocol/ProtocolHashing.sol`: domain-separated hashes and static term
  validation.
- `src/protocol/CommitValidation.sol`: authorization replay and progression
  checks.
- `src/protocol/StateMachines.sol`: same-chain and cross-chain transitions.
- `src/protocol/Settlement.sol`: claim/reclaim guards and payouts.
- `src/protocol/*Wrapper.sol`: commit and settlement entry points, state
  ownership, and deterministic HTLC registries.
- `src/protocol/SwapHTLC.sol`: cloneable custody boundary for exactly one
  trade side; only its wrapper controller can release it.
- `src/authorization/`: PQ and submitter/delegation boundaries.
- `src/assets/`: token admission and exact collection/release checks.

## Terms and hashes

`ProtocolTerms` contains two ordered `SideTerms` records. Each side signs its
chain, assets, principal, authorization mode and key version, destinations,
deadlines, delegation policy, `commitLock`, and random `sideNonce`.

Important hashes are:

- `TradeID`: all canonical terms;
- `GateContextID`: all terms with Bob's commit lock projected to zero;
- `commitLock`: Bob's progression preimage bound to that context;
- settlement `Lock`: `TradeID` plus the settlement preimage;
- `AssetHash`: one side's exact canonical asset list; and
- `CommitPayloadHash`: chain, mode, verifier, wrapper, trade, lock, side,
  expected source state, assets, principal, delegation, nonce, and expiry.

Contracts enforce intrinsic term shapes and deadline ordering. Directional
finality and reaction margins are client policy, not signed terms or an on-chain
registry.

## Authorization

Both modes deliver `VerifiedCommitAuthorization` to a wrapper. The applicable
authorization boundary verifies the signature and submitter policy, then
consumes its own nonce before calling the wrapper. The wrapper reconstructs the
payload, checks the trusted authorization caller and evidence, and enforces
exclusive expiry. A failed commit reverts nonce consumption with the complete
transaction.

### Registered-direct mode

`DirectAuthorization` is one deployed contract implementing both the identity
registry and direct commit gateway roles. Wrappers pin its address as
`DIRECT_AUTHORIZATION`; no separate registry/gateway deployment is required.

It maps an EOA to independently versioned active and
recovery PQ keys. Initial registration can be combined atomically with the
first commit. Rotation, recovery, revocation, proof of possession, expiry, and
registry replay protection are chain- and contract-bound.

The prototype records the verifier address, runtime code hash, version, and
profile when admitting keys. Signature-use paths do not currently recheck every
property; the verifier must remain immutable until that gap is fixed.

### Wallet mode

`QuipWallet` owns its PQ key and monotonic key epoch. Its commit signature wraps
the canonical payload with the wallet address, chain, and epoch. Generic
classical-owner execution cannot directly invoke a wrapper authorization
selector.

Wrappers do not yet authenticate wallets through an approved factory or
implementation registry. Wallet provenance is therefore a prototype trust
assumption.

### Delegation

`NotAllowed` requires principal submission. `SpecificDelegate` permits the
principal or signed registered delegate. `Permissionless` permits any nonzero
transport caller. Delegation never changes the funding principal or payout
destinations.

## Progression and settlement secrets

Same-chain commits require canonical zero progression data.

Every cross-chain commit supplies the same trade-bound `BobCommitSecret`:

1. Alice includes it in her funded commit. The wrapper verifies it and emits
   `BobCommitSecretPublished` atomically with escrow.
2. It is public immediately, but Bob's trusted client waits for the configured
   finality threshold before enabling submission.
3. Bob supplies the same preimage with his independently authorized commit.

`BobCommitSecret` enables only Bob's exact authorized escrow. It cannot claim
assets or redirect payouts.

The separate settlement secret opens the trade-bound settlement lock. Alice's
claim on Bob's chain publishes it. Bob or any funded executor can then claim
Alice's leg. Claims and reclaims are permissionless and always pay signed
destinations.

## State machines

Cross-chain state is local to `(TradeID, Lock, SideTag)`:

```text
Unused -> Committed -> Claimed
                    -> Reclaimed
```

Same-chain state is local to `(TradeID, Lock)`:

```text
Unused -> PartyCommitted -> BothCommitted -> ClaimPending -> Claimed
             |                  |
             |                  +-> ReclaimPending -> Reclaimed
             +--------------------> ReclaimPending -> Reclaimed
```

The first same-chain commit binds both sides. Each commit creates and funds its
own deterministic HTLC. A payout-free transaction irreversibly selects claim
or reclaim inside its valid time window. Permissionless calls then release one
selected HTLC side in bounded asset batches. Required/completed side bitmaps
keep the outcome pending until every applicable HTLC completes; a failed batch
does not undo earlier successful batches or permit switching outcomes.

## Asset custody

Token commits require the exact `(assetType, target)` pair in
`AssetSupportRegistry`. Collection and release check exact native value,
balance deltas, or ERC-721 ownership. The wrapper deterministically clones one
`SwapHTLC` for the committed side and sends assets directly from the principal
to that clone. It never pools committed funds. The clone binds its controller,
`TradeID`, settlement lock, side tag, and side-terms hash; release is one-shot
and pays only the destination selected by the wrapper from signed terms.

`reserved(Asset)` remains as a compatibility view and always returns zero. It
is not custody accounting.

Commitment fees are separate wrapper accounting. Each accepted local commit
retains one live owner-configured native fee while forwarding only signed
native escrow to its HTLC. Fees are not signed or snapshotted, remain accrued
through claim and reclaim, and only the accrued ledger—not raw wrapper
balance—is owner-withdrawable. Network gas is never protocol revenue. See
[commitment fees](docs/fees.md).

Allowlisting is an assertion of continued token behavior, not proof of safety.
See [asset compatibility](docs/asset-support.md).

## Deployment and SDK

`script/DeployProtocol.s.sol` deploys five components with versioned,
sender-permissioned CREATE3 salts. See
[prototype deployment](script/DEPLOYMENT.md) for current verification gaps.

The package root exports current terms, hashes, ABIs, clients, events, trusted
workflow, and console primitives. Omnibus compatibility is isolated at
`@quip.network/quip-swap-sdk/legacy`.

## Cached settlement validation

Settlement relies on the originating commit's structural validation and the
complete terms-hash binding of its stored record. The
[Solidity refinement argument](docs/settlement-validity.md) states the invariant,
proves preservation by induction over wrapper transactions, and identifies the
hash and deployment assumptions. It also covers resumable same-chain states.
Mutable asset admission and client timing policy are separate from this cached
structural predicate.

## Core invariants and limits

- Hashes bind security-relevant action fields to a chain and contract.
- State, custody, lazy registration, and nonce consumption roll back together.
- Assets are pulled from the signed principal, not a broker or relayer.
- Callers cannot redirect claim or reclaim payouts.
- Terminal local state cannot be reused.
- Same-chain payout work is bounded per call and retryable after transient
  failure, while the selected payout address remains fixed across batches.
- Contracts do not establish remote finality, asset honesty, verifier
  immutability, wallet provenance, a bound on term asset counts, or timely
  execution.
