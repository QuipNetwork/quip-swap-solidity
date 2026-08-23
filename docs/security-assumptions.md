# Security assumptions and known limitations

The v1.1 code is a prototype. Passing tests and deterministic demos do not make
it production-ready. This is a concise risk summary, not a severity-ranked bug
tracker or remediation-status ledger.

## Protocol assumptions

- The settlement secret remains confidential until both intended commits are
  safely established. Earlier disclosure can enable one-sided settlement.
- `BobCommitSecret` is public in Alice's commit. Client-side finality gating can
  stop conforming clients from using it early, but cannot stop another actor
  from submitting Bob's already-authorized commit.
- Each chain enforces only local state and `block.timestamp`.
- The normative protocol design binds a timing-policy identifier into signed
  terms and treats route-specific final-claim safety margins as part of
  protocol-valid admission. The current Solidity prototype intentionally drifts
  from that design for gas efficiency: terms omit `timingPolicyId`, wrappers do
  not resolve or enforce route timing policy on-chain, and contracts validate
  only structural deadline ordering and local-chain predicates.
- As a result, timing-policy compatibility is a trusted-client assumption in
  the prototype. Conforming client apps are trusted to validate the supported
  chain pair and directional timing margins before producing or submitting
  commit authorizations. If a client is bypassed, misconfigured, inconsistent,
  or malicious, the contracts can still accept structurally valid but
  timing-unsafe terms.
- Cross-chain completion requires a funded executor to observe the revealing
  claim and land the final claim before its deadline.
- Confirmation counts and timing margins are operational assumptions, not
  objective economic finality.
- Solidity currently accepts zero `sideNonce` values even though the SDK
  rejects them. Contracts should reject zero to align validation and catch an
  obvious nonce-generation failure.

## Authorization assumptions

- The trusted PQ verifier must remain correct and immutable. Current signature
  paths do not recheck its pinned runtime code hash and metadata on every use.
- Wallet-mode wrappers do not yet authenticate an approved QuipWallet factory
  or implementation.
- Commit authorization nonces are consumed by the QuipWallet or direct
  authorization gateway before the wrapper callback. A rejected callback reverts
  that consumption with the transaction.
- Key revocation, verifier failure, or registry changes before a pending second
  commit can force the first side to wait for reclaim.

## Custody and liveness assumptions

- Only explicitly reviewed, exact-behavior token contracts may be allowlisted.
- Upgradeable, rebasing, fee-on-transfer, callback-heavy, or dishonest tokens
  can block settlement or invalidate accounting assumptions.
- Asset arrays and reclaim horizons are not contract-bounded. Excessive lists
  can exceed block gas; extreme timestamps can make recovery impractical.
- Atomic same-chain claim and dual reclaim fail completely if either payout
  fails.
- A local wrapper can currently be signed as `recipient` or
  `reclaimRecipient`; this can revert settlement or strand an ERC-721.
- Asset-support governance can delist a second-side asset after agreement or
  after the first cross-chain commit, forcing timeout recovery.

## Client and operational assumptions

- The prototype console stores secrets in owner-only plaintext files. It is not
  a production secret store.
- Local demos use deterministic public secrets, hard-coded Anvil keys, and a
  verifier mock.
- Observers use one configured RPC endpoint. Production needs an explicit RPC,
  reorganization, and finality policy.
- Transactions are currently broadcast before their journal entry is durable.
  A crash in that interval may require manual chain reconstruction.
- Workspace lock files may survive unclean process termination.

## Deployment assumptions

- CREATE3 address prediction does not prove bytecode or constructor bindings.
- The current rerun verifier does not check every runtime code identity or both
  wrappers' asset-support immutable.
- The verifier address must be reviewed for proxy or metamorphic behavior.
- Registry ownership, allowlisting, monitoring, and emergency procedures need
  production governance.

## Before production

At minimum, resolve the high-severity verifier, wallet provenance, and
deployment-verification gaps; bound settlement work and recovery horizons;
define asset and registry governance; add durable transaction recovery;
validate real PQ gas and signatures end to end; and complete an independent
security audit plus the planned EasyCrypt adversary model.
