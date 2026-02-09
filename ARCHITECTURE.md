# QUIP Architecture

## Overview

QUIP (Quick Interchange Protocol) is a trustless atomic swap system using hashlock contracts. It enables secure asset exchanges between two parties, potentially across different chains.

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
│   └── isLockSpent (mapping)
│
├── Modifier
│   └── onlyAdmin
│
├── Constructor
│   └── constructor(firstAdmin, quipImpl, maxFee, creationFee)
│
├── Public Functions
│   ├── deployCoupledQuip(lock, terms)
│   ├── deployUncoupledQuip(lock, terms)
│   ├── withdrawFees(receiver, amount)
│   └── setCreationFee(newFee)
│
└── Internal Functions
    ├── _deployQuip(lock)
    ├── _enforceValidLock(lock)
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
│   ├── VERSION
│   └── PORTAL_PREDETERMINED
│
├── State
│   ├── lock (bytes32)
│   ├── termsDigest (bytes32)
│   └── INIT_UNCOUPLED (bool)
│
├── Modifier
│   └── onlyPortal
│
├── Public Functions
│   ├── PORTAL_FROM_BYTECODE()
│   ├── initializeCoupled(lock, termsDigest)
│   ├── initializeUncoupled(lock, termsDigest)
│   ├── coupleQuip(party, counterparty, termsDigest)
│   ├── claim(key, terms)
│   └── reclaim(terms)
│
└── Internal Functions
    ├── _verifyKey(key)
    ├── _onlyPortal()
    ├── _enforcePortalMatch()
    └── _enforcePortalCaller()
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
    ├── digestTerms(terms) [calldata]
    ├── digestTermsMemory(terms) [memory]
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
│       │     data = abi.encode(VERSION),                                     │
│       │     salt = lock                                                     │
│       │ )                                                                   │
│       │                                                                     │
│       ▼                                                                     │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │  Quip Clone                                                         │   │
│   │  ┌─────────────────────────────────────────────────────────────┐    │   │
│   │  │ 45 bytes proxy bytecode → delegates to QUIP_IMPLEMENTATION  │    │   │
│   │  └─────────────────────────────────────────────────────────────┘    │   │
│   │  ┌─────────────────────────────────────────────────────────────┐    │   │
│   │  │ Immutable args: VERSION (encoded in bytecode)               │    │   │
│   │  └─────────────────────────────────────────────────────────────┘    │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│   Address = CREATE2(sender, salt=lock, bytecode)                            │
│   → Deterministic address from lock                                         │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Benefits:**
- ~10x cheaper deployment vs full contract
- Deterministic addresses from lock
- Upgradeable via new implementation + new portal

---

## Storage Layout

### QuipPortal Storage

| Slot | Variable | Type |
|------|----------|------|
| 0 | creationFee | uint256 |
| 1 | accumulatedFees | uint256 |
| 2 | admin | address |
| 3+ | isLockSpent | mapping(bytes32 => bool) |

*Note: VERSION, MAX_FEE, QUIP_IMPLEMENTATION are immutable (in bytecode)*

### Quip Storage

| Slot | Variable | Type |
|------|----------|------|
| 0 | _initialized (from Initializable) | uint64 |
| 1 | lock | bytes32 |
| 2 | termsDigest | bytes32 |
| 3 | INIT_UNCOUPLED | bool |

---

## Hashlock Security Model

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         HASHLOCK MECHANISM                                  │
│                                                                             │
│   1. Key Generation (off-chain)                                             │
│      key = random_bytes()                                                   │
│      lock = keccak256(key)                                                  │
│                                                                             │
│   2. Lock Published                                                         │
│      Quip stores: lock (public)                                             │
│      Key holder: keeps key secret                                           │
│                                                                             │
│   3. Claim with Key                                                         │
│      if keccak256(provided_key) == stored_lock:                             │
│          transfer assets                                                    │
│          emit event with key (now public)                                   │
│                                                                             │
│   4. Key Revelation                                                         │
│      Once key is used on Chain A, it's visible to all                       │
│      Counterparty can use same key on Chain B                               │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Terms Digest Pattern

Only the hash of terms is stored on-chain to save gas:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        TERMS DIGEST PATTERN                                 │
│                                                                             │
│   ON-CHAIN                           OFF-CHAIN                              │
│   ────────                           ─────────                              │
│   termsDigest = 0xabc123...          QuipTerms {                            │
│   (32 bytes)                           party: 0x...,                        │
│                                        partyRecipient: 0x...,               │
│                                        counterparty: 0x...,                 │
│                                        ...                                  │
│                                      }                                      │
│                                                                             │
│   VERIFICATION (at claim/reclaim):                                          │
│   ────────────────────────────────                                          │
│   require(keccak256(abi.encode(terms)) == termsDigest)                      │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Uncoupled Mode Transition:**
```
PROPOSED:   termsDigest = hash(PartyTerms)
     │
     │ coupleQuip()
     ▼
COMMITTED:  termsDigest = hash(QuipTerms)
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
│   Claimer ──[claim(key, terms)]──► Quip                                     │
│                                      │                                      │
│                                      └──► transferAssets(quip → recipient)  │
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
          └── emit PartyCommitment(termsDigest)
    └── emit QuipCreated(quip, terms)

UNCOUPLED CREATION:
  QuipPortal.deployUncoupledQuip()
    └── Quip.initializeUncoupled()
          └── emit PartyProposal(lock, termsDigest)
    └── emit QuipProposed(quip, terms)

COUPLING:
  Quip.coupleQuip()
    └── emit QuipCommitted(termsDigest)

CLAIM:
  Quip.claim()
    └── emit PartyTermsFulfilled(key, recipient, assets)

RECLAIM:
  Quip.reclaim()
    └── emit PartyUnbound(recipient, assets)
```

---

## Security Considerations

| Aspect | Implementation |
|--------|----------------|
| Reentrancy | State changes before external calls (CEI pattern) |
| Lock uniqueness | `isLockSpent` mapping prevents reuse |
| Terms tampering | Terms verified against stored digest |
| Expiry enforcement | Block timestamp checks for claim/reclaim |
| Asset validation | Type-specific validation in `validateAsset()` |
| Permissionless claim | By design - key possession = authorization |
| Zero-address checks | Constructor and terms validation |

---

## Dependencies

| Package | Version | Usage |
|---------|---------|-------|
| OpenZeppelin Contracts | 5.6.0-rc.1 | IERC721, IERC1155, Context |
| Solady | 0.1.26 | SafeTransferLib, LibClone, EfficientHashLib, Initializable |
