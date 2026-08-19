# QUIP Swap Architecture

## Overview

QUIP Swap is a trustless atomic-swap system built around a single **`Omnibus`** contract. Two parties exchange assets — native, ERC-20, ERC-721 or ERC-1155 — either on one chain or across two, coordinated by a shared hashlock. Authorization is post-quantum capable: commits are endorsed through **ERC-7913 signature verifiers** (the SHRINCS/XMSS verifier from `@quip.network/hashsigs-solidity`), or by a wallet deployed from the quip **`WalletFactory`**, which reaches `commit` only from its own PQ-authenticated execute flow.

There is one deployable artifact. `TermsLib` is an all-`internal` library and inlines into the caller — it is never deployed or linked separately.

```
┌────────────────────────────────────────────────────────────────────────────────┐
│                             QUIP SWAP SYSTEM                                   │
│                                                                                │
│   ┌──────────────────────────┐              ┌────────────────────────────┐     │
│   │        Omnibus           │  uses        │        TermsLib            │     │
│   │ (singleton, Ownable2Step │─────────────►│  (internal library,        │     │
│   │  escrow + lock registry) │              │   inlined — not deployed)  │     │
│   └──────────────────────────┘              └────────────────────────────┘     │
│         │                │                                                     │
│  commit │                │ authorization (view-only, STATICCALL)               │
│         │                ▼                                                     │
│         │   ┌────────────────────────┐      ┌────────────────────────────┐     │
│         │   │ IERC7913SignatureVerif.│      │      IWalletFactory        │     │
│         │   │  KEYED route           │      │  WALLET route              │     │
│         │   │  (owner-activated)     │      │  (vaultIdOf != 0)          │     │
│         │   └────────────────────────┘      └────────────────────────────┘     │
│         ▼                                                                      │
│   escrowed assets: native / ERC-20 / ERC-721 / ERC-1155                        │
│                                                                                │
└────────────────────────────────────────────────────────────────────────────────┘
```

The same `Omnibus` address exists on every chain — see [Deployment](#deployment).

---

## Contract Hierarchy

### Omnibus (`src/Omnibus.sol`)

`contract Omnibus is IOmnibus, IERC721Receiver, IERC1155Receiver, Ownable2Step`

The singleton. Holds escrowed assets, tracks lock state, and settles swaps.

| Member | Kind | Purpose |
|---|---|---|
| `VERSION` | `constant uint256` = 0 | Implementation version. Version scoping comes from `address(this)` in the domain — each version deploys at a distinct CREATE3 address. |
| `MAX_FEE` | `constant uint256` = 0.01 ether | Ceiling on `commitmentFee`; `setCommitmentFee` reverts above it. |
| `COMMIT_DIGEST_TAG` | `constant bytes32` | `keccak256('QUIP:Omnibus:commit')`. No version suffix — see `VERSION`. |
| `DOMAIN_SEPARATOR` | `immutable bytes32` | `keccak256(abi.encode(COMMIT_DIGEST_TAG, block.chainid, address(this)))`, baked at construction. The replay scope. |
| `WALLET_FACTORY` | `immutable IWalletFactory` | The quip WalletFactory the wallet route trusts. Zero reverts `ZeroFactory()`. |

**Constructor:** `constructor(address initialOwner, address walletFactory)`. Both are dependency-injected; nothing is hardcoded. Neither affects the deployed address (CREATE3 ignores init code), so owner and factory may differ per chain while the address does not.

**External entry points**

| Function | Access | Purpose |
|---|---|---|
| `commit(lock, party, counterparty, auth)` | permissionless, `payable` | Escrows one side of a swap. `msg.sender` **funds**; the identity in `auth` **authorizes**. |
| `claim(secret, party, counterparty)` | permissionless | Reveals the preimage and settles. |
| `reclaim(lock, party, counterparty)` | permissionless | Returns escrowed assets after `reclaimRelease`. |
| `commitDigest(lock, party, counterparty, signerHash)` | `view` | The exact digest a keyed identity must endorse. |
| `setVerifierActivity(verifier, active)` | `onlyOwner` | Activates/deactivates an ERC-7913 verifier. |
| `setCommitmentFee(newFee)` | `onlyOwner` | Sets the per-commit fee, capped at `MAX_FEE`. |
| `withdrawFees(to)` | `onlyOwner` | Withdraws **only** `accruedFees`; escrowed native stays owed. |

Also implements `onERC721Received`, `onERC1155Received`, `onERC1155BatchReceived`, `supportsInterface`, and a bare `receive()`.

### TermsLib (`src/TermsLib.sol`)

All functions `internal`. Owns terms validation, digesting, and asset movement:

- `digestTerms`, `digestTermsCanonically` — per-side and order-independent pair digests
- `validateTerms`, `validateAsset`, `validateAssets`, `validateTermPairing`
- `enforceChainId`, `enforceNonZeroChainId`, `enforceWithin`
- `transferAsset`, `transferAssets`, `transferAssetsNoNative`, `totalNative`, `heldBalance`
- `proposedByParty`

### Interfaces

- **`IOmnibus`** — the `LockState` enum, the `CommitAuth` struct, and all errors/events.
- **`IWalletFactory`** — one method, `vaultIdOf(address wallet) returns (bytes32)`. Non-zero **iff** the address was deployed by the factory; written once and never revocable, so it is a durable membership discriminator.

---

## Data Structures

### Assets

```solidity
enum AssetType { Native, ERC20, ERC721, ERC1155 }

struct Asset {
  AssetType assetType;
  address   target;   // asset contract; zero for native
  uint256   id;       // ERC-721 / ERC-1155 only
  uint256   amount;   // native / ERC-20 / ERC-1155 only
}
```

### Terms

```solidity
struct Terms {
  uint256 chainId;            // chain where THESE assets are held
  address reclaimRecipient;   // receives this side's assets on reclaim
  address recipient;          // receives the COUNTERPARTY's assets on claim
  uint256 commitmentDeadline; // commit forbidden after
  uint256 claimDeadline;      // claim forbidden after
  uint256 reclaimRelease;     // reclaim permitted after
  Asset[] assets;
}
```

Deadlines must be strictly increasing (`DisordedDeadlines` otherwise). Each side carries its own `chainId`, which is what makes a cross-chain pairing expressible in one struct pair.

### Authorization

```solidity
struct CommitAuth {
  bytes signer;     // ERC-7913 identity: verifier(20 bytes) ‖ key
  bytes signature;  // over commitDigest; EMPTY selects the wallet route
}
```

### Lock state

```solidity
enum LockState { Unused, Free, Committed, Spent }
```

---

## Lock State Machine

A lock is `keccak256(secret)`. State advances through `_advanceLockTo`, which whitelists transitions and reverts `InvalidLockAdvancement` on anything else — this is also what makes reentrant settlement fail, since the lock is marked `Spent` before assets move.

```
                    ┌─────────┐
                    │ Unused  │
                    └────┬────┘
          same-chain     │      cross-chain
        (first commit)   │     (single commit)
              ┌──────────┴──────────┐
              ▼                     ▼
         ┌────────┐            ┌───────────┐
         │  Free  │───────────►│ Committed │
         └────┬───┘  2nd commit└─────┬─────┘
              │   (other side posts) │
              │                      │
              └──────────┬───────────┘
                         ▼
                    ┌─────────┐
                    │  Spent  │  terminal (claimed or reclaimed)
                    └─────────┘
```

- **Same-chain**: both sides' `chainId` match, so the first `commit` lands in `Free` and the second advances to `Committed`. Re-posting the same side reverts `TermsAlreadyPosted`.
- **Cross-chain**: a single `commit` on each chain goes straight to `Committed`; the counterparty's commit is on another chain and is not on-chain observable. The party is responsible for confirming it before committing.

Alongside the state, `commit` records `posted[lock][termsDigest] = true` for the side it escrows. Settlement re-checks `posted` for each side it pays out (`TermsNotPosted`), so a lock can never disburse a side that was never funded.

---

## Authorization Model

`_enforceCommitAuthorized` is view-only and resolves to `STATICCALL`s, so it adds no reentrancy surface.

**Identities attribute; they do not gate.** The endorsement proves that this exact payload was endorsed by the declared identity. It does **not** restrict which identity may post a side. Counterparty-identity policy, where a client wants it, belongs off-chain against the `Commitment` event.

A shared shape gate comes first: the only accepted identity is ERC-7913 keyed, `verifier(20 bytes) ‖ key`. Anything 20 bytes or shorter — including a bare address — reverts `MalformedSigner`. Two routes then diverge on whether `signature` is empty:

| | KEYED route (`signature` non-empty) | WALLET route (`signature` empty) |
|---|---|---|
| Check | Declared verifier must be owner-activated, and `verify(key, digest, sig)` must return its selector | `WALLET_FACTORY.vaultIdOf(msg.sender)` must be non-zero |
| Digest verified? | Yes | No — a vetted wallet only reaches `commit` from its PQ-authenticated execute flow, so factory membership stands in for the endorsement |
| Signer blob | Cryptographically bound | **Attribution only.** Its verifier prefix is neither activity-checked nor consulted |
| Sender model | Permissionless: anyone may fund | Collapses to `msg.sender == quip wallet` |
| Failure | `VerifierNotActive`, `InvalidCommitSignature` | `NotQuipWallet` |

---

## Digests

### Per-side and canonical terms

`digestTerms(terms)` hashes one side. `digestTermsCanonically(party, counterparty)` hashes both **in sorted order** (smaller digest first), so the pair digest is identical regardless of which side calls. That value is stored once in `termsHash[lock]` on the first commit and re-checked on every later interaction (`TermsMismatch`), which is what binds both legs to a single negotiated pairing.

### Commit digest

```solidity
keccak256(abi.encode(DOMAIN_SEPARATOR, lock, partyTerms, counterpartyTerms, signerHash))
```

Raw tagged keccak, deliberately not EIP-712: every honest signer in this stack signs raw 32-byte digests. `commit` and the public `commitDigest` view share the one code path — there is no inline re-derivation to drift.

It binds the full context: which swap instance (`lock`), which side is being posted (`partyTerms`), the whole negotiated pairing (`counterpartyTerms`), the declared identity (`signerHash`), and the replay scope (`DOMAIN_SEPARATOR` — tag + chainid + address). **Do not narrow it**: bind less and signatures become liftable to another chain, another Omnibus version, or another side.

---

## Settlement Flows

### commit

1. `party.chainId` must equal `block.chainid`; both sides validated; pairing validated.
2. Proposer determined by `proposedByParty` — whichever side has the earlier `commitmentDeadline`.
   - Party proposed → the party's own commitment window must still be open.
   - Counterparty proposed → the counterparty's window must have **elapsed** and the party's must still be open.
3. `msg.value` must equal `party.totalNative() + commitmentFee` exactly (`IncorrectNativeAmountReceived`).
4. Authorization enforced against the commit digest.
5. Lock advanced; `commitmentFee` added to `accruedFees`; `posted[lock][partyDigest]` set.
6. Non-native assets pulled from `msg.sender`; native arrived with the call.
7. Emits `Commitment(lock, party, auth.signer, msg.sender)`.

### claim

Called by the party against the counterparty's terms. `lock` is derived from the revealed `secret`.

- The counterparty's terms **must** be on this chain (that is where the party gets paid); the party's terms may or may not be.
- Window depends on the proposer, as in `commit`.
- Lock must be `Committed`; advanced to `Spent` **before** any transfer.
- Counterparty's assets → `party.recipient`. If the party's side is also on this chain, the party's assets → `counterparty.recipient` in the same call, which is what prevents a same-chain double-spend.
- Emits `Claim(msg.sender, lock, secret)`.

### reclaim

- Only after `party.reclaimRelease`.
- Terms must match the stored canonical digest, and the party's side must have been posted.
- If the counterparty is on this chain **and** the lock is `Committed`, both sides are returned to their respective `reclaimRecipient`s; otherwise only the party's.
- Lock advanced to `Spent` before transfers. Emits `Reclaimed` per side returned.

---

## Storage Layout

Slot order as declared. `DOMAIN_SEPARATOR` and `WALLET_FACTORY` are `immutable` and live in code, not storage; `VERSION`, `MAX_FEE` and `COMMIT_DIGEST_TAG` are `constant`.

| Slot | Variable | Type |
|------|----------|------|
| 0 | `_owner` | `address` (`Ownable`) |
| 1 | `_pendingOwner` | `address` (`Ownable2Step`) |
| 2 | `commitmentFee` | `uint256` |
| 3 | `accruedFees` | `uint256` |
| 4 | `lockState` | `mapping(bytes32 => LockState)` |
| 5 | `termsHash` | `mapping(bytes32 => bytes32)` |
| 6 | `posted` | `mapping(bytes32 => mapping(bytes32 => bool))` |
| 7 | `verifierActive` | `mapping(address => bool)` |

There is no proxy and no upgrade path: a new version is a new deployment at a new CREATE3 address, which is precisely why `DOMAIN_SEPARATOR` needs no version suffix.

---

## Deployment

`Omnibus` is deployed through the canonical [CreateX](https://github.com/pcaversaccio/createx) factory (`0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed`, pre-deployed on 100+ chains) using **CREATE3 with a sender-permissioned salt**. The address is a function of `(CreateX, DEPLOYER, salt)` only — independent of constructor args, identical on every chain, and claimable by nobody else.

```
salt    = [20 bytes DEPLOYER][0x00][11 bytes entropy]     entropy = keccak256(label)[0:11]
guarded = keccak256(abi.encode(DEPLOYER, salt))            ← CreateX MsgSender branch
proxy   = CREATE2(CreateX, guarded, keccak256(0x67363d3d37363d34f03d5260086018f3))
Omnibus = keccak256(0xd694 ‖ proxy ‖ 0x01)[12:]            ← proxy's nonce-1 CREATE
```

The `0x00` flag byte keeps `block.chainid` out of the guard, which is what makes the address chain-invariant. `0x01` would silently make it per-chain.

**The critical property:** a wrong caller does **not** revert inside CreateX. It fails the sender-prefix match, falls to the permissionless branch `keccak256(abi.encode(salt))`, and deploys *successfully* at an unrelated address. Everything below exists because that failure is silent.

- `script/Constants.sol` is the single source of truth for the salt math, and `DEPLOYER` is **compiled in** — not read from the environment. A prediction derived from the live signer would follow a wrong key to its wrong address and every post-deploy equality check would still pass.
- `script/DeployOmnibus.s.sol` runs every gate before broadcasting: build profile, signer identity, `tx.origin`, optional chain id, wallet-factory code and ABI, agreement between the local prediction and the factory's own `computeCreate3Address`, and a **semantic** occupancy check on the `WALLET_FACTORY`/`DOMAIN_SEPARATOR` immutables (a CREATE3 address ignores init code, so "has code" says nothing about what is there).
- Deploys build under `FOUNDRY_PROFILE=prod` — metadata stripped, dedicated `out-prod/`.
- `test/Constants/` locks the math: known-answer tests anchored to the live deployment, layout and anti-squat invariants, a registry lock against `sdk/src/deployments.json`, and an env-gated fork test that executes the real CreateX bytecode.

**Safe / multisig routing is unsupported by construction.** CreateX keys its guard off `msg.sender`, so a Safe-executed deploy lands somewhere else entirely. The address is bound to an EOA key, and that key is address-load-bearing: losing it makes those addresses unreachable on any chain not yet deployed to.

Deploy order per chain: the quip `WalletFactory` must already exist (it is baked in as an immutable and called at runtime), then `Omnibus`, then `setVerifierActivity` for each ERC-7913 verifier. See `README.md` for the runbook.

---

## Security Considerations

**Reentrancy.** Settlement advances the lock to `Spent` before transferring anything, so a reentrant `claim`/`reclaim` fails the transition whitelist. `_enforceCommitAuthorized` is view-only.

**Exact native accounting.** `commit` requires `msg.value` to match `totalNative() + commitmentFee` exactly. `withdrawFees` withdraws only `accruedFees` — escrowed native remains owed to `reclaimRecipient`s and is never withdrawable by the owner.

**Terms binding.** The canonical pair digest is stored on first commit and re-checked everywhere; `posted` gates every payout on that side having actually been funded.

**Signature liftability.** The commit digest binds tag, chain id, contract address, lock, both terms and the signer blob. Narrowing it re-opens cross-chain and cross-version replay.

**Cross-chain trust boundary.** A counterparty commit on another chain is not on-chain verifiable. The party must confirm it before committing; the contract only enforces deadline ordering.

**Owner powers.** The owner can activate/deactivate verifiers, set the fee (capped at `MAX_FEE`), and withdraw accrued fees. It cannot touch escrow, move locks, or upgrade the contract. `Ownable2Step` makes handover explicit.

**Fee-on-transfer tokens.** `commit` escrows what actually arrives; a token that skims on transfer will under-deliver at settlement. Vet asset contracts off-chain — the swap terms are whatever the two sides agreed.

---

## Dependencies

| Dependency | Version | Used for |
|---|---|---|
| `forge-std` | 1.14.0 | Test and script harness |
| `solady` | 0.1.26 | `SafeTransferLib`, `EfficientHashLib`, `CREATE3` (address prediction) |
| `@openzeppelin-contracts` | 5.6.0-rc.1 | `Ownable2Step`, ERC-721/1155 receivers, ERC-165 |
| `@quip.network/hashsigs-solidity` | 0.2.0 (git rev-pinned) | `IERC7913SignatureVerifier`; SHRINCS/XMSS PQ verifier |

Managed by [soldeer](https://soldeer.xyz) under `dependencies/` — there is no `lib/`. Compiled with solc 0.8.33, `evm_version = prague`, `optimizer_runs = 10_000`.

`UXMSS.sol` from hashsigs is pinned to a `via-ir` compilation profile (it is stack-too-deep otherwise). That restriction propagates to every compilation unit including it — the SHRINCS integration suite — but `src/` imports only the dependency's interfaces and stays on the default pipeline, so production artifacts are unaffected.

---

## Repository Map

```
src/
├── Omnibus.sol                  # the singleton (only deployable artifact)
├── TermsLib.sol                 # internal library, inlined
└── interfaces/{IOmnibus,IWalletFactory}.sol

script/
├── Constants.sol                # salt math — single source of truth
├── ICreateX.sol                 # minimal CreateX interface
├── DeployOmnibus.s.sol          # gated deploy
├── VerifyOmnibus.s.sol          # offline registry check (every row)
└── ActivateVerifier.s.sol       # post-deploy owner action

test/
├── Omnibus/{behaviors,integration,scenario}/
├── TermsLib/behaviors/
├── Constants/{behaviors,integration}/   # salt + CreateX guard
├── attack/                              # adversarial scenarios
└── {harness,mocks,utils}/               # SaltRef.sol lives in utils/

sdk/                             # TypeScript SDK; deployments.json is the registry
```
