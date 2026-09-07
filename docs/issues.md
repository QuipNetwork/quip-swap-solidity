# Remaining issues

This is the current prototype issue tracker. It lists known unresolved security,
liveness, deployability, and operational weaknesses. It is not exhaustive and
does not replace an independent audit.

Status meanings: **open** requires an implementation or specification change;
**partially mitigated** has safeguards but retains material residual risk;
**production gap** is intentionally outside the local prototype.

## A: Known issues from v1

### A1 - Settlement-secret disclosure can break cross-chain atomicity — partially mitigated

If the settlement secret leaks before both intended commits are stable, a
committed leg may be claimed while the opposite leg is absent or later
reclaimed. The local HTLC predicate cannot verify remote-chain readiness.

Mitigation: fresh secrets, restricted storage, authenticated observations, and
revealing only after Bob's exact commit. Residual device, logging, backup, and
application compromise remains.

### A2 - Final-claim delivery and finality are not guaranteed — partially mitigated

After the revealing claim, an executor must land and finalize the opposite
claim before reclaim becomes admissible. Censorship, congestion,
reorganization, delayed observation, or bad timing calibration can produce an
asymmetric `(Claimed, Reclaimed)` outcome.

Mitigation: conservative deadlines, multiple funded permissionless executors,
rapid fee bumping, and chain-specific finality policies.

---

## IS: Intentional simplifications


### Bob-commit finality is an off-chain policy — partially mitigated

Alice's commit publishes `BobCommitSecret` immediately. Bob's client waits for
configured finality, but the destination contract cannot verify the remote
commit. Incorrect policy, compromised software, false RPC observations, or
client bypass can leave Bob escrowed after Alice's commit reorganizes away.


---

## PG: Production gaps

### PG1 - Wallet-mode authorization provenance — open

Wrappers do not prove that a wallet-mode caller is an approved QuipWallet
implementation that performed PQ verification. An EOA or arbitrary contract
named as the wallet principal may fabricate authorization evidence and bypass
PQ commit authorization.

Required: authenticate wallets through a **pinned factory**, registry,
implementation, or dedicated gateway, and test EOA and malicious-wallet
masquerading.

### PG2 - Verifier identity is not rechecked on every use — open

Registered-direct admission pins verifier address, code hash, version, and
profile, but later signature paths do not recheck every property. A mutable
proxy or metamorphic verifier at the same address could accept invalid
signatures.

Required: enforce verifier immutability or recheck all pinned properties for
every security-sensitive verification.


### PG3 - Deterministic deployment reruns incompletely verify existing code — open

A predicted address containing code may be skipped without checking every
runtime bytecode identity and wrapper `ASSET_SUPPORT` immutable. A stale or
constructor-mismatched deployment could be accepted.

Required: verify released runtime hashes and all immutable dependencies on new,
partial, and resumed deployments.

### PG4 - Unbounded commit and total settlement work — partially mitigated

Terms have no contract-level asset-count bound. Funding still processes a
side's complete list in one commit, and a very large list may exceed block gas.
Same-chain payout execution is now bounded by caller-selected `maxAssets` and
resumable, so the complete list no longer has to settle in one transaction.
Large lists still increase the number and total cost of required calls.

Required: enforce a conservative term asset-count bound for commits and define
per-chain execution policy for settlement batch sizes.


### Prototype client secret storage is plaintext — production gap

Party files are permission-restricted but unencrypted. Secrets may still leak
through compromised hosts, backups, memory, telemetry, or operator mistakes.

### Observation depends on one configured RPC — production gap

The prototype authenticates receipts, blocks, events, protocol bindings, and
confirmation counts, but one RPC can provide a false or stale chain view.
Production needs explicit provider diversity and disagreement handling.

### Full demos use a verifier mock — production gap

The demos validate protocol plumbing, not real SHRINCS signature generation,
calldata size, verification gas, transaction feasibility, or production
verifier failures. A full real-verifier run is required before deployment.

### Mutable admission is conflated with structural term validity — open specification mismatch

The technical specification calls `ValidTerms` pure while including supported
assets, and then requires `ValidTerms` again for claims and reclaims. Solidity
checks structural asset validity in `validateTerms`, consults the mutable asset
allowlist only when committing, and intentionally permits settlement after an
asset is delisted. Rechecking mutable support during settlement would strand
existing escrow.

Required: define a pure `StructurallyValidTerms` predicate and separate mutable
`CommitAssetSupported` admission. A committed binding should imply prior
structural validity; claims and reclaims must not reconsult mutable admission.


### Reclaim horizons are unbounded — open

Solidity validates deadline ordering but permits impractically distant reclaim
releases, including values near `uint256` maximum.

Required: impose contract or deployment-policy bounds and reject unsafe terms in
all clients.


### Transaction broadcast precedes durable journaling — open

Commit, claim, and reclaim transactions can be broadcast before their journal
entry is durable. A crash may leave a pending or mined transaction without a
local hash, and stale workspace locks can block later commands.

Required: persist intent and sender nonce before broadcast, reconcile from
chain afterward, add binding-aware recovery scanning, and define safe stale-lock
recovery.


### Permanently failing asset can strand its selected HTLC — design limitation

Same-chain claim or reclaim selection is irreversible, and each HTLC can then
settle independently in bounded batches. A permanently failing asset or
recipient can leave only that HTLC pending indefinitely. It cannot roll back a
completed payout on the other side, but the trade cannot reach terminal state
and the failing side cannot switch to the opposite outcome.

## To fix


### Supported remote chains are enforced only by clients — open specification mismatch

The specification says `ValidTerms` requires supported chain identifiers.
Solidity requires nonzero identifiers and verifies only that the selected local
side equals `block.chainid`; the SDK timing policy performs the supported-chain
check. A locally valid commit can therefore bind a nonexistent or unsupported
remote chain if a signer bypasses the conforming client.

Required: classify remote-chain support as an explicit client/deployment
predicate, or add an on-chain supported-chain policy if contract enforcement is
required.



### Mutable asset admission can strand an accepted trade — partially mitigated

An administrator can delist the second-side asset after agreement or after the
first leg commits. The second commit then fails and the funded party must wait
for reclaim. Ownership renunciation can permanently freeze a bad allowlist.

Required: define governance and emergency policy, forbid unsafe renunciation,
and warn and recheck immediately before commits. Stronger stability requires an
allowlist epoch or adapter version bound to the trade.

### Adversarial or changing assets can violate custody assumptions — partially mitigated

The allowlist and balance checks cannot make malicious, upgradeable, rebasing,
callback-abusive, dishonest, or misclassified tokens safe. A negative rebase or
blocked transfer can make a dedicated HTLC unpayable.

Required: narrowly govern exact `(assetType, target)` entries, monitor upgrades,
and use audited adapters where necessary.



## Intentional simplifications


### Live commitment-fee changes can race pending commits — open

The commitment fee is mutable, is read at execution time, and is not bound into
the signed protocol terms or commit payload. An owner can change it after a
caller obtains a quote, including between the two commits of a same-chain
trade. The wrapper then rejects the pending transaction because its `msg.value`
no longer equals the native escrow plus the current fee.

This is a retryable availability and fee-slippage problem rather than permanent
fund loss: the caller can read the new fee and resubmit, and `MAX_FEE` caps the
charge. Repeated owner changes can nevertheless disrupt a pending second leg
while the first leg remains escrowed until settlement or reclaim.

Required: bind an `expectedFee` or `maxFee` into commit submission, or introduce
a delayed fee update or per-trade fee snapshot. Until then, clients must refresh
the quote immediately before submission and clearly surface fee-related retry
failures.

### Timing-policy enforcement is a trusted-client assumption — open

The current Solidity prototype intentionally omits a signed on-chain timing-policy
identifier and does not resolve route timing policy inside wrappers.
Contracts enforce only structural deadline ordering and local-chain predicates;
chain-pair support and directional final-claim safety margins are validated by
client software before authorization and submission.

Consequently, the contracts can accept structurally valid terms that a
conforming client should reject as timing-unsafe. **This is an intentional
prototype simplification for gas efficiency, but it moves part of admissibility
from the contracts into the trusted client.**

Required: document the split explicitly everywhere the prototype is described,
define a clear client-side timing-safety predicate, and ensure every supported
signing or submission path applies it before producing commit authorization.


### Settlement validity is cached only implicitly — open proof refinement

The technical predicates require `ValidTerms` on every claim and reclaim.
Solidity does not rerun structural validation during settlement; it relies on
the fact that the `(TradeID, Lock, side)` or `(TradeID, Lock)` state key could
only have been created by a valid commit. This is safe under the terms-hash
binding assumption but is not stated in the specification or proof refinement.

Required: specify and prove that committed state implies structural validity at
commit time and that collision-resistant keyed lookup binds settlement to those
same terms.


### Canonical vectors are not executable sources of truth — open conformance gap

The checked-in canonical JSON still exposes the removed timing-policy identifier,
while current Solidity terms omit it and current SDK documentation treats it as removed. The
Solidity and SDK conformance tests do not load that JSON, so the file can drift
without failing either suite.

Required: regenerate vectors for the selected timing-policy model and make both
Solidity and SDK tests consume the same checked-in values.

### Solidity and SDK accept zero side nonces — resolved

Solidity term validation and the SDK protocol validator reject zero `sideNonce`
values on either side in both modes. Clients must resample zero outputs and
remain responsible for cryptographically random per-run nonces. The check
catches an obvious generation failure; it does not prove randomness or
uniqueness, add a nonce registry, or consume side nonces.

### Wrapper addresses are valid payout destinations — resolved

Both wrappers reject the executing wrapper as a local claim or reclaim
recipient before accepting custody. Same-chain commits check both sides before
the first escrow; cross-chain commits check only the committing chain's side.
The SDK applies the same case-insensitive address check when preparing commit hashes
and before quoting or submitting direct, wallet, or registration commits.
Remote-chain destinations are not rejected merely for matching the local
wrapper address. Existing settlement remains available.


### Authorization component names describe a superseded split — resolved

Protocol, technical specification, proof model/map, and prototype plans now use
`DirectAuthorization` for the single contract implementing both identity-registry
and direct commit gateway roles. Deployment documentation identifies the same
instance as the wrappers' `DIRECT_AUTHORIZATION` dependency. The proof-to-code
mapping preserves distinct registry-operation and commit-authorization nonce
scopes and stores without implying separate contract deployments or completed
boundary soundness proofs.