# QUIP Architecture

## Overview

QUIP (Quick Interchange Protocol) is a trustless atomic swap system using WOTS+ (Winternitz One-Time Signature Plus) for quantum-resistant authorization. It enables secure asset exchanges between two parties, potentially across different chains.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              QUIP SYSTEM                                    │
│                                                                             │
│  ┌─────────────────┐         ┌─────────────────┐         ┌───────────────┐  │
│  │   QuipPortal    │ creates │      Quip       │  uses   │   TermsLib    │  │
│  │                 │────────►│    (Clone)      │────────►│   (Library)   │  │
│  └─────────────────┘         └─────────────────┘         └───────────────┘  │
│          │                          │                           │           │
│          │                          │                           │           │
│          ▼                          ▼                           ▼           │
│  ┌─────────────────┐         ┌─────────────────┐         ┌───────────────┐  │
│  │  IQuipPortal    │         │     IQuip       │         │  Data Types   │  │
│  │   (Interface)   │         │   (Interface)   │         │   & Structs   │  │
│  └─────────────────┘         └─────────────────┘         └───────────────┘  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Contract Hierarchy

### QuipPortal

The singleton portal contract responsible for deploying Quip instances.

```
QuipPortal
├── Constants/Immutables
│   ├── VERSION (constant)
│   ├── MAX_FEE (immutable)
│   └── QUIP_IMPLEMENTATION (immutable)
│
├── State
│   ├── creationFee
│   ├── accumulatedFees
│   ├── admin
│   └── pqOwnerState (mapping: bytes32 => PqOwnerState)
│
├── Modifier
│   └── onlyAdmin
│
├── Constructor
│   └── constructor(firstAdmin, quipImpl, maxFee, creationFee)
│
├── Public Functions
│   ├── deployCoupledQuip(pqOwner, terms)
│   ├── deployUncoupledQuip(pqOwner, terms)
│   ├── spendPqOwner(pqOwnerHash)
│   ├── withdrawFees(receiver, amount)
│   └── setCreationFee(newFee)
│
└── Internal Functions
    ├── _deployQuip(pqOwnerHash, deployer)
    ├── _enforceValidPqOwner(pqOwner, pqOwnerHash)
    ├── _advancePqOwner(pqOwnerHash)
    ├── _computePqOwnerHash(pqOwner)
    ├── _enforceQuipCaller()
    ├── _enforceNonEmptyAddress(addr)
    ├── _ensureCorrectNative(amount)
    ├── _validateQuipTerms(terms)
    ├── _validatePartyTerms(terms)
    └── _onlyAdmin()
```

### Quip (Clone Instance)

Individual swap contracts deployed as minimal clones.

```
Quip
├── Constants
│   └── VERSION
│
├── State
│   ├── pqOwner (WinternitzAddress)
│   ├── termsDigest (bytes32)
│   └── INIT_UNCOUPLED (bool)
│
├── Modifier
│   └── onlyPortal
│
├── Public Functions
│   ├── PORTAL_FROM_BYTECODE()
│   ├── pqOwner()
│   ├── pqOwnerHash()
│   ├── initializeCoupled(pqOwner, termsDigest)
│   ├── initializeUncoupled(pqOwner, termsDigest)
│   ├── coupleQuip(party, counterparty)
│   ├── claim(signature, terms)
│   └── reclaim(terms)
│
└── Internal Functions
    ├── _verifySignature(signature)
    └── _onlyPortal()
```

### TermsLib (Library)

Stateless library for terms handling and asset transfers.

```
TermsLib
├── Errors
│   ├── ZeroAmount
│   ├── InvalidNativeAsset
│   ├── InvalidERC20Asset
│   ├── InvalidERC721Asset
│   ├── InvalidERC1155Asset
│   ├── InvalidTerms
│   ├── TermsExpired
│   └── TermsNotExpired
│
└── Functions
    ├── digestPartyTerms(terms)
    ├── coupleTerms(party, counterparty)
    ├── digestTermsCanonically(terms) [calldata]
    ├── digestTermsCanonicallyMemory(terms) [memory]
    ├── verifyTerms(digest, terms)
    ├── executePartyCommitment(quip, recipient, assets)
    ├── releasePartyCommitment(quip, recipient, assets)
    ├── validateAsset(asset)
    ├── transferAsset(asset, from, to)
    ├── transferAssets(assets, from, to)
    ├── transferAssetsNoNative(assets, from, to)
    ├── totalNativeAmount(assets)
    ├── enforceTermFreshness(expiry)
    └── enforceTermStaleness(expiry)
```

---

## Data Structures

### Asset Types

```solidity
enum AssetType {
  Native,    // ETH or native chain currency
  ERC20,     // Fungible tokens
  ERC721,    // Non-fungible tokens
  ERC1155    // Multi-tokens
}

struct Asset {
  AssetType assetType;
  address target;      // Token contract (0x0 for Native)
  uint256 id;          // Token ID (ERC721/ERC1155)
  uint256 amount;      // Amount (Native/ERC20/ERC1155)
}
```

### Terms Structures

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                            PartyTerms                                       │
│                     (Single party proposal)                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│  signatory    │ address  │ The party's address (signer)                    │
│  recipient    │ address  │ Where counterparty's assets go                  │
│  expiry       │ uint64   │ Deadline for commitment                         │
│  assets       │ Asset[]  │ Assets being offered                            │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│                            QuipTerms                                        │
│                      (Complete agreement)                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│  party                │ address  │ Initiating party                        │
│  partyRecipient       │ address  │ Receives counterparty's assets          │
│  counterparty         │ address  │ Accepting party                         │
│  counterpartyRecipient│ address  │ Receives party's assets                 │
│  partyExpiry          │ uint64   │ Party's deadline                        │
│  counterpartyExpiry   │ uint64   │ Counterparty's deadline                 │
│  partyAssets          │ Asset[]  │ Party's offered assets                  │
│  counterpartyAssets   │ Asset[]  │ Counterparty's offered assets           │
└─────────────────────────────────────────────────────────────────────────────┘
```

### WOTS+ Types

```solidity
struct WinternitzAddress {
    bytes32 publicSeed;      // Public seed for hash chain derivation
    bytes32 publicKeyHash;   // Hash of all public key segments
}

struct WinternitzElements {
    bytes32[67] elements;    // Signature elements (67 hash chain endpoints)
}
```

---

## Deployment Pattern

QuipPortal uses **EIP-1167 Minimal Proxy Clones** for gas-efficient Quip deployment.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         CLONE DEPLOYMENT                                    │
│                                                                             │
│   QuipPortal                                                                │
│       │                                                                     │
│       │ LibClone.cloneDeterministic(                                        │
│       │     implementation = QUIP_IMPLEMENTATION,                           │
│       │     data = abi.encode(address(this)),                               │
│       │     salt = pqOwnerHash                                              │
│       │ )                                                                   │
│       │                                                                     │
│       ▼                                                                     │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │  Quip Clone                                                         │   │
│   │  ┌─────────────────────────────────────────────────────────────┐    │   │
│   │  │ 45 bytes proxy bytecode → delegates to QUIP_IMPLEMENTATION  │    │   │
│   │  └─────────────────────────────────────────────────────────────┘    │   │
│   │  ┌─────────────────────────────────────────────────────────────┐    │   │
│   │  │ Immutable args: portal address (encoded in bytecode)        │    │   │
│   │  └─────────────────────────────────────────────────────────────┘    │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│   Address = CREATE2(sender, salt=pqOwnerHash, bytecode)                     │
│   → Deterministic address from pqOwnerHash                                  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Benefits:**
- ~10x cheaper deployment vs full contract
- Deterministic addresses from pqOwnerHash
- Upgradeable via new implementation + new portal

---

## Storage Layout

### QuipPortal Storage

| Slot | Variable | Type |
|------|----------|------|
| 0 | creationFee | uint256 |
| 1 | accumulatedFees | uint256 |
| 2 | admin | address |
| 3+ | pqOwnerState | mapping(bytes32 => PqOwnerState) |

*Note: VERSION, MAX_FEE, QUIP_IMPLEMENTATION are immutable (in bytecode)*

### Quip Storage

| Slot | Variable | Type |
|------|----------|------|
| 0 | _initialized (from Initializable) | uint64 |
| 1 | pqOwner.publicSeed | bytes32 |
| 2 | pqOwner.publicKeyHash | bytes32 |
| 3 | termsDigest | bytes32 |
| 4 | INIT_UNCOUPLED | bool |

---

## WOTS+ Security Model

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         WOTS+ SIGNATURE MECHANISM                           │
│                                                                             │
│   1. Key Generation (off-chain)                                             │
│      privateKey = random_bytes32()                                          │
│      pqOwner = WOTSPlus.generateKeyPair(privateKey)                         │
│      pqOwnerHash = hash(pqOwner.publicSeed, pqOwner.publicKeyHash)          │
│                                                                             │
│   2. Public Key Published                                                   │
│      Quip stores: pqOwner (public)                                          │
│      Key holder: keeps privateKey secret                                    │
│                                                                             │
│   3. Claim with Signature                                                   │
│      message = canonicalTermsDigest                                         │
│      signature = WOTSPlus.sign(privateKey, message)                         │
│      if WOTSPlus.verify(pqOwner, message, signature):                       │
│          transfer assets                                                    │
│          emit event with signature (now public)                             │
│                                                                             │
│   4. Signature Reuse (Cross-Chain)                                          │
│      Both QUIPs use same canonical terms digest                             │
│      Same signature valid on both chains                                    │
│      Counterparty can use revealed signature on other chain                 │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Why WOTS+ Instead of Hashlock?

| Aspect | Hashlock | WOTS+ |
|--------|----------|-------|
| **Quantum Security** | Vulnerable to Grover's algorithm | Quantum-resistant (hash-based) |
| **Key Reuse** | Same key = same hash | One-time signature (by design) |
| **Signature Size** | 32 bytes (preimage) | ~2KB (67 × 32 bytes) |
| **Verification Cost** | ~3k gas | ~100-150k gas |
| **Cross-Chain** | Same preimage reveals key | Same signature, same canonical digest |

---

## Canonical Terms Digest Pattern

The canonical digest ensures both parties can use the same signature:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                     CANONICAL TERMS DIGEST PATTERN                          │
│                                                                             │
│   1. Compute party digests separately                                       │
│      partyDigest = hash(party, partyRecipient, partyExpiry, partyAssets)    │
│      counterpartyDigest = hash(counterparty, counterpartyRecipient, ...)    │
│                                                                             │
│   2. Sort and combine (smaller value first)                                 │
│      if partyDigest < counterpartyDigest:                                   │
│          canonicalDigest = hash(partyDigest, counterpartyDigest)            │
│      else:                                                                  │
│          canonicalDigest = hash(counterpartyDigest, partyDigest)            │
│                                                                             │
│   WHY THIS MATTERS:                                                         │
│   ─────────────────                                                         │
│   Chain A (Alice's QUIP):  party=Alice, counterparty=Bob                    │
│   Chain B (Bob's QUIP):    party=Bob,   counterparty=Alice                  │
│                                                                             │
│   Both compute the SAME canonical digest!                                   │
│   → Alice signs once, signature works on both chains                        │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Uncoupled Mode Transition:**
```
PROPOSED:   termsDigest = hash(PartyTerms)
     │
     │ coupleQuip()
     ▼
COMMITTED:  termsDigest = canonicalHash(QuipTerms)
```

---

## Asset Transfer Flow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         ASSET TRANSFER FLOW                                 │
│                                                                             │
│   COUPLED DEPLOYMENT                                                        │
│   ──────────────────                                                        │
│   User ──[approve tokens]──► Token Contracts                                │
│     │                                                                       │
│     └──[deployCoupledQuip + ETH]──► QuipPortal                              │
│                                        │                                    │
│                                        ├──► Deploy Quip clone               │
│                                        │                                    │
│                                        └──► transferAssets(user → quip)     │
│                                                   │                         │
│                                                   ├── Native: via msg.value │
│                                                   ├── ERC20: transferFrom   │
│                                                   ├── ERC721: safeTransfer  │
│                                                   └── ERC1155: safeTransfer │
│                                                                             │
│   CLAIM                                                                     │
│   ─────                                                                     │
│   Claimer ──[claim(signature, terms)]──► Quip                               │
│                                            │                                │
│                                            └──► transferAssets(quip → recipient)
│                                                                             │
│   RECLAIM                                                                   │
│   ───────                                                                   │
│   Anyone ──[reclaim(terms)]──► Quip (after expiry)                          │
│                                   │                                         │
│                                   └──► transferAssets(quip → partyRecipient)│
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Event Flow

```
COUPLED CREATION:
  QuipPortal.deployCoupledQuip()
    └── Quip.initializeCoupled()
          └── emit PartyCommitment(pqOwnerHash, termsDigest)
    └── emit QuipCreated(pqOwnerHash, quip, terms)

UNCOUPLED CREATION:
  QuipPortal.deployUncoupledQuip()
    └── Quip.initializeUncoupled()
          └── emit PartyProposal(pqOwnerHash, termsDigest)
    └── emit QuipProposed(pqOwnerHash, quip, terms)

COUPLING:
  Quip.coupleQuip()
    └── emit QuipCommitted(termsDigest)

CLAIM:
  Quip.claim()
    └── QuipPortal.spendPqOwner(pqOwnerHash)
    └── emit PartyTermsFulfilled(signature, recipient, assets)

RECLAIM:
  Quip.reclaim()
    └── QuipPortal.spendPqOwner(pqOwnerHash)
    └── emit PartyUnbound(recipient, assets)
```

---

## Security Considerations

| Aspect | Implementation |
|--------|----------------|
| Reentrancy | State changes before external calls (CEI pattern) |
| PqOwner uniqueness | `pqOwnerState` enum (Unused→Free→Spent) prevents replay; allows same-chain swaps |
| Terms tampering | Terms verified against stored canonical digest |
| Expiry enforcement | Block timestamp checks for claim/reclaim |
| Asset validation | Type-specific validation in `validateAsset()` |
| Permissionless claim | By design - valid signature = authorization |
| Zero-address checks | Constructor and terms validation |
| Quantum resistance | WOTS+ signatures based on hash function security |

### Portal-Quip Mutual Authentication

The system uses a two-way binding to prevent malicious clone attacks:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      MUTUAL AUTHENTICATION                                  │
│                                                                             │
│   ┌─────────────┐                              ┌─────────────┐              │
│   │  QuipPortal │                              │    Quip     │              │
│   │             │                              │   (Clone)   │              │
│   └──────┬──────┘                              └──────┬──────┘              │
│          │                                            │                     │
│          │  1. Portal verifies Quip                   │                     │
│          │     ─────────────────────                  │                     │
│          │     spendPqOwner() checks:                 │                     │
│          │     msg.sender.codehash ==                 │                     │
│          │       QUIP_CODEHASH                        │                     │
│          │                                            │                     │
│          │  2. Quip verifies Portal                   │                     │
│          │     ─────────────────────                  │                     │
│          │     initializeCoupled/Uncoupled checks:    │                     │
│          │     msg.sender == PORTAL_FROM_BYTECODE()   │                     │
│          │                                            │                     │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Why this matters:**

An attacker could deploy a fake clone with matching `codehash` by using the same
implementation and immutable args. However:

1. **Attacker deploys fake clone** → Clone has matching codehash ✓
2. **Attacker tries to initialize** → `onlyPortal` checks `msg.sender == PORTAL_FROM_BYTECODE()`
3. **Attacker is not the portal** → Reverts with `CallerNotPortal`
4. **Uninitialized clone** → `pqOwner = 0`, `termsDigest = 0`
5. **Cannot claim/reclaim** → No path to call `spendPqOwner()`

The portal address embedded in the clone's bytecode (via LibClone immutable args)
ensures only the legitimate portal can initialize quips, while the codehash check
ensures only legitimate quips can call `spendPqOwner()`.

---

## Dependencies

| Package | Version | Usage |
|---------|---------|-------|
| OpenZeppelin Contracts | 5.6.0-rc.1 | IERC721, IERC1155, Context |
| Solady | 0.1.26 | SafeTransferLib, LibClone, EfficientHashLib, Initializable |
| hashsigs-solidity | 0.1.0 | WOTSPlus library for quantum-resistant signatures |
