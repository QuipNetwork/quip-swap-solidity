# QUIP Lifecycle

A **QUIP** (Quick Interchange Protocol) is a hashlock-based atomic swap mechanism that enables trustless asset exchanges between two parties across potentially different chains or contexts.

## Table of Contents

- [Core Concepts](#core-concepts)
- [Initialization Modes](#initialization-modes)
- [Lifecycle Overview](#lifecycle-overview)
- [Coupled QUIP Flow](#coupled-quip-flow)
- [Uncoupled QUIP Flows](#uncoupled-quip-flows)
  - [Flow A: Uncoupled-Uncoupled](#flow-a-uncoupled-uncoupled-both-propose)
  - [Flow B: Uncoupled-Coupled](#flow-b-uncoupled-coupled-propose-and-accept)
- [Terminal States](#terminal-states)
- [Data Structures](#data-structures)

---

## Core Concepts

### Lock and Key

Every QUIP is secured by a **lock** (a hash) and can only be claimed with the corresponding **key** (the preimage).

```
lock = keccak256(key)
```

The party who initiates the swap controls the secret key. They reveal it to claim assets on one side, which simultaneously enables the counterparty to claim on the other side.

### Terms Digest

Instead of storing full swap terms on-chain (expensive), QUIPs store only a **terms digest**:

```
termsDigest = keccak256(abi.encode(QuipTerms))
```

Full terms are provided at claim/reclaim time and verified against the stored digest.

### Supported Assets

QUIPs support multiple asset types in a single swap:

| Type | Description |
|------|-------------|
| `Native` | Chain-native currency (ETH, etc.) |
| `ERC20` | Fungible tokens |
| `ERC721` | Non-fungible tokens |
| `ERC1155` | Multi-tokens |

---

## Initialization Modes

QUIPs support two initialization modes to accommodate different use cases:

| Mode | Use Case | Asset Transfer |
|------|----------|----------------|
| **Coupled** | Both parties known upfront | Immediate on creation |
| **Uncoupled** | Proposal-based discovery | Deferred until coupling |

---

## Lifecycle Overview

```
═══════════════════════════════════════════════════════════════════════════════════════
                                    COUPLED MODE
═══════════════════════════════════════════════════════════════════════════════════════

     ┌─────────┐   deployCoupledQuip()    ┌─────────────────┐
     │  START  │ ───────────────────────► │    COMMITTED    │
     └─────────┘    + assets transferred  └─────────────────┘                      
                                                   │                               
                              ┌────────────────────┴────────────────────┐          
                              │                                         │          
                         claim(key)                                reclaim()       
                        [before expiry]                          [after expiry]    
                              │                                         │          
                              ▼                                         ▼          
                       ┌─────────────┐                           ┌─────────────┐   
                       │   CLAIMED   │                           │  RECLAIMED  │   
                       └─────────────┘                           └─────────────┘   
                                                                              
═══════════════════════════════════════════════════════════════════════════════════════
                                   UNCOUPLED MODES
═══════════════════════════════════════════════════════════════════════════════════════

     FLOW A - SYMMETRIC: Both parties deploy uncoupled, then couple
     ──────────────────────────────────────────────────────────────
  
     ┌─────────┐  deployUncoupledQuip()  ┌──────────────┐  coupleQuip()  ┌───────────┐
     │  START  │ ──────────────────────► │   PROPOSED   │ ─────────────► │ COMMITTED │
     └─────────┘     (no assets)         └──────────────┘  + assets      └───────────┘
                                                 │                             │
                                           [never coupled]                     │
                                                 │                        ┌────┴────┐
                                                 ▼                        ▼         ▼
                                          ┌─────────────┐            CLAIMED   RECLAIMED
                                          │  ABANDONED  │
                                          └─────────────┘
  
     FLOW B - ASYMMETRIC: Proposer uncoupled, responder coupled immediately
     ──────────────────────────────────────────────────────────────────────
  
     PROPOSER (Alice):
     ┌─────────┐  deployUncoupledQuip()  ┌──────────────┐  coupleQuip()  ┌───────────┐
     │  START  │ ──────────────────────► │   PROPOSED   │ ─────────────► │ COMMITTED │
     └─────────┘     (no assets)         └──────────────┘  + assets      └───────────┘
  
     RESPONDER (Bob) - sees proposal, deploys coupled immediately:
     ┌─────────┐  deployCoupledQuip()    ┌───────────┐
     │  START  │ ──────────────────────► │ COMMITTED │
     └─────────┘     + assets            └───────────┘

```

---

## Coupled QUIP Flow

Use coupled mode when both parties and their terms are known at creation time.

### Sequence Diagram

```
    Party (Alice)                    QuipPortal                      Quip                     Counterparty (Bob)
         │                               │                            │                              │
         │  1. Generate secret key       │                            │                              │
         │     lock = hash(key)          │                            │                              │
         │                               │                            │                              │
         │  2. deployCoupledQuip(        │                            │                              │
         │       lock, terms)            │                            │                              │
         │  ────────────────────────────►│                            │                              │
         │     + pay fee                 │  3. Deploy clone           │                              │
         │                               │  ───────────────────────►  │                              │
         │                               │                            │                              │
         │                               │  4. initializeCoupled(     │                              │
         │                               │       lock, termsDigest)   │                              │
         │                               │  ───────────────────────►  │                              │
         │                               │                            │                              │
         │                               │  5. Transfer assets        │                              │
         │                               │     to Quip contract       │                              │
         │                               │  ───────────────────────►  │                              │
         │                               │                            │                              │
         │                               │                            │  ◄─────────────────────────  │
         │                               │                            │   6. Bob sees QuipCreated    │
         │                               │                            │      event, verifies terms    │
         │                               │                            │                              │
         │                               │                            │   7. Bob creates mirror      │
         │                               │                            │      QUIP on Chain B with    │
         │                               │                            │      same lock, his assets   │
         │                               │                            │  ◄─────────────────────────  │
         │                               │                            │                              │
         │  8. Alice claims Bob's        │                            │                              │
         │     assets on Chain B         │                            │                              │
         │     revealing the key         │                            │                              │
         │                               │                            │                              │
         │                               │                            │  9. claim(key, terms)        │
         │                               │                            │  ◄─────────────────────────  │
         │                               │                            │     Bob uses revealed key    │
         │                               │                            │                              │
         │                               │                            │  10. Assets transferred      │
         │                               │                            │      to counterpartyRecipient│
         │                               │                            │  ────────────────────────►   │
         │                               │                            │                              │
```

### Step-by-Step

1. **Alice generates a secret key** and computes `lock = keccak256(key)`

2. **Alice calls `deployCoupledQuip()`** with:
   - The `lock`
   - Full `QuipTerms` specifying both parties, recipients, expiries, and assets
   - Payment: creation fee + native assets (if any)

3. **QuipPortal deploys a minimal clone** using the lock as salt (deterministic address)

4. **QuipPortal initializes the Quip** with coupled terms:
   - Stores `lock`
   - Stores `termsDigest = hash(QuipTerms)`
   - Emits `PartyCommitment(termsDigest)`

5. **Assets are transferred** from Alice to the Quip contract

6. **Bob observes the `QuipCreated` event** and verifies the terms match his expectations

7. **Bob creates a mirror QUIP** on Chain B with the same lock but reversed roles

8. **Alice claims Bob's assets** on Chain B by revealing the key

9. **Bob uses the revealed key** to call `claim(key, terms)` on Chain A

10. **Assets transfer** to `counterpartyRecipient` (Bob's designated receiver)

---

## Uncoupled QUIP Flows

Use uncoupled mode for proposal-based swaps where the counterparty isn't known at creation time.

There are **two variations** of the uncoupled flow:

| Flow | Description | Use Case |
|------|-------------|----------|
| **Uncoupled-Uncoupled** | Both parties deploy uncoupled, then couple | Symmetric negotiation |
| **Uncoupled-Coupled** | Proposer deploys uncoupled, responder deploys coupled | Quick response to proposal |

---

### Flow A: Uncoupled-Uncoupled (Both Propose)

Both parties deploy uncoupled QUIPs first, then couple them once terms are agreed.

#### Sequence Diagram

```
    Party (Alice)                    QuipPortal                      Quip                     Counterparty (Bob)
         │                               │                            │                              │
         │  1. Generate secret key       │                            │                              │
         │     lock = hash(key)          │                            │                              │
         │                               │                            │                              │
         │  2. deployUncoupledQuip(      │                            │                              │
         │       lock, partyTerms)       │                            │                              │
         │  ────────────────────────────►│                            │                              │
         │     + pay fee only            │  3. Deploy clone           │                              │
         │     (no asset transfer)       │  ───────────────────────►  │                              │
         │                               │                            │                              │
         │                               │  4. initializeUncoupled(   │                              │
         │                               │       lock, termsDigest)   │                              │
         │                               │  ───────────────────────►  │                              │
         │                               │                            │                              │
         │                               │     Quip is PROPOSED       │                              │
         │                               │     INIT_UNCOUPLED = true  │                              │
         │                               │                            │                              │
         │                               │                            │  ◄─────────────────────────  │
         │                               │                            │   5. Bob sees QuipProposed   │
         │                               │                            │      decides to participate  │
         │                               │                            │                              │
         │                               │                            │   6. Bob creates his own     │
         │                               │                            │      uncoupled QUIP with     │
         │                               │                            │      same lock               │
         │                               │                            │  ◄─────────────────────────  │
         │                               │                            │                              │
         │  7. coupleQuip(               │                            │                              │
         │       aliceTerms,             │                            │                              │
         │       bobTerms,               │                            │                              │
         │       termsDigest)            │                            │                              │
         │  ─────────────────────────────────────────────────────────►│                              │
         │     + send native assets      │                            │                              │
         │     + approve token transfers │                            │                              │
         │                               │                            │                              │
         │                               │     8. Verify termsDigest  │                              │
         │                               │        matches stored hash │                              │
         │                               │                            │                              │
         │                               │     9. Compute coupled     │                              │
         │                               │        QuipTerms           │                              │
         │                               │                            │                              │
         │                               │     10. Update termsDigest │                              │
         │                               │         to full terms hash │                              │
         │                               │                            │                              │
         │                               │     11. Transfer assets    │                              │
         │                               │         (no native)        │                              │
         │                               │                            │                              │
         │                               │     Quip is COMMITTED      │                              │
         │                               │                            │                              │
         │                               │                            │   12. Bob couples his QUIP   │
         │                               │                            │  ◄─────────────────────────  │
         │                               │                            │                              │
         │  ... same claim flow as coupled mode ...                   │                               │
         │                               │                            │                              │
```

### Step-by-Step

1. **Alice generates a secret key** and computes `lock = keccak256(key)`

2. **Alice calls `deployUncoupledQuip()`** with:
   - The `lock`
   - Her `PartyTerms` only (not full QuipTerms)
   - Payment: creation fee only (no assets transferred yet)

3. **QuipPortal deploys a minimal clone** (same as coupled)

4. **QuipPortal initializes the Quip** in uncoupled mode:
   - Stores `lock`
   - Stores `termsDigest = hash(PartyTerms)` (partial terms)
   - Sets `INIT_UNCOUPLED = true`
   - Emits `PartyProposal(lock, termsDigest)`

5. **Bob discovers the proposal** via events and decides to participate

6. **Bob creates his own uncoupled QUIP** with the same lock on his chain

7. **Alice calls `coupleQuip()`** with:
   - Her original `PartyTerms`
   - Bob's `PartyTerms`
   - The original `termsDigest` (for verification)
   - Native assets via `msg.value`
   - Pre-approved token transfers

8. **Contract verifies** that the provided `termsDigest` matches the stored hash

9. **Contract computes** the full `QuipTerms` by combining both party terms

10. **Contract updates** `termsDigest` to the hash of the full coupled terms

11. **Contract transfers** non-native assets from Alice to itself

12. **Bob couples his QUIP** similarly on his chain

13. **Claim flow proceeds** as in coupled mode

### Terms Digest Evolution (Uncoupled)

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                                                                                 │
│   PROPOSED STATE                           COMMITTED STATE                      │
│                                                                                 │
│   termsDigest = hash(PartyTerms)    ───►   termsDigest = hash(QuipTerms)        │
│                                                                                 │
│   ┌─────────────────────┐                  ┌─────────────────────────────────┐  │
│   │ PartyTerms          │                  │ QuipTerms                       │  │
│   │ ├─ party            │                  │ ├─ party                        │  │
│   │ ├─ partyRecipient   │      combine     │ ├─ partyRecipient               │  │
│   │ ├─ partyExpiry      │   ──────────►    │ ├─ counterparty                 │  │
│   │ └─ partyAssets[]    │                  │ ├─ counterpartyRecipient        │  │
│   └─────────────────────┘                  │ ├─ partyExpiry                  │  │
│              +                             │ ├─ counterpartyExpiry           │  │
│   ┌─────────────────────┐                  │ ├─ partyAssets[]                │  │
│   │ CounterPartyTerms   │                  │ └─ counterpartyAssets[]         │  │
│   │ (as PartyTerms)     │                  └─────────────────────────────────┘  │
│   └─────────────────────┘                                                       │
│                                                                                 │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

### Flow B: Uncoupled-Coupled (Propose and Accept)

Alice deploys an uncoupled QUIP as a proposal. Bob sees it, constructs full terms, and deploys a coupled QUIP immediately.

#### Sequence Diagram

```
                      CHAIN A                                              CHAIN B
    ┌─────────────────────────────────────────────┐     ┌─────────────────────────────────────────────┐
    │                                             │     │                                             │
    │   Alice (Proposer)           Alice's Quip   │     │   Bob's Quip                Bob (Responder) │
    │        │                          │         │     │       │                          │          │
    │        │  1. Generate key         │         │     │       │                          │          │
    │        │     lock = hash(key)     │         │     │       │                          │          │
    │        │                          │         │     │       │                          │          │
    │        │  2. deployUncoupledQuip( │         │     │       │                          │          │
    │        │       lock, aliceTerms)  │         │     │       │                          │          │
    │        │  ───────────────────────►│         │     │       │                          │          │
    │        │                          │         │     │       │                          │          │
    │        │     [PROPOSED]           │         │     │       │  3. Bob sees proposal    │          │
    │        │     termsDigest =        │         │     │       │     constructs full      │          │
    │        │     hash(aliceTerms)     │         │     │       │     QuipTerms            │          │
    │        │                          │         │     │       │                          │          │
    │        │                          │         │     │       │  4. deployCoupledQuip(   │          │
    │        │                          │         │     │       │       lock, fullTerms)   │          │
    │        │                          │         │     │       │  ◄───────────────────────│          │
    │        │                          │         │     │       │     + transfers assets   │          │
    │        │                          │         │     │       │                          │          │
    │        │                          │         │     │       │     [COMMITTED]          │          │
    │        │                          │         │     │       │     termsDigest =        │          │
    │        │                          │         │     │       │     hash(QuipTerms)      │          │
    │        │                          │         │     │       │                          │          │
    │        │  5. Alice sees Bob's     │         │     │       │                          │          │
    │        │     commitment, calls    │         │     │       │                          │          │
    │        │     coupleQuip()         │         │     │       │                          │          │
    │        │  ───────────────────────►│         │     │       │                          │          │
    │        │     + transfers assets   │         │     │       │                          │          │
    │        │                          │         │     │       │                          │          │
    │        │     [COMMITTED]          │         │     │       │                          │          │
    │        │                          │         │     │       │                          │          │
    │        │                          │         │     │       │                          │          │
    │        │  ══════════════════════════════════════════════════════════════════════════ │          │
    │        │                           CLAIM PHASE                                       │          │
    │        │  ══════════════════════════════════════════════════════════════════════════ │          │
    │        │                          │         │     │       │                          │          │
    │        │  6. Alice claims on      │         │     │       │                          │          │
    │        │     Chain B (reveals key)│         │     │       │                          │          │
    │        │  ─────────────────────────────────────────────►  │                          │          │
    │        │                          │         │     │       │                          │          │
    │        │                          │         │     │       │  7. Bob sees key,        │          │
    │        │                          │         │     │       │     claims on Chain A    │          │
    │        │                          │  ◄────────────────────────────────────────────── │          │
    │        │                          │         │     │       │                          │          │
    │        │                    [CLAIMED]       │     │ [CLAIMED]                        │          │
    │        │                          │         │     │       │                          │          │
    └────────┴──────────────────────────┴─────────┘     └───────┴──────────────────────────┴──────────┘
```

#### Step-by-Step

1. **Alice generates a secret key** and computes `lock = keccak256(key)`

2. **Alice calls `deployUncoupledQuip()`** on Chain A with:
   - The `lock`
   - Her `PartyTerms` (what she's offering and expecting)
   - Payment: creation fee only

3. **Bob discovers the proposal** and constructs full `QuipTerms`:
   - Alice's terms become the `party*` fields
   - Bob's terms become the `counterparty*` fields
   - Note: From Bob's QUIP perspective, roles are reversed

4. **Bob calls `deployCoupledQuip()`** on Chain B with:
   - The same `lock` (from Alice's proposal)
   - Full `QuipTerms` (with his assets committed immediately)
   - Payment: creation fee + his assets

5. **Alice sees Bob's commitment** and calls `coupleQuip()` on Chain A:
   - Provides both party terms
   - Commits her assets
   - Her QUIP transitions from PROPOSED to COMMITTED

6. **Alice claims Bob's assets** on Chain B by revealing the key

7. **Bob uses the revealed key** to claim Alice's assets on Chain A

#### Why Use This Flow?

| Advantage | Description |
|-----------|-------------|
| **Faster for responder** | Bob commits in one transaction instead of two |
| **Lower gas for Bob** | No need to call `coupleQuip()` separately |
| **Clear commitment signal** | Bob's coupled deployment shows serious intent |

#### Comparison: Flow A vs Flow B

```
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                                                                                     │
│   FLOW A: Uncoupled-Uncoupled                FLOW B: Uncoupled-Coupled              │
│                                                                                     │
│   Alice: deployUncoupledQuip()               Alice: deployUncoupledQuip()           │
│      │                                          │                                   │
│      ▼                                          ▼                                   │
│   Bob: deployUncoupledQuip()                 Bob: deployCoupledQuip() ◄─ assets     │
│      │                                          │                                   │
│      ▼                                          ▼                                   │
│   Alice: coupleQuip() ◄─ assets              Alice: coupleQuip() ◄─ assets          │
│      │                                          │                                   │
│      ▼                                          ▼                                   │
│   Bob: coupleQuip() ◄─ assets                [Both committed, ready to claim]       │
│      │                                                                              │
│      ▼                                                                              │
│   [Both committed, ready to claim]                                                  │
│                                                                                     │
│   Transactions: 4                            Transactions: 3                        │
│   Bob commits assets: Step 4                 Bob commits assets: Step 2             │
│                                                                                     │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

---

## Terminal States

### Claimed

The swap completed successfully. The counterparty revealed the key and received the party's assets.

```solidity
function claim(bytes calldata key, QuipTerms calldata terms) external {
    _verifyKey(key);                                    // key must hash to lock
    TermsLib.verifyTerms(termsDigest, terms);          // terms must match digest
    TermsLib.enforceTermFreshness(terms.partyExpiry);  // must be before expiry

    // Transfer assets to counterparty's recipient
    TermsLib.executePartyCommitment(address(this), terms.counterpartyRecipient, terms.partyAssets);
}
```

### Reclaimed

The swap expired and the party reclaimed their assets.

```solidity
function reclaim(QuipTerms calldata terms) external {
    TermsLib.verifyTerms(termsDigest, terms);          // terms must match digest
    TermsLib.enforceTermStaleness(terms.partyExpiry); // must be after expiry

    // Return assets to party's recipient
    TermsLib.releasePartyCommitment(address(this), terms.partyRecipient, terms.partyAssets);
}
```

### State Diagram

```
                              ┌─────────────────┐
                              │                 │
                  ┌───────────│    COMMITTED    │───────────┐
                  │           │                 │           │
                  │           └─────────────────┘           │
                  │                                         │
            claim(key)                                 reclaim()
         [before expiry]                            [after expiry]
                  │                                         │
                  ▼                                         ▼
         ┌─────────────┐                           ┌─────────────┐
         │             │                           │             │
         │   CLAIMED   │                           │  RECLAIMED  │
         │             │                           │             │
         └─────────────┘                           └─────────────┘
               │                                         │
               │         Assets go to                    │         Assets return to
               │         counterpartyRecipient           │         partyRecipient
               ▼                                         ▼
```

---

## Data Structures

### Asset

```solidity
struct Asset {
    AssetType assetType;  // Native, ERC20, ERC721, ERC1155
    address target;       // Contract address (0x0 for Native)
    uint256 id;           // Token ID (ERC721/ERC1155 only)
    uint256 amount;       // Amount (not used for ERC721)
}
```

### PartyTerms

Used in uncoupled mode for single-party proposals:

```solidity
struct PartyTerms {
    address party;           // The party's address
    address partyRecipient;  // Where to receive counterparty's assets
    uint64 partyExpiry;      // Deadline for the swap
    Asset[] partyAssets;     // Assets being offered
}
```

### QuipTerms

The complete swap agreement:

```solidity
struct QuipTerms {
    address party;                  // Initiating party
    address partyRecipient;         // Receives counterparty's assets
    address counterparty;           // Accepting party
    address counterpartyRecipient;  // Receives party's assets
    uint64 partyExpiry;             // Party's deadline
    uint64 counterpartyExpiry;      // Counterparty's deadline
    Asset[] partyAssets;            // Party's offered assets
    Asset[] counterpartyAssets;     // Counterparty's offered assets
}
```

---

## Gas Optimization

QUIPs use several gas optimization techniques:

1. **Minimal Clones**: Each QUIP is a minimal proxy clone, reducing deployment costs
2. **Terms Digest**: Only a 32-byte hash is stored on-chain, not full terms
3. **Deterministic Addresses**: Lock-based salt enables address prediction without deployment
4. **Calldata Terms**: Terms are passed as calldata at claim/reclaim time

---

## Security Considerations

| Risk | Mitigation |
|------|------------|
| Key exposure | Key holder should claim on destination chain first |
| Front-running | Terms are committed at creation; can't be changed |
| Expiry manipulation | Block timestamp used; set appropriate margins |
| Replay attacks | Each lock can only be used once per portal |
| Asset approval | Use exact approval amounts or revoke after swap |
