# Remaining issues

This is the current prototype issue tracker. It lists known unresolved security,
liveness, deployability, and operational weaknesses. It is not exhaustive and
does not replace an independent audit.

Status meanings: **open** requires an implementation or specification change;
**partially mitigated** has safeguards but retains material residual risk;
**production gap** is intentionally outside the local prototype.

## KI: Known Issues from v1

### KI01 - Settlement-secret disclosure can break cross-chain atomicity — partially mitigated

If the settlement secret leaks before both intended commits are stable, a
committed leg may be claimed while the opposite leg is absent or later
reclaimed. The local HTLC predicate cannot verify remote-chain readiness.

Mitigation: fresh secrets, restricted storage, authenticated observations, and
first revealing through an accepted counterparty-side claim after Bob's exact
commit is stable. Residual device, logging, backup, and application compromise
remains.

### KI02 - Final-claim delivery and finality are not guaranteed — partially mitigated

After the revealing claim, an executor must land and finalize the opposite
claim before its claim deadline. Censorship, congestion,
reorganization, delayed observation, or bad timing calibration can produce an
asymmetric `(Claimed, Reclaimed)` outcome.

Mitigation: conservative deadlines, multiple funded permissionless executors,
rapid fee bumping, and chain-specific finality policies.

---

## IS: Intentional simplifications


### IS01 - Bob-commit finality is an off-chain policy — partially mitigated

Alice's commit publishes `BobCommitSecret` immediately. Bob's client waits for
configured finality, but the destination contract cannot verify the remote
commit. Incorrect policy, compromised software, false RPC observations, or
client bypass can leave Bob escrowed after Alice's commit reorganizes away.


### IS02 - Live commitment-fee changes can race pending commits — open

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

### IS03 - Directional final-claim margin — enforced; calibration remains operational

Cross-chain admission now requires
`counterpartySide.claimDeadline + FINAL_CLAIM_DELAY <= partySide.claimDeadline`
on each cross-chain wrapper deployment. `FINAL_CLAIM_DELAY` is a nonzero
immutable deployment parameter.
The SDK enforces the same inequality using `counterpartyToPartyDelay` before
workflow authorization, in addition to its existing reclaim margins. The
reproduced schedule (party claim 300, counterparty claim 320, delay 10) is
rejected; equality at the required margin is accepted and tested through both
payouts after a last-moment reveal.

The supported direction is Alice revealing on the counterparty leg, then Bob
claiming the party leg. The settlement secret must first become available
through that accepted reveal after both commits are safely established.
Arbitrary early disclosure or the opposite first-reveal direction is outside
this completion guarantee.

Required for production: review the immutable budget for every supported route,
including finality, observation, relay, transaction inclusion, and timestamp
skew. Clients must use a reviewed `counterpartyToPartyDelay` at least as large
as both wrappers' on-chain values. Route support and the SDK's additional
reclaim margins remain client policy; contracts do not resolve a route policy.
See [the timing argument](protocol-flow.md#cross-chain-final-claim-window).

### IS04 - Supported remote chains are enforced only by clients — open specification mismatch

The specification says `ValidTerms` requires supported chain identifiers.
Solidity requires nonzero identifiers and verifies only that the selected local
side equals `block.chainid`; the SDK timing policy performs the supported-chain
check. A locally valid commit can therefore bind a nonexistent or unsupported
remote chain if a signer bypasses the conforming client.

Required: classify remote-chain support as an explicit client/deployment
predicate, or add an on-chain supported-chain policy if contract enforcement is
required.

---

## PG: Production gaps

### PG01 - Full demos use a verifier mock — production gap

The demos validate protocol plumbing, not real SHRINCS signature generation,
calldata size, verification gas, transaction feasibility, or production
verifier failures. A full real-verifier run is required before deployment.

### PG02 - Verifier identity is not rechecked on every use — open

Registered-direct admission pins verifier address, code hash, version, and
profile, but later signature paths do not recheck every property. A mutable
proxy or metamorphic verifier at the same address could accept invalid
signatures.

Required: enforce verifier immutability or recheck all pinned properties for
every security-sensitive verification.


### PG03 - Wallet-mode authorization provenance — open

Wrappers do not prove that a wallet-mode caller is an approved QuipWallet
implementation that performed PQ verification. An EOA or arbitrary contract
named as the wallet principal may fabricate authorization evidence and bypass
PQ commit authorization.

Required: authenticate wallets through a **pinned factory**, registry,
implementation, or dedicated gateway, and test EOA and malicious-wallet
masquerading.


### PG04 - Prototype client secret storage is plaintext — production gap

Party files are permission-restricted but unencrypted. Secrets may still leak
through compromised hosts, backups, memory, telemetry, or operator mistakes.

### PG05 - Observation depends on one configured RPC — production gap

The prototype authenticates receipts, blocks, events, protocol bindings, and
confirmation counts, but one RPC can provide a false or stale chain view.
Production needs explicit provider diversity and disagreement handling.

### PG06 - Deterministic deployment reruns incompletely verify existing code — open

A predicted address containing code may be skipped without checking every
runtime bytecode identity and wrapper `ASSET_SUPPORT` immutable. A stale or
constructor-mismatched deployment could be accepted.

Required: verify released runtime hashes and all immutable dependencies on new,
partial, and resumed deployments.

### PG07 - Reclaim horizons are unbounded — open

Solidity validates deadline ordering but permits impractically distant reclaim
releases, including values near `uint256` maximum.

Required: impose contract or deployment-policy bounds and reject unsafe terms in
all clients.


### PG08 - Transaction broadcast precedes durable journaling — open

Commit, claim, and reclaim transactions can be broadcast before their journal
entry is durable. A crash may leave a pending or mined transaction without a
local hash, and stale workspace locks can block later commands.

Required: persist intent and sender nonce before broadcast, reconcile from
chain afterward, add binding-aware recovery scanning, and define safe stale-lock
recovery.


### PG09 - Canonical vectors are not executable sources of truth — open conformance gap

The checked-in canonical JSON still exposes the removed timing-policy identifier,
while current Solidity terms omit it and current SDK documentation treats it as removed. The
Solidity and SDK conformance tests do not load that JSON, so the file can drift
without failing either suite.

Required: regenerate vectors for the selected timing-policy model and make both
Solidity and SDK tests consume the same checked-in values.

### PG10 - QuipWallet cannot receive standard NFT safe transfers — open

`QuipWallet` implements neither ERC-721 nor ERC-1155 receiver callbacks. Reproduction tests confirmed that standard safe transfers of both token types to the wallet revert.

This prevents normal ERC-1155 funding and NFT payouts to the wallet. An ERC-721
deposited through an unsafe transfer can subsequently be committed, but
reclaim to that wallet would fail. Same-chain settlement targeting the wallet
can remain pending.

The documentation describes generic recipient compatibility but does not
identify the supplied wallet as incompatible.

Required: add the standard receiver interfaces and test wallet funding, claim,
and reclaim for both ERC-721 and ERC-1155 assets.

---

## Asset Support issues


### AS01 - Mutable asset admission can strand an accepted trade — partially mitigated

An administrator can delist the second-side asset after agreement or after the
first leg commits. The second commit then fails and the funded party must wait
for reclaim. Ownership renunciation can permanently freeze a bad allowlist.

Required: define governance and emergency policy, forbid unsafe renunciation,
and warn and recheck immediately before commits. Stronger stability requires an
allowlist epoch or adapter version bound to the trade.

### AS02 - Adversarial or changing assets can violate custody assumptions — partially mitigated

The allowlist and balance checks cannot make malicious, upgradeable, rebasing,
callback-abusive, dishonest, or misclassified tokens safe. A negative rebase or
blocked transfer can make a dedicated HTLC unpayable.

Required: narrowly govern exact `(assetType, target)` entries, monitor upgrades,
and use audited adapters where necessary.

### AS03 - Permanently failing asset can strand its selected HTLC — design limitation

Same-chain claim or reclaim selection is irreversible, and each HTLC can then
settle independently in bounded batches. A permanently failing asset or
recipient can leave only that HTLC pending indefinitely. It cannot roll back a
completed payout on the other side, but the trade cannot reach terminal state
and the failing side cannot switch to the opposite outcome.


### AS04 - Unbounded commit and total settlement work — partially mitigated

Terms have no contract-level asset-count bound. Funding still processes a
side's complete list in one commit, and a very large list may exceed block gas.
Same-chain payout execution is now bounded by caller-selected `maxAssets` and
resumable, so the complete list no longer has to settle in one transaction.
Cross-chain claim and reclaim still call `SwapHTLC.release` for the complete
local-side bundle in one transaction. A bundle may therefore fit within the
commit gas limit but exceed the later cross-chain settlement gas limit, leaving
that HTLC unable to claim or reclaim. Even where batching is available, large
lists increase the number and total cost of required calls.

Required: enforce a conservative term asset-count bound for commits, make
cross-chain release resumable or prove an admission bound sufficient for both
commit and payout, and define per-chain execution policy for settlement batch
sizes.


### AS05 - Mutable admission is conflated with structural term validity — open specification mismatch

The technical specification calls `ValidTerms` pure while including supported
assets, and then requires `ValidTerms` again for claims and reclaims. Solidity
checks structural asset validity in `validateTerms`, consults the mutable asset
allowlist only when committing, and intentionally permits settlement after an
asset is delisted. Rechecking mutable support during settlement would strand
existing escrow.

Required: define a pure `StructurallyValidTerms` predicate and separate mutable
`CommitAssetSupported` admission. A committed binding should imply prior
structural validity; claims and reclaims must not reconsult mutable admission.


### AS06 - Forced native balance has no accounting or recovery path — design limitation

The wrappers have no payable `receive` or `fallback`, so an ordinary native
transfer outside a commit is rejected. Native currency can nevertheless be
forced into a wrapper, for example through a protocol mechanism that does not
execute the recipient. This value is not an accepted commitment fee and is not
recorded in `accruedFees`.

`withdrawFees` deliberately transfers only the recorded `accruedFees`
snapshot, preventing the owner from sweeping escrow or unrelated balance.
Consequently, forced or otherwise unaccounted native balance remains in the
wrapper permanently under the current interface.

Required: either retain this behavior as an explicit non-recoverability policy,
or add a narrowly scoped excess-balance recovery function that can withdraw no
more than `address(this).balance - accruedFees` and cannot affect HTLC-held
escrow.
