# Structural validity carried by committed state

This is a source-level refinement argument for the current Solidity wrappers.
It documents why settlement can omit a repeated structural term validation.
It is not a machine-checked EasyCrypt proof or a claim that Solidity implements
every predicate in the broader protocol specification.

## Predicate and scope

Define `StructurallyValidTerms(T)` to mean that
[`ProtocolHashing.validateTerms(T)`](../src/protocol/ProtocolHashing.sol)
returns without reverting under the deployed implementation. This is a pure
predicate: it includes canonical asset and identity fields, nonzero side
nonces, progression-field shape, and structural deadline ordering.

This predicate does not include mutable asset admission, signature validity,
current time, remote-chain support, or client timing-policy margins. Local
chain, wrapper payout-address checks, and the cross-chain immutable final-claim
margin are additional commit guards. A cached
structural check does not establish the broader specification's complete
`ValidTerms` predicate where that predicate includes policies absent from this
prototype.

The argument applies to reachable storage of the deployed
[`CrossChainWrapper`](../src/protocol/CrossChainWrapper.sol) and
[`SameChainWrapper`](../src/protocol/SameChainWrapper.sol), at transaction
boundaries. It assumes their code and storage have not been replaced or
modified outside these entry points. It does not apply to arbitrary users of
the internal state-machine libraries or test harnesses that can seed state.

## Invariant

For each non-`Unused` record in wrapper `W`, there exist complete terms `T0`
and a successful originating commit in `W` such that:

- `StructurallyValidTerms(T0)` held when that commit executed;
- for cross-chain records, the immutable final-claim margin also held at commit;
- the record is keyed by `TradeID(T0)` and its settlement lock, plus the local
  side tag for cross-chain records;
- every subsequent transition of that record retains this binding.

For cross-chain records, the originating action is that local side's commit.
For same-chain records, it is the party commit, which validates **both** sides'
terms before creating `PartyCommitted`. The counterparty commit revalidates the
complete terms and advances the same joint record. The invariant covers
`ClaimPending` and `ReclaimPending` as well as committed and terminal states.
A same-chain party commit establishes validity of Bob's terms, not custody of
Bob's assets; only the responding commit establishes the latter.

## Inductive argument over transactions

1. **Initial storage.** All records are `Unused`, so the invariant holds
   vacuously.
2. **Record creation.** Both `receiveAuthorizedCommit` entry points call their
   `_validate`, which invokes `ProtocolHashing.validateTerms`, before calling a
   state-machine commit transition. The only transitions out of `Unused` are
   cross-chain `commit` and same-chain `commitParty`. The trade identifier is
   recomputed from those validated terms. Although state effects precede asset
   interactions, a failed funding or custody check reverts the entire call;
   a persisted originating commit therefore passed structural validation.
3. **Existing records.** The same-chain counterparty commit requires
   `PartyCommitted` at the supplied terms' key. Claims, reclaim selections,
   settlement batches, and completion transitions require an existing source
   state. The [state machines](../src/protocol/StateMachines.sol) update only
   that record's state and progress bits; they do not replace its key or create
   a settlement record from `Unused`. Thus each transition preserves its valid
   origin. A successful batch can leave a pending record, which retains the
   same origin even if a later batch fails.
4. **Rejection and unrelated actions.** Reverted calls leave the prior storage
   unchanged. Fee and asset-support administration cannot write the wrapper's
   private protocol-state mappings. Terminal records cannot be recommitted.

These cases establish the invariant for every reachable transaction-boundary
state under the stated code/storage assumptions.

## Why supplied settlement terms are the validated terms

The caller supplies complete terms `T`. Settlement recomputes `TradeID(T)`;
there is no caller-supplied trade identifier that bypasses that computation.
The state-machine keys are:

```text
cross-chain: keccak256(abi.encode(TradeID(T), Lock, SideTag))
same-chain:  keccak256(abi.encode(TradeID(T), Lock))
```

Each wrapper owns its own mappings, so the wrapper address is an implicit
storage namespace. An admissible source-state lookup must find an existing
record. By the invariant, that record has a validated origin `T0`.

Assume unambiguous ABI encoding and no relevant collision in either the
record-key hash or the domain-separated terms hash. Equality of record keys
then binds the same trade identifier, lock, and applicable side. Equality of
trade identifiers binds the complete canonical terms: `T = T0`. It follows
that `StructurallyValidTerms(T)` holds without rerunning the validator. Modified
terms, including either side's assets, destinations, deadlines, or nonce, cannot
select that record under these assumptions. Collision resistance is a
computational assumption, not mathematical injectivity of Keccak.

Before paying from a dedicated HTLC, [Settlement](../src/protocol/Settlement.sol)
also verifies its controller, trade identifier, lock, side, and side-terms hash.
These custody-binding checks supplement the state lookup; they do not replace
its valid-origin argument. Mode, local chain, source state, settlement secret,
and action-specific time guards still execute where required. For resumable
same-chain settlement, the time guard applies to outcome selection; later
batches require the selected pending outcome.

## What is intentionally not rechecked

Asset support is admission policy at commit time. Delisting an asset does not
invalidate its committed terms or prevent claim/reclaim. The invariant proves
neither continued token behavior nor successful payout; live transfer checks
still apply. It also proves neither remote finality nor client timing safety.

With an unchanged pure validator, validity at commit time implies validity at
settlement time for identical terms. A future upgrade or migration that changes
validation or admits preexisting state must re-establish this invariant for
those records; it cannot assume they passed the new validator.
