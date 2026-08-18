# QUIP Solidity Architecture

## Status and scope

This document describes the current v1.1 multi-contract prototype in `src/`.
It supports atomic exchange of native currency, ERC-20, ERC-721, and ERC-1155
assets on one chain or across two chains. Commit admission uses post-quantum
(PQ) authorization; settlement uses trade-bound hashlock secrets and signed
deadlines.

`Omnibus.sol`, `interfaces/IOmnibus.sol`, and the old `Terms` functionality
in `legacy/TermsLib.sol` remain for comparison and regression testing. They are not the current integration or deployment
surface. The current implementation does
not use the former QuipPortal/minimal-clone architecture.

The normative design is under `../../interlock-ec/dev/v1.1/protocol/`,
especially `protocol.md` and `technical-spec.md`. This document maps that
design to Solidity.

## Source layout

- `src/protocol/` contains the v1.1 terms model, hashing, state machines,
  commit validation, settlement, and wrappers. Related internal libraries share
  `CommitValidation.sol` and `StateMachines.sol` source units while retaining
  their library names.
- `src/authorization/` contains wallet and registered-direct PQ admission.
- `src/assets/` contains asset admission, support configuration, and custody helpers.
- `src/interfaces/` contains cross-component interfaces.
- `src/legacy/` isolates the v1.0 Omnibus implementation and terms library.

## System map

```text
                         OFF-CHAIN CLIENT
                               |
                  canonical terms and PQ signature
                               |
             +-----------------+-----------------+
             |                                   |
      QuipWallet                         DirectAuthorization
      (wallet mode)                      (registered-direct mode)
             +------------- verified evidence --+
                               |
               +---------------+---------------+
               |                               |
      SameChainWrapper                CrossChainWrapper
               |                               |
      SameChainStateMachine           CrossChainStateMachine
               |                               |
               +---------- Settlement --------+
                               |
                         AssetCustody

Shared validation:
  ProtocolTypes + ProtocolHashing + CommitAuthorization
  + ProgressionGate + AssetSupportRegistry
```

Authorization contracts authenticate who approved a commit. Wrappers do not
verify PQ signatures themselves. They accept calls only from the authorization
boundary named by the signed terms and independently reconstruct the signed
payload. Wrappers own escrow, swap state, nonce consumption, and settlement
entry points.

## Canonical trade model

### `protocol/ProtocolTypes.sol`

Defines the shared data model:

- `AuthorizationMode`: QuipWallet or RegisteredDirect.
- `DelegationPolicy`: no delegation, permissionless relay, or a specific
  registered delegate.
- `WrapperMode`: same-chain or cross-chain.
- `SideTag`: party or counterparty.
- `ExpectedSourceState`: the transition source state signed into a commit.
- `CrossChainLegState` and `SameChainState`: settlement state enums.
- `SideTerms`: one side's principal, destinations, chain, assets, deadlines,
  authorization settings, commit lock, and nonce.
- `ProtocolTerms`: the two signed side-term records.
- Commit request, payload, and verified-evidence structures.
- PQ identity registration, rotation, recovery, and revocation structures.

`recipient` receives assets after claim. `reclaimRecipient` receives the
side's own assets after timeout. These destinations need not be principals and
cannot be changed by the transaction caller.

### `protocol/ProtocolHashing.sol`

Provides domain-separated hashes and static term validation:

- `tradeId` commits to all immutable protocol terms.
- `gateContextId` identifies the counterparty progression-gate context.
- `commitLock` binds Bob's cross-chain progression secret.
- `settlementLock` binds the settlement secret to one trade.
- `assetHash` commits to one side's exact canonical asset list.
- `commitPayloadHash` binds chain, wrapper, verifier, trade, lock, side,
  source state, assets, principal, delegation, action nonce, and expiry.
- Nonce encoders separate commit and registry replay domains.
- `validateTerms` implements the specification's static `ValidTerms(T)`.

Validation checks addresses, enum and authorization shapes, canonical assets,
deadline ordering, chain mode, and progression fields. Cross-chain terms must leave each claim deadline no later than the opposite reclaim release. Clients apply any stronger route-specific finality and reaction margins before signing or submitting terms.

## Authorization

Both authorization modes produce the same canonical payload and
`VerifiedCommitAuthorization` evidence for the wrapper.

### `authorization/wallet/QuipWallet.sol`

The wallet-mode authorization boundary. It reconstructs the commit payload,
verifies the active PQ key, identifies the authenticated submitter, and forwards
the request, evidence, and native value to a wrapper. It supports active-key
rotation using old-key authorization plus new-key proof of possession.
`execute` remains controlled by the classical owner. Wallet key epochs are
internal; wallet-mode terms use principal key version zero.

### `authorization/direct/DirectAuthorization.sol`

Maps an EOA to independently versioned active and recovery PQ keys. It pins the
trusted verifier by address, code hash, version tag, and profile tag so an
encoded key cannot choose arbitrary verifier behavior.

It supports atomic initial registration and first commit, active-key rotation,
recovery-key rotation, recovery of both keys, and revocation. Requests bind the
chain, registry, expected versions, proposed keys, action, nonce, and exclusive
expiry. Newly installed keys prove possession. Failed registration-and-commit
calls revert registration, nonce, escrow, and swap state together.

### `authorization/shared/AuthorizationSubmitter.sol`

Derives the authenticated submitter and key version. Transaction sender,
principal, broker, and relayer can differ, so downstream code must not equate
`msg.sender` with the principal.

### `authorization/shared/KeyedVerifier.sol`

Parses an encoded keyed-verifier value, extracts its verifier contract, and
delegates digest/signature validation to it.

### Commit authorization `protocol/CommitValidation.sol`

The wrapper-side authorization check. It requires:

- the exact QuipWallet or configured direct authorization boundary selected by the terms;
- matching caller evidence;
- the correct signed source state;
- a live exclusive expiry;
- a submitter satisfying the signed delegation policy;
- a payload matching the wrapper's own reconstruction; and
- an unused, version-scoped action nonce.

Validation and nonce consumption are separate. Consumption happens only in the
successful commit transaction; a later revert rolls it back with state and
assets.

### Off-chain timing policy

The SDK timing policy is local configuration, not a protocol term. Before a user
signs or submits terms, the client checks the wrapper mode, ordered chain pair,
and directional finality and reaction margins against the signed deadlines.
Contracts enforce only intrinsic deadline ordering and do not store, identify,
or resolve timing policies. Different clients may require stronger margins, but
both still sign the same terms.

## Admission policy

### Asset admission `assets/AssetSupportRegistry.sol` and `assets/AssetHandling.sol`

The registry is an owner-managed allowlist keyed by asset type and token
address. Native currency needs no entry. `AssetSupport` checks each token
before a new commit. Delisting blocks future commits only; existing escrow
remains claimable and reclaimable.

## Secrets and progression

### Progression gate `protocol/CommitValidation.sol`

Enforces commit sequence separately from PQ approval:

- a cross-chain party commit needs no progression secret;
- a cross-chain counterparty commit must reveal `bobCommitSecret` matching its
  trade-bound `commitLock`;
- a same-chain party commit starts from `Unused`; and
- a same-chain counterparty commit requires local `PartyCommitted` state.

Bob's commit secret is not the settlement secret. It should be released after
observing adequate finality for the first commit. The settlement secret later
claims escrow and enables the final cross-chain claim.

## Escrow

### Asset custody `assets/AssetHandling.sol`

Collects and releases native currency and supported token standards. Collection
requires exact native value and exact token balance or ownership changes,
rejecting fee-on-transfer and other non-exact behavior. ERC-721 custody is one
unit.

Reserved amounts are tracked by asset identity. Because multiple swaps share a
wrapper, reservations prevent one trade from consuming another trade's funds.

### `protocol/ProtocolTypes.sol` and `legacy/TermsLib.sol`

`protocol/ProtocolTypes.sol` defines the canonical `AssetType` and `Asset` used by
the v1.1 protocol. The older `Terms`, pair-digest, and transfer helpers are
isolated in `legacy/TermsLib.sol` for Omnibus regression testing.

## State machines

### Cross-chain state machine `protocol/StateMachines.sol`

Each chain stores one local leg keyed by `(tradeId, lock, side)`:

```text
Unused -> Committed -> Claimed
                    -> Reclaimed
```

Commit stores a binding over trade, lock, side, terms, and assets. Settlement
must reproduce it. Terminal states cannot be reused. No remote-chain state is
read or proven.

### Same-chain state machine `protocol/StateMachines.sol`

A local trade is keyed by `(tradeId, lock)`:

```text
Unused -> PartyCommitted -> BothCommitted -> Claimed
             |                  |
             +-> Reclaimed      +-> Reclaimed
```

The first commit binds both asset lists and complete terms. The second must
match, preventing substitution after party assets enter escrow.

## `protocol/Settlement.sol`

Combines validation, state transitions, time windows, secret checks, and asset
release.

A cross-chain claim requires a committed local leg, local-chain binding,
`now < claimDeadline`, and a valid trade-bound preimage. Reclaim requires the
leg still be committed and `reclaimRelease <= now`.

Same-chain claim requires `BothCommitted` and atomically exchanges both sides.
Timeout paths return either the sole party commitment or both committed legs.
Claims and reclaims are permissionless because signed terms fix payouts.

## Wrappers

### `protocol/CrossChainWrapper.sol`

The escrow and orchestration contract for one local cross-chain leg. A commit
atomically:

1. resolves the policy and validates terms;
2. checks local chain and asset support;
3. validates commit authorization;
4. checks progression and commit time;
5. records `Committed`;
6. collects exact assets; and
7. consumes the authorization nonce.

It exposes permissionless claim/reclaim, state inspection, and reserved-balance
inspection.

### `protocol/SameChainWrapper.sol`

The equivalent contract when both sides are on one chain. The party commits
first, the counterparty second, and one claim exchanges both escrows atomically.
One-sided and dual reclaim paths handle timeouts. Both wrappers accept safe NFT
transfers and guard mutating entry points against reentrancy.

## End-to-end flows

### Same-chain

```text
Party authorization -> verify -> escrow party assets -> PartyCommitted
Counterparty auth    -> verify -> escrow its assets   -> BothCommitted
Settlement secret   -> verify -> exchange both sides -> Claimed
```

If the counterparty never commits, the party can reclaim after its release. If
both commit but no claim occurs, both legs can be reclaimed atomically.

### Cross-chain

```text
Chain A: party authorization -> party assets escrowed
Off-chain: observe finality -> release bobCommitSecret
Chain B: counterparty authorization + gate secret -> assets escrowed
Chain B: claim with settlement secret -> secret becomes public
Chain A: final claim with same secret -> remaining assets released
```

The wrappers never communicate. Atomicity depends on settlement-secret confidentiality before both commits. Each client must apply its configured chain-finality and reaction margins before accepting the signed deadlines; those operational margins are deliberately not represented or registered on chain. Each local leg can otherwise be reclaimed after its release.

## Interfaces

| File | Boundary |
| --- | --- |
| `ICommitAuthorizationReceiver.sol` | Wrapper callback after authorization. |
| `IRegisteredCommitTarget.sol` | Atomic registration-and-commit callback. |
| `IAssetSupportRegistry.sol` | Asset-support lookup. |
| `IProfiledPQVerifier.sol` | PQ verifier version/profile introspection. |
| `IWalletFactory.sol` | Legacy Omnibus wallet-factory boundary. |
| `IOmnibus.sol` | Legacy Omnibus types and interface. |

## Legacy Omnibus

`Omnibus.sol` combines authorization, terms hashing, lock state, escrow,
settlement, verifier administration, and fees. It uses legacy `Terms` and lock
states based on `Unused`, `Free`, `Committed`, and `Spent`.

The v1.1 design replaces that broad boundary with separate identity,
authorization, wrapper, custody, state-machine, and settlement
components. Omnibus scripts, tests, and SDK exports are legacy unless labeled
otherwise.

## Security boundaries and invariants

- **Canonical binding:** trades, payloads, locks, policies, assets, wrappers,
  and verifiers are domain-separated and signed or stored.
- **Trusted caller:** wrappers accept commits only from the selected wallet or
  configured authorization boundary.
- **Replay protection:** nonces include chain, verifier/registry, principal, key
  role/version, and action nonce.
- **Atomic rejection:** a revert rolls back state, custody, nonce, and lazy
  registration.
- **Exact custody:** asset changes must match signed terms, while reservations
  isolate concurrent trades.
- **Terminal states:** local escrow can be claimed or reclaimed at most once.
- **Permissionless settlement:** callers cannot redirect signed payouts.
- **Key lifecycle isolation:** key changes block future stale-key commits but do
  not strand committed escrow.
- **Cross-chain limitation:** contracts cannot observe remote state; secrets,
  finality observation, and timing margins supply the safety assumptions.

## External dependencies

- OpenZeppelin Contracts: ownership, receiver helpers, token interfaces, and
  reentrancy protection.
- Configured profiled PQ verifier: post-quantum signature checking.
- Foundry: compilation, deployment scripts, and Solidity tests.
