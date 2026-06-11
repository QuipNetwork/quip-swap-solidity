# Quip Swap TypeScript SDK Implementation Task

You are working inside the `quip-swap-solidity-v0` repository.

Your task is to design and implement a production-quality TypeScript SDK for the current Quip Swap Solidity protocol, together with the necessary unit, integration, differential, and end-to-end tests.

Do not merely explain how the SDK could be built. Inspect the repository, implement it, run the tests, fix failures, and leave the repository in a usable state.

---

## Primary Objective

Create a standalone SDK under:

```text
sdk/
```

Use:

```text
TypeScript
Bun
Viem
Vitest
Foundry
Anvil
```

The SDK must provide safe, typed access to the current `Omnibus` contract and must reproduce Solidity hashing and encoding exactly.

The SDK should be suitable for use by:

- Browser applications
- Node.js backends
- QuipWallet front-ends and coordinators
- Same-chain swaps
- Cross-chain swap coordinators

Do not build a frontend.

Do not build a centralized secret-storage service.

Do not introduce custody of private keys.

---

# 1. Source-of-Truth Rule

Treat these files and directories as the primary source of truth:

```text
src/Omnibus.sol
src/TermsLib.sol
src/interfaces/IOmnibus.sol
src/interfaces/IQuipFactory.sol
test/
foundry.toml
Makefile
```

Do not assume the following are fully current:

```text
ARCHITECTURE.md
QUIP_LIFECYCLE.md
.env.example
README.md
script/DeployOmnibus.s.sol
script/DeployTestnet.s.sol
```

Compare all documentation against the active Solidity code before relying on it.

Known staleness you must account for:

- `.env.example` references a `QuipPortal` that does not exist in `src/`.
- Both deployment scripts construct `Omnibus` with `abi.encode(OMNIBUS_OWNER)` only, but the active constructor is `constructor(address initialOwner, address quipFactory)`. The scripts are stale. Do not derive init-code hashes, constructor encodings, or deterministic addresses from them without correcting for the two-argument constructor.

The active protocol is:

```text
Omnibus singleton (Ownable2Step, ERC721/ERC1155 receiver)
QuipFactory wallet-registry gating on commit
Hashlocks (keccak of a 32-byte secret)
Terms with three lifecycle timestamps per side
Half-open timing windows enforced per action
Same-chain swaps
Cross-chain swaps
commit / claim / reclaim
```

There is no `execute` function. The settlement function is `claim`.

Do not implement an older Portal, clone, WOTS, signatory-based, or single-deadline architecture. None of those are present in the active Solidity source.

---

# 2. Existing Solidity Model

The SDK must mirror the Solidity types exactly.

## Asset types

```solidity
enum AssetType {
    Native,   // 0
    ERC20,    // 1
    ERC721,   // 2
    ERC1155   // 3
}
```

## Asset structure

```solidity
struct Asset {
    AssetType assetType; // uint8 in ABI
    address target;      // contract address, zero for native
    uint256 id;          // token id, only used for erc721 and erc1155
    uint256 amount;      // only used for native, erc20, erc1155 (erc721 canonically 1)
}
```

## Terms structure

```solidity
struct Terms {
    uint256 chainId;            // chain where this side's assets are held
    address reclaimRecipient;   // receives this side's assets on reclaim
    address recipient;          // receives the COUNTERPARTY's assets on claim
    uint256 commitmentDeadline; // timestamp after which commitment is forbidden
    uint256 claimDeadline;      // timestamp after which claiming is forbidden
    uint256 reclaimRelease;     // timestamp after which reclaim is permitted
    Asset[] assets;             // the assets offered by this side
}
```

There is no `signatory` field. There is no single `deadline` field. All timestamps are `uint256`, not `uint64`.

## Lock states

```solidity
enum LockState {
    Unused,    // 0 - lock has never been used
    Free,      // 1 - same-chain only: one party committed, waiting for the other
    Committed, // 2 - ready for claim (same-chain: both committed; cross-chain: the single local commit)
    Spent      // 3 - terminal (claimed or reclaimed)
}
```

Valid transitions (enforced by `_advanceLockTo`):

```text
Unused -> Free
Unused -> Committed
Free -> Committed
Free -> Spent        (reclaim of a half-committed same-chain swap)
Committed -> Spent
```

## Access control

- `commit` carries the `onlyQuipWallet` modifier: it reverts with `CallerNotQuipWallet` unless `QUIP_FACTORY.vaultIdOf(msg.sender) != bytes32(0)`. Only factory-deployed QuipWallets can commit.
- `claim` and `reclaim` are permissionless.
- `setCommitmentFee` and `withdrawFees` are `onlyOwner` (Ownable2Step).

## QuipFactory surface consumed by Omnibus

```solidity
interface IQuipFactory {
    function vaultIdOf(address wallet) external view returns (bytes32 vaultId);
}
```

Use `bigint` for all Solidity integer values in TypeScript.

Use Viem `Address`, `Hex`, and `Hash` types where appropriate.

---

# 3. Inspect the Repository Before Modifying It

Before making changes:

1. Read all production contracts, including `IQuipFactory.sol`.
2. Read the existing Foundry tests, especially `test/Omnibus/Omnibus.t.sol` — it documents the canonical timing schedule (Alice = proposer, Bob = taker) and contains helpers that show exactly how commit/claim/reclaim are sequenced and warped.
3. Read all test harnesses (`test/harness/`).
4. Read all mock contracts (`test/mocks/`), including `QuipFactoryMock`.
5. Read the deployment scripts, remembering they are stale (Section 1).
6. Read `foundry.toml`, `remappings.txt`, and the root `Makefile`.
7. Run:

```bash
forge fmt --check
forge build
forge test
```

8. Record pre-existing failures separately from failures caused by your changes.
9. Identify every contract function, getter, custom error, and event that belongs in the SDK.
10. Confirm the exact behavior of Solady `EfficientHashLib.hash` (solady-0.1.26) as used by:
    - `TermsLib.digestTerms` — `hash(bytes memory)` = keccak256 of the buffer
    - `TermsLib.digestTermsCanonically` — `hash(bytes32, bytes32)` = keccak256 of the 64-byte concatenation
    - `Omnibus._generateLock` — `hash(bytes32)` = keccak256 of the single 32-byte word

Do not guess hashing behavior. Verify it against the Solidity implementation with differential tests. The harnesses already expose everything you need (Section 22).

After inspection, continue directly with implementation. Do not stop after presenting a plan.

---

# 4. SDK Directory Structure

Create a structure similar to:

```text
sdk/
├── package.json
├── bun.lock
├── tsconfig.json
├── vitest.config.ts
├── README.md
├── src/
│   ├── index.ts
│   ├── types.ts
│   ├── assets.ts
│   ├── terms.ts
│   ├── windows.ts          // half-open window math + per-action window helpers
│   ├── hashing.ts
│   ├── secrets.ts
│   ├── validation.ts
│   ├── approvals.ts
│   ├── errors.ts
│   ├── deployments.ts
│   ├── client.ts
│   ├── receipts.ts
│   ├── events.ts
│   ├── workflows/
│   │   ├── sameChain.ts
│   │   └── crossChain.ts
│   └── generated/
│       └── omnibusAbi.ts
├── scripts/
│   ├── generate-abi.ts
│   ├── run-integration-tests.ts
│   └── run-cross-chain-tests.ts
└── test/
    ├── unit/
    ├── mocked-client/
    ├── integration/
    └── cross-chain/
```

You may adjust the structure when there is a strong technical reason.

Maintain a clear separation between:

- Pure protocol logic
- RPC interaction
- Transaction submission
- Workflow orchestration
- Generated files
- Test infrastructure

Avoid creating one enormous SDK class.

---

# 5. Package Configuration

Configure the SDK as a publishable TypeScript package.

Requirements:

- Use ESM.
- Use strict TypeScript.
- Provide package exports.
- Generate JavaScript output.
- Generate TypeScript declaration files.
- Generate source maps where appropriate.
- Do not export internal test utilities.

Add scripts similar to:

```json
{
  "scripts": {
    "generate:abi": "...",
    "typecheck": "...",
    "test": "...",
    "test:unit": "...",
    "test:integration": "...",
    "test:cross-chain": "...",
    "build": "...",
    "check": "..."
  }
}
```

Use a straightforward build tool such as `tsup`, unless another small tool is clearly more appropriate.

---

# 6. ABI Generation

Do not permanently hand-maintain the Omnibus ABI.

Implement a generation script that reads:

```text
out/Omnibus.sol/Omnibus.json
```

and generates:

```text
sdk/src/generated/omnibusAbi.ts
```

The generated ABI must:

1. Be exported with `as const`.
2. Support Viem type inference.
3. Contain only the ABI.
4. Exclude bytecode and unrelated artifact metadata.
5. Be deterministically generated.
6. Fail with a useful error if the Foundry artifact does not exist.

The expected flow should be:

```bash
forge build
cd sdk
bun run generate:abi
```

Test-only deployment utilities may read full Foundry artifacts for ABI and bytecode, including `QuipFactoryMock.json`, the mock tokens, and the harnesses.

Do not publish harness, mock, or factory-mock bytecode through the SDK's public API.

---

# 7. Public TypeScript Types

Implement typed equivalents of:

```text
AssetType
Asset
Terms
LockState
```

Recommended enums:

```ts
export enum AssetType {
    Native = 0,
    ERC20 = 1,
    ERC721 = 2,
    ERC1155 = 3,
}

export enum LockState {
    Unused = 0,
    Free = 1,
    Committed = 2,
    Spent = 3,
}
```

Use interfaces or readonly types such as:

```ts
export interface Asset {
    readonly assetType: AssetType
    readonly target: Address
    readonly id: bigint
    readonly amount: bigint
}

export interface Terms {
    readonly chainId: bigint
    readonly reclaimRecipient: Address
    readonly recipient: Address
    readonly commitmentDeadline: bigint
    readonly claimDeadline: bigint
    readonly reclaimRelease: bigint
    readonly assets: readonly Asset[]
}
```

Do not use JavaScript `number` for:

- Chain IDs
- Any of the three lifecycle timestamps
- Token IDs
- Token amounts
- Balances
- Fees
- Block numbers

---

# 8. Asset Builders

Create safe builders:

```ts
nativeAsset(amount)
erc20Asset(target, amount)
erc721Asset(target, tokenId)
erc1155Asset(target, tokenId, amount)
```

They must return canonical Solidity-compatible `Asset` objects. The on-chain rules below come from `TermsLib.validateAsset`; reproduce them exactly, and where the SDK is stricter than the contract, say so in JSDoc.

## Universal on-chain rule

```text
amount > 0 for EVERY asset type (ZeroAmount otherwise) — including ERC-721
```

## Native asset rules (on-chain: InvalidNativeAsset)

```text
assetType = Native
target = zeroAddress
id = 0n
amount > 0n
```

## ERC-20 rules (on-chain: InvalidERC20Asset)

```text
assetType = ERC20
target != zeroAddress
id = 0n          // the contract REJECTS non-zero id for ERC-20
amount > 0n
```

## ERC-721 rules (on-chain: InvalidERC721Asset)

```text
assetType = ERC721
target != zeroAddress
amount > 0n      // this is all the contract enforces
```

The contract does not force `amount == 1` for ERC-721, but the amount is hashed into the terms digest, and the transfer moves exactly one specific NFT regardless of the amount value. The SDK must therefore canonicalize every ERC-721 asset to:

```ts
amount: 1n
```

This matches the repository's own `AssetHelper.makeERC721` and prevents two different digests describing the same effective NFT transfer.

Do not assume token ID zero is invalid. The contract explicitly permits id 0 for ERC-721 and ERC-1155 (see the comment in `validateAsset`).

## ERC-1155 rules (on-chain: InvalidERC1155Asset)

```text
assetType = ERC1155
target != zeroAddress
amount > 0n
```

Provide standalone asset validation functions for objects received from JSON, APIs, databases, or external applications.

---

# 9. Terms Helpers and Validation

Implement a helper such as:

```ts
createTerms({
    chainId,
    reclaimRecipient,
    recipient,
    commitmentDeadline,
    claimDeadline,
    reclaimRelease,
    assets,
})
```

## Structural validation (mirror `TermsLib.validateTerms` exactly)

```text
assets is not empty                                  (EmptyAssets)
reclaimRecipient != zeroAddress                      (ZeroAddressRecipient)
recipient != zeroAddress                             (ZeroAddressRecipient)
commitmentDeadline != 0                              (ZeroDeadline)
commitmentDeadline < claimDeadline < reclaimRelease  (DisordedDeadlines, strict)
chainId > 0                                          (ZeroChainId)
every asset is structurally valid                    (Section 8)
```

IMPORTANT: `validateTerms` deliberately does NOT check that deadlines are in the future. Freshness is enforced per-action by half-open timing windows (see below). Do not add a freshness check to structural validation — the taker legitimately commits AFTER the proposer's commitment deadline has elapsed, and a freshness check would wrongly reject the proposer's already-elapsed deadline during the taker's commit.

## Pairing validation (mirror `TermsLib.validateTermPairing` exactly)

The two sides' lifecycle timestamps must strictly interleave. Exactly one of these must hold:

```text
A proposes:
A.commitmentDeadline < B.commitmentDeadline < A.claimDeadline
    < B.claimDeadline < A.reclaimRelease < B.reclaimRelease

B proposes: the same chain with A and B swapped
```

Otherwise the contract reverts with `DisordedDeadlines`. Implement `validateTermPairing(a, b)` and `proposedBy(a, b)` in TypeScript (`proposedByParty` on-chain: the proposer is the side with the smaller `commitmentDeadline`).

## Window helpers (mirror `TermsLib.enforceWithin` exactly)

`enforceWithin(lower, upper, timestamp)` enforces the HALF-OPEN window `[lower, upper)`:

```text
lower >= upper            -> InvalidRange
timestamp < lower         -> WindowViolated
timestamp >= upper        -> WindowViolated (upper bound is EXCLUSIVE)
```

The exclusive upper bound is deliberate: adjacent windows share a boundary and exactly one window accepts the shared instant. Do not implement the upper bound as inclusive.

Implement pure helpers that compute, for a (party, counterparty) pair, the action windows the contract actually enforces:

```text
proposer commit window:  [0, proposer.commitmentDeadline)
taker commit window:     [proposer.commitmentDeadline, taker.commitmentDeadline)
proposer claim window:   [taker.commitmentDeadline, proposer.claimDeadline)
taker claim window:      [proposer.claimDeadline, proposer.reclaimRelease)
reclaim window (a leg):  [thatLeg.reclaimRelease, +infinity)
```

Derivation, so you can verify rather than trust this list:
- `commit` first/proposer path: `enforceWithin(0, party.commitmentDeadline, ts)`
- `commit` taker path: `enforceWithin(counterparty.commitmentDeadline, party.commitmentDeadline, ts)`
- `claim` when the claimant role (`party`) is the proposer: `enforceWithin(counterparty.commitmentDeadline, party.claimDeadline, ts)`
- `claim` when the claimant role is the taker: `enforceWithin(counterparty.claimDeadline, counterparty.reclaimRelease, ts)`
- `reclaim`: `enforceWithin(party.reclaimRelease, type(uint256).max, ts)`

Avoid relying directly on local wall-clock time inside pure helpers. Accept an explicit timestamp:

```ts
validateCommitWindow(party, counterparty, currentTimestamp)
```

The SDK must not imply that off-chain validation replaces on-chain validation.

---

# 10. Hashing and Encoding

Implement the exact TypeScript equivalents of:

```solidity
TermsLib.digestTerms
TermsLib.digestTermsCanonically
Omnibus._generateLock
```

## Single-side terms digest

The Solidity implementation is:

```solidity
digest = EfficientHashLib.hash(
    abi.encode(
        terms.chainId,
        terms.reclaimRecipient,
        terms.recipient,
        terms.commitmentDeadline,
        terms.claimDeadline,
        terms.reclaimRelease,
        terms.assets
    )
);
```

That is keccak256 over standard `abi.encode` of seven values, where `terms.assets` is a dynamic array of the `(uint8, address, uint256, uint256)` Asset tuple. Use standard ABI encoding (Viem `encodeAbiParameters`), not packed encoding.

Do not assume your encoding is automatically equivalent without proving it with Solidity differential tests (Section 25).

Create a central ABI tuple definition for `Asset[]` and the `Terms` tuple. Do not duplicate tuple definitions across multiple files. The `Terms` tuple is also needed to decode the `Commitment` event (Section 17).

## Canonical digest

The canonical digest must:

1. Calculate the digest of each side independently.
2. Compare the two `bytes32` values as unsigned 256-bit numbers.
3. Put the numerically smaller digest first.
4. Concatenate the two raw 32-byte values.
5. keccak256 the resulting 64 bytes (matching `EfficientHashLib.hash(bytes32, bytes32)`).

## Lock generation

`_generateLock(secret)` is keccak256 over the raw 32-byte secret (matching `EfficientHashLib.hash(bytes32)`).

Implement:

```ts
digestTerms(terms)
digestTermsCanonically(party, counterparty)
generateLock(secret)
```

Do not compare hash strings using locale-aware string comparison. Use byte-level or unsigned-bigint comparison.

---

# 11. Secret Generation

Implement cryptographically secure secret generation.

Use:

```text
crypto.getRandomValues
```

or another cryptographically secure runtime API.

Never use:

```text
Math.random()
timestamps
incrementing counters
predictable seeds
```

Return:

```ts
{
    secret,
    lock,
}
```

Both values must be exactly 32-byte hex values, with `lock = generateLock(secret)`.

Validate externally supplied secrets before hashing.

Do not print or log secrets during normal SDK execution.

Tests may use fixed deterministic secrets (the Foundry suite uses `keccak256('secret')`).

Document clearly:

- The lock may be shared.
- The secret must remain private before claim.
- Losing the secret may make claiming impossible.
- Revealing the secret too early can compromise the cross-chain flow.

---

# 12. Native Amount Calculation

Implement:

```ts
totalNative(terms)
```

It must sum only assets with:

```ts
assetType === AssetType.Native
```

The exact commit transaction value must be:

```text
totalNative(party) + current commitmentFee
```

Read `commitmentFee` from the deployed contract immediately before simulation.

Do not hardcode the fee.

Do not allow accidental extra value.

The contract checks `msg.value` for exact equality (`IncorrectNativeAmountReceived`), so both underpayment and overpayment must be prevented.

---

# 13. Deployment Registry

Create a typed deployment registry.

Do not invent addresses.

It is acceptable for the initial registry to be empty.

Allow applications to override the registry by supplying:

```ts
{
    chainId,
    omnibusAddress,
}
```

Fail clearly if:

- No verified deployment exists.
- No explicit address override is provided.

Do not calculate deterministic addresses unless every necessary input has been verified:

- CreateX factory (`0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed` per the scripts)
- Deployer address
- Guarded salt
- Init-code hash
- Constructor arguments — note that the active constructor is `(address initialOwner, address quipFactory)`, while the repository's deployment scripts stale-encode only one argument; any address derived from the scripts as-written is wrong for the active contract

Document this limitation. Do not silently "fix" the deployment scripts as part of the SDK task; flag them in the final report (Section 33 governs any Solidity-side change).

---

# 14. SDK Client API

Create a client factory similar to:

```ts
createOmnibusClient({
    address,
    publicClient,
    walletClient,
})
```

Accept existing Viem clients.

Do not force callers to provide:

- Private keys
- Raw RPC URLs
- Browser-only providers
- A specific wallet implementation

Support:

- Browser wallets
- Local private-key accounts
- Backends
- Hardware-wallet-compatible clients
- Custom transports
- Clients whose sender is a QuipWallet contract (the only senders that can commit in production)

## Read methods

Expose typed read methods for all relevant active getters, including at least:

```text
VERSION
MAX_FEE
QUIP_FACTORY
commitmentFee
accruedFees
lockState(lock)
termsHash(lock)
posted(lock, termsDigest)
owner
pendingOwner
```

Also expose a QuipWallet eligibility check that reads `vaultIdOf(account)` on the `QUIP_FACTORY` address and reports whether `account` can pass the `onlyQuipWallet` gate.

Verify the exact getter signatures from the active contract ABI.

## Write methods

Expose:

```text
commit(lock, party, counterparty)   // payable, QuipWallet-gated
claim(secret, party, counterparty)  // permissionless
reclaim(lock, party, counterparty)  // permissionless
```

There is no `execute` function; do not name anything `execute` in a way that implies a contract function of that name.

Expose administrative operations separately:

```text
setCommitmentFee
withdrawFees
transferOwnership / acceptOwnership (Ownable2Step), if you choose to surface them
```

Do not mix regular user operations and owner administration confusingly.

---

# 15. Write-Method Safety

All writes must use Viem simulation before submission:

```ts
const { request } = await publicClient.simulateContract(...)
const hash = await walletClient.writeContract(request)
```

Do not call `writeContract` directly without simulation.

In all flows below, "party" means the terms of the role the sender is acting for, and "counterparty" means the other side, matching the contract's parameter conventions.

## Commit flow

Before simulating `commit`:

1. Validate both terms structurally (Section 9).
2. Validate the pairing interleaving (Section 9).
3. Read the connected chain ID and ensure `party.chainId` matches it. Only the local side's chainId must match; `counterparty.chainId` may differ (cross-chain).
4. Check the sender passes the QuipWallet gate: `QUIP_FACTORY.vaultIdOf(sender) != bytes32(0)`. Produce a clear, actionable error if not — this is the most likely integration failure.
5. Determine the sender's role via `proposedBy` and validate the current timestamp against the correct commit window:
   - proposer: `[0, party.commitmentDeadline)`
   - taker: `[counterparty.commitmentDeadline, party.commitmentDeadline)` — the taker can only commit AFTER the proposer's commitment deadline has elapsed; surface this clearly when the window has not opened yet.
6. Read the latest `commitmentFee`.
7. Calculate exact `msg.value = totalNative(party) + commitmentFee`.
8. Simulate the contract call.
9. Submit the simulated request.

Do not substitute the QuipWallet's owner EOA for the wallet. The committer is the QuipWallet contract itself; assets and approvals must belong to it (Section 28).

## Claim flow

Before simulating `claim`:

1. Validate the secret (32-byte hex).
2. Derive the lock with `generateLock`.
3. Validate both terms structurally and as a pairing.
4. Ensure `counterparty.chainId` matches the connected chain — the claimed leg must be local. (`party.chainId` may be remote in a cross-chain claim.)
5. Validate the claim window for the claimant's role (Section 9).
6. Optionally verify `termsHash(lock)` equals the canonical digest, and that `posted(lock, digestTerms(counterparty))` is true.
7. Simulate.
8. Submit.

Do not add a caller restriction: the contract permits anyone with the correct secret to claim. Note for same-chain claims: when `party.chainId == block.chainid`, a single claim settles BOTH legs (counterparty's assets to `party.recipient` and party's assets to `counterparty.recipient`).

## Reclaim flow

Before simulating `reclaim`:

1. Validate terms structurally and as a pairing.
2. Ensure `party.chainId` matches the connected chain.
3. Ensure `currentTimestamp >= party.reclaimRelease`.
4. Optionally verify the canonical terms hash and posted state.
5. Simulate.
6. Submit.

Do not add an off-chain caller restriction that does not exist in Solidity — reclaim is permissionless, and assets go to `reclaimRecipient` regardless of caller. Note: when `counterparty.chainId` is local and the lock is `Committed`, a single reclaim returns BOTH legs to their respective `reclaimRecipient` addresses and emits two `Reclaimed` events. Reclaim is also valid from the `Free` state (half-committed same-chain swap).

---

# 16. Receipt Helpers

A returned transaction hash does not mean the transaction succeeded.

Provide helpers that:

1. Wait for a receipt.
2. Check receipt status.
3. Decode relevant Omnibus events.
4. Return a typed result.

For example:

```ts
{
    transactionHash,
    receipt,
    lock,
    state,
    commitmentEvent,
}
```

Keep submission and receipt waiting sufficiently separate so the application can choose:

- Confirmation count
- Timeout
- Retry behavior
- Finality policy

---

# 17. Event Helpers

Provide typed event decoding and query helpers for all active events. The exact signatures are:

```solidity
event Commitment(bytes32 indexed lock, Terms party, address indexed committer);
event Claim(address recipient, bytes32 indexed lock, bytes32 secret);
event Reclaimed(address caller, bytes32 indexed lock, address indexed recipient);
event FeeUpdated(uint256 oldFee, uint256 newFee);
event FeesWithdrawn(address indexed to, uint256 amount);
```

Verify these against the generated ABI. Notes that matter for the SDK:

- `Commitment` carries the FULL `Terms` struct of the committing side in event data. Provide a decoder that recovers a typed `Terms` from a `Commitment` log — this lets coordinators reconstruct a side's terms from chain history.
- `Claim.secret` is NOT indexed; it lives in event data. Provide a helper that extracts the revealed secret from a valid `Claim` event — this is how the counterparty learns the secret in a cross-chain swap. Filterable topic: `lock`.
- `Reclaimed` can be emitted twice in one reclaim transaction (both legs reclaimed on the same chain). Helpers must handle multiple `Reclaimed` events per receipt.

Support historical event queries through:

```ts
publicClient.getLogs(...)
```

A live watcher may also be provided.

Do not make the base SDK depend on a permanently running in-memory watcher.

Account for:

- Duplicate events
- Chain reorganizations
- Confirmation requirements
- Starting blocks
- Contract address filtering
- Lock filtering

Do not describe an event as final merely because it was observed once.

---

# 18. Approval Planning

Implement approval inspection for all non-native assets.

The committer is `msg.sender` (a QuipWallet). Determine whether the Omnibus contract can pull each asset from:

```text
the committing wallet address
```

There is no `signatory` field; the owner of the assets is the wallet that will send the commit transaction.

## ERC-20

Check:

```text
allowance(committer, omnibus) >= required amount
```

If multiple asset entries use the same ERC-20 token, aggregate their required amounts.

## ERC-721

Check either:

```text
getApproved(tokenId) == omnibus
```

or:

```text
isApprovedForAll(committer, omnibus) == true
```

## ERC-1155

Check:

```text
isApprovedForAll(committer, omnibus) == true
```

Return a typed approval plan.

Do not automatically send unlimited approvals by default.

Make the choice between exact and unlimited ERC-20 approval explicit.

Provide request-building or explicit approval methods where appropriate.

Use simulation for approval transactions.

Do not assume every ERC-20 implementation behaves perfectly or returns standard values. Note that commit uses balance reconciliation (`transferAssetsNoNative`): if a fee-on-transfer or deflationary ERC-20/ERC-1155 delivers less than the declared amount, commit reverts with `UnexpectedAmountReceived`. The approval plan being satisfied does not guarantee commit success for such tokens; document this.

---

# 19. Error Handling

Decode known custom errors from:

```text
IOmnibus
TermsLib
Ownable / Ownable2Step (OpenZeppelin 5.x)
```

Also preserve token-contract and Solady SafeTransferLib errors where practical.

Expose a useful SDK error type such as:

```ts
interface QuipSdkErrorDetails {
    code: string
    message: string
    contractErrorName?: string
    cause?: unknown
    details?: unknown
}
```

The complete set of active custom errors is:

From `IOmnibus`:

```text
TermsMismatch
InvalidLockState
IncorrectNativeAmountReceived
InvalidLockAdvancement
TermsAlreadyPosted
TermsNotPosted
FeeExceedsMax
CallerNotQuipWallet
ZeroQuipFactory
```

From `TermsLib`:

```text
ZeroAmount
ZeroChainId
ChainIdMismatch
DisordedDeadlines
InvalidNativeAsset
InvalidERC20Asset
InvalidERC721Asset
InvalidERC1155Asset
EmptyAssets
ZeroDeadline
UnexpectedAmountReceived
WindowViolated
ZeroAddressRecipient
InvalidRange
```

Plus the OpenZeppelin `OwnableUnauthorizedAccount` / `OwnableInvalidOwner` family for admin paths.

There are no `CallerNotSignatory`, `TermsExpired`, or `TermsNotExpired` errors. Timing failures surface as `WindowViolated`; ordering failures as `DisordedDeadlines`.

Verify exact error names and selectors from the generated ABI.

Do not discard the original Viem error.

Do not parse human-readable error strings when structured ABI error decoding is available.

---

# 20. Same-Chain Workflow Helpers

Implement non-custodial helpers for the same-chain workflow.

The roles are PROPOSER (the side with the earlier schedule; commits first) and TAKER. The secret holder must be the proposer (see the claim windows below — only the proposer can claim in the first claim window).

The SDK should help an application understand and perform:

```text
1.  Build both sides' terms with a strictly interleaved schedule:
    proposer.commitmentDeadline < taker.commitmentDeadline
        < proposer.claimDeadline < taker.claimDeadline
        < proposer.reclaimRelease < taker.reclaimRelease
2.  The proposer generates the secret and lock.
3.  Calculate the canonical trade digest.
4.  Check approvals for the proposer's wallet.
5.  Proposer commits in [0, proposer.commitmentDeadline).
6.  Lock transitions Unused -> Free.
7.  WAIT: the taker's commit window does not open until the proposer's
    commitment deadline has elapsed.
8.  Check approvals for the taker's wallet.
9.  Taker commits in [proposer.commitmentDeadline, taker.commitmentDeadline).
    The taker's commit must post the OTHER side; re-posting an already-posted
    side reverts with TermsAlreadyPosted.
10. Lock transitions Free -> Committed.
11. Anyone with the secret claims in the proposer-claim window
    [taker.commitmentDeadline, proposer.claimDeadline). One same-chain claim
    settles both legs.
12. Lock transitions Committed -> Spent.
```

Do not hide wallet signing.

Do not automatically approve or submit transactions without an explicit application call.

Provide status inspection based on actual on-chain state (`lockState`, `posted`, `termsHash`) combined with the current window.

Keep application-level statuses separate from Solidity `LockState`.

Also support the unhappy paths:

```text
- Only the proposer committed (lock = Free) and the proposer's reclaimRelease
  has passed: reclaim from Free is valid (Free -> Spent).
- Both committed but nobody claimed before a leg's reclaim window opened:
  reclaim returns assets to reclaimRecipient addresses. A reclaim where the
  counterparty leg is local and the lock is Committed returns BOTH legs in
  one transaction.
```

---

# 21. Cross-Chain Workflow Helpers

Implement helpers for safely describing and validating cross-chain swaps.

Do not build a centralized bridge.

Do not claim that one atomic transaction spans both chains.

The roles and the timing model are identical to Section 20 — one strictly interleaved six-timestamp schedule shared by both legs — but each leg lives on its own chain and each local commit moves that chain's lock Unused -> Committed directly (no Free state cross-chain).

The expected flow, with Alice as proposer and secret holder on Chain A and Bob as taker on Chain B:

```text
1. Alice generates the secret and lock.
2. Alice commits her leg on Chain A in [0, alice.commitmentDeadline).
   Chain A lock: Unused -> Committed.
3. Bob verifies Alice's commitment on Chain A (the contract cannot verify
   a remote commitment; this off-chain check is mandatory), then commits
   his leg on Chain B in [alice.commitmentDeadline, bob.commitmentDeadline).
   Chain B lock: Unused -> Committed.
4. Alice claims Bob's leg ON CHAIN B in the proposer-claim window
   [bob.commitmentDeadline, alice.claimDeadline), passing
   claim(secret, party=aliceTerms, counterparty=bobTerms).
   The Claim event on Chain B reveals the secret.
5. Bob or a relayer extracts the secret from the Chain B Claim event.
6. Bob claims Alice's leg ON CHAIN A in the taker-claim window
   [alice.claimDeadline, alice.reclaimRelease), passing
   claim(secret, party=bobTerms, counterparty=aliceTerms).
7. Both locks are Spent.
```

## Safety invariants the SDK must validate

1. The pairing interleaves strictly (mirror `validateTermPairing`). The contract enforces this on both chains; the SDK should reject bad pairings before any transaction.
2. The secret holder is the proposer. If the secret holder were the taker, the windows would let them claim the counterparty leg while retaining the ability to let their own leg expire — mis-assignment of roles is the cross-chain free-option risk the interleaving exists to prevent (see `test/attack/CrossChainFreeOption.t.sol`).
3. The taker's post-reveal reaction buffer is the gap between the latest possible reveal and the close of the taker's claim window:

```text
reactionBuffer = proposer.reclaimRelease - proposer.claimDeadline
```

Provide a validator such as:

```ts
validateCrossChainSchedule({
    proposerTerms,        // the secret holder's leg
    takerTerms,           // the counterparty's leg
    minimumBufferSeconds, // minimum acceptable gap between EVERY pair of
                          // adjacent timestamps in the interleaved schedule,
                          // including the reaction buffer above
})
```

Use explicit parameter names. Avoid ambiguous use of only `party` and `counterparty` in high-level cross-chain helpers; those names describe call-site roles, not protocol roles.

Do not silently choose a production-safe buffer. Require the application to provide the minimum buffer, or expose an explicitly documented default.

Document that buffer selection depends on:

- Chain finality
- Reorganization risk
- RPC reliability
- Network congestion
- Relayer responsiveness
- Operational safety margin

Also document the step-3 obligation prominently: the contract comments state the taker MUST verify the proposer's remote commitment has taken effect before committing; this cannot be enforced on-chain in a cross-chain swap.

---

# 22. Preserve Existing Foundry Tests

Do not replace Foundry tests with TypeScript tests.

Preserve and run the existing Solidity test suite.

Use the existing mock contracts for actual state-transition tests:

```text
ERC20Mock
ERC721Mock
ERC1155Mock
FeeOnTransferERC20Mock
QuipFactoryMock
```

`QuipFactoryMock` is mandatory wherever a real commit happens: register each committing address with `registerWallet(wallet, vaultId, owner)` so it passes the `onlyQuipWallet` gate, and use `unregisterWallet` for negative tests.

Use deployed Solidity mocks to test:

```text
balances
allowances
ownership
transfers
fee-on-transfer behavior
quip wallet gating
```

Use Foundry cheatcodes appropriately:

```text
vm.prank
vm.startPrank
vm.stopPrank
vm.deal
vm.warp
vm.expectRevert
vm.expectEmit
vm.recordLogs
vm.mockCall
vm.mockCallRevert
```

Do not use `vm.mockCall` where a real mock token is needed to verify balances or ownership changes.

Use existing harnesses:

```text
test/harness/OmnibusHarness.sol
test/harness/TermsLibHarness.sol
```

The harnesses already expose everything the SDK's differential tests need, including:

```text
TermsLibHarness.exposed_digestTerms
TermsLibHarness.exposed_digestTermsCanonically
TermsLibHarness.exposed_totalNative
TermsLibHarness.exposed_validateTermPairing
TermsLibHarness.exposed_proposedByParty
TermsLibHarness.exposed_enforceWithin
TermsLibHarness.exposed_validateTerms
TermsLibHarness.exposed_validateAsset
OmnibusHarness.exposed_generateLock
OmnibusHarness.computeTermsHash
OmnibusHarness.computeTermsDigest
OmnibusHarness.setLockState / setTermsHash / setPosted
```

Do not add new harness methods unless something genuinely needed is missing, and do not make production functions public solely for testing.

Also study `test/Omnibus/Omnibus.t.sol`: it defines the canonical interleaved schedule (ALICE_* = proposer, BOB_* = taker) and the per-action time anchors (AT_PROPOSER_COMMIT etc.). Reuse the same schedule shape in TypeScript tests so the two suites stay comparable.

---

# 23. Pure TypeScript Unit Tests

Use Vitest.

## Asset-builder tests

Test:

```text
Native canonical fields (target = zero, id = 0n)
ERC-20 canonical fields (id MUST be 0n)
ERC-721 amount always equals 1n after canonicalization
ERC-1155 canonical fields
zero amount rejection (all four types, including ERC-721)
zero target rejection (ERC-20/721/1155)
non-zero id rejection for ERC-20
non-zero target or id rejection for Native
token id zero ACCEPTED for ERC-721 and ERC-1155
invalid enum values
immutability where practical
```

## Terms-validation tests

Test:

```text
zero chain ID
zero reclaimRecipient
zero recipient
zero commitmentDeadline
non-strict ordering rejected (equal timestamps anywhere)
commitmentDeadline >= claimDeadline rejected
claimDeadline >= reclaimRelease rejected
empty assets
invalid nested assets
structural validation does NOT reject elapsed deadlines
```

## Pairing and window tests

Test:

```text
valid interleaving (A proposes) accepted
valid interleaving (B proposes) accepted
non-interleaved schedules rejected
equal timestamps across sides rejected
proposedBy identifies the smaller commitmentDeadline
enforceWithin: lower inclusive
enforceWithin: upper EXCLUSIVE (timestamp == upper rejected)
enforceWithin: degenerate range (lower >= upper) rejected
each derived action window matches the contract's enforceWithin calls
```

## Native-total tests

Test:

```text
no native assets
one native asset
multiple native assets
mixed asset types
```

## Secret-and-lock tests

Test:

```text
generated secret is 32 bytes
generated lock is 32 bytes
fixed secret produces expected Solidity-compatible lock
invalid secret length rejected
invalid hex rejected
```

## Hashing tests

Test:

```text
same input produces same digest
every one of the seven Terms fields affects the digest
  (chainId, reclaimRecipient, recipient, commitmentDeadline,
   claimDeadline, reclaimRelease, assets)
asset target / id / amount affect the digest
asset order affects the single-side digest
canonical digest is order-independent across sides
single-side digest is not order-independent
```

## Cross-chain schedule tests

Test:

```text
correct interleaving accepted
secret holder not the proposer rejected
reversed schedules rejected
insufficient buffer rejected
sufficient buffer accepted
```

Do not use RPC calls for tests that can remain pure.

---

# 24. Mocked Viem Client Tests

Use mocked Viem clients only to test SDK orchestration.

Test:

```text
correct contract function selected (commit / claim / reclaim)
correct ABI arguments passed (7-field Terms tuples)
exact msg.value calculated
commitmentFee read before commit
quip-wallet eligibility (vaultIdOf) read before commit
simulation called before write
simulated request passed into writeContract
missing wallet client produces a clear error
non-quip-wallet sender rejected before submission with a clear error
chain mismatch rejected before submission (party local for commit/reclaim,
  counterparty local for claim)
commit outside the sender's window rejected before submission
```

Do not treat mocked-client tests as proof that ABI encoding matches Solidity.

Avoid unsafe production casts such as:

```ts
as never
```

A limited test-only cast may be acceptable where required to build a small mock.

---

# 25. Solidity/TypeScript Differential Tests

This is mandatory.

Deploy `TermsLibHarness` and `OmnibusHarness` to Anvil (the harness constructor needs `(initialOwner, quipFactory)` — deploy a `QuipFactoryMock` first).

Compare TypeScript output directly against Solidity output.

At minimum, verify:

```text
TypeScript digestTerms             == TermsLibHarness.exposed_digestTerms
TypeScript digestTermsCanonically  == TermsLibHarness.exposed_digestTermsCanonically
TypeScript generateLock            == OmnibusHarness.exposed_generateLock
TypeScript totalNative             == TermsLibHarness.exposed_totalNative
TypeScript validateTermPairing     == TermsLibHarness.exposed_validateTermPairing
                                      (accept/reject parity across vectors)
TypeScript window math             == TermsLibHarness.exposed_enforceWithin
                                      (boundary parity: lower, upper-1, upper)
```

Use deterministic vectors containing:

```text
Native assets
ERC-20 assets
ERC-721 assets (including amount values other than 1, to prove digest
  sensitivity and justify SDK canonicalization)
ERC-1155 assets
Token id zero
Multiple assets and varied ordering
Different reclaimRecipients and recipients
Different chain IDs
Different timestamp schedules (valid and invalid interleavings)
Digest pairs near the canonical-ordering boundary
```

Include a deterministic generated-vector loop using a fixed seed.

Do not calculate the expected result using the same TypeScript function being tested.

The Solidity harness must be the comparison oracle.

---

# 26. Single-Chain Anvil Integration Tests

Create an automated integration-test runner that:

1. Starts Anvil on a dedicated or available port.
2. Uses a known local chain ID.
3. Waits until RPC is ready.
4. Runs `forge build`.
5. Deploys, using actual Foundry artifacts (ABI and bytecode):
   - `QuipFactoryMock` — then registers every test account that will commit,
     via `registerWallet`
   - `Omnibus` with constructor args `(owner, quipFactoryMockAddress)`
   - `ERC20Mock`
   - `ERC721Mock`
   - `ERC1155Mock`
   - `FeeOnTransferERC20Mock`
   - `TermsLibHarness`
   - `OmnibusHarness`, where needed
6. Creates Viem public and wallet clients.
7. Runs integration tests.
8. Terminates Anvil whether tests pass or fail.

Do not require developers to start Anvil manually for the normal integration-test command.

The timing model requires controlling block timestamps: the taker's commit window only opens after the proposer's commitment deadline, and claim/reclaim windows are bounded. Use Anvil time control (`evm_setNextBlockTimestamp` / Viem test client `setNextBlockTimestamp` + mining) between steps, mirroring the warp anchors in `test/Omnibus/Omnibus.t.sol`.

## Read tests

Test:

```text
VERSION
MAX_FEE
QUIP_FACTORY (equals the deployed mock)
commitmentFee
accruedFees
lockState
termsHash
posted
```

## QuipWallet gating tests

Test:

```text
registered wallet can commit
unregistered account reverts CallerNotQuipWallet
SDK preflight catches the unregistered case before submission
claim and reclaim succeed from unregistered accounts
```

## Native commit tests

Test:

```text
exact native amount plus fee succeeds
underpayment fails (IncorrectNativeAmountReceived)
overpayment fails (IncorrectNativeAmountReceived)
fee accrual visible in accruedFees
```

## ERC-20 tests

Test:

```text
missing approval detected by the approval planner
approval succeeds
commit pulls correct token balance into Omnibus
```

## ERC-721 tests

Test:

```text
single-token approval
operator approval
NFT ownership moves to Omnibus on commit
NFT ownership moves to the claiming side's recipient on claim
```

## ERC-1155 tests

Test:

```text
operator approval
correct quantity moves on commit
correct quantity moves on claim
```

## Same-chain happy path

Test:

```text
proposer commit -> Free
advance time past proposer.commitmentDeadline
taker commit -> Committed
advance time into the proposer-claim window
claim -> Spent
both legs' assets reach the intended recipients in the single claim
Claim event decoded; secret recovered equals the original
Commitment events decoded; recovered Terms equal the inputs
```

## Reclaim flow

Test:

```text
reclaim before reclaimRelease fails (WindowViolated)
time advances
reclaim after reclaimRelease succeeds
assets return to reclaimRecipient (not to the committer per se)
both legs returned in one reclaim when counterparty leg is local and
  lock was Committed (two Reclaimed events)
reclaim from Free (only proposer committed) succeeds after release
state becomes Spent
```

## Invalid operations

Test:

```text
unregistered committer (CallerNotQuipWallet)
wrong chain ID (ChainIdMismatch)
commit outside window (WindowViolated)
taker commit before proposer deadline (WindowViolated)
non-interleaved schedules (DisordedDeadlines)
duplicate same-side commit (TermsAlreadyPosted)
terms mismatch on second commit (TermsMismatch)
claim with wrong secret (TermsMismatch — wrong lock has no termsHash)
claim on non-Committed lock (InvalidLockState)
double claim (InvalidLockState / InvalidLockAdvancement)
double reclaim (InvalidLockAdvancement)
```

## Fee-on-transfer token

Verify that an underfunded escrow caused by a fee-on-transfer ERC-20 is rejected with:

```text
UnexpectedAmountReceived
```

Do not fake these results with mocked RPC clients.

---

# 27. Two-Chain Anvil End-to-End Tests

Create a separate test runner that starts two Anvil instances.

Use distinct ports and chain IDs.

For example:

```text
Chain A: dedicated free port, chain ID 31337
Chain B: another dedicated free port, chain ID 31338
```

Do not hardcode ports if doing so makes parallel test execution unreliable.

The runner must stop both processes after completion or failure.

Deploy on EACH chain: a `QuipFactoryMock` (register the committing accounts), an `Omnibus`, and the required mock assets. Keep both chains' block timestamps coordinated with the shared schedule using time control on each.

## Successful cross-chain flow

Test:

```text
1.  Generate a fixed test secret and lock.
2.  Build one strictly interleaved six-timestamp schedule.
3.  Alice is the proposer AND the secret holder; her leg is on Chain A.
4.  Bob is the taker; his leg is on Chain B.
5.  Alice approves and commits on Chain A inside her window.
    Chain A lock: Unused -> Committed.
6.  (Off-chain step the SDK should model) Bob verifies Alice's Chain A
    commitment via lockState/posted before committing.
7.  Advance both chains past Alice's commitment deadline.
8.  Bob approves and commits on Chain B inside his window.
    Chain B lock: Unused -> Committed.
9.  Advance both chains into the proposer-claim window.
10. Alice claims Bob's leg on Chain B with
    claim(secret, aliceTerms, bobTerms).
11. Decode the secret from the Chain B Claim event; assert it equals
    the original.
12. Advance both chains into the taker-claim window.
13. Bob claims Alice's leg on Chain A with
    claim(secret, bobTerms, aliceTerms).
14. Both lock states are Spent.
15. Verify final token balances and NFT ownership on both chains.
```

Also test:

```text
secret holder assigned as taker rejected by the SDK validator
non-interleaved schedule rejected by SDK and by contract
insufficient buffer rejected by the SDK validator
one-leg reclaim after that leg's reclaimRelease when the other leg
  was never claimed
duplicate Claim-event processing is idempotent at workflow level
```

Do not describe this as true cross-chain atomicity.

It is a coordinated flow across two independent EVM chains; the interleaved schedule plus the off-chain commitment check are what bound each side's risk.

---

# 28. QuipWallet Compatibility

The only accounts that can commit in production are QuipWallet contracts deployed by the QuipFactory. The Solidity gate is:

```solidity
modifier onlyQuipWallet() {
    if (QUIP_FACTORY.vaultIdOf(msg.sender) == bytes32(0)) revert CallerNotQuipWallet();
    _;
}
```

Document and test:

- The committer is the QuipWallet CONTRACT address, not its owner's EOA.
- Assets must belong to the QuipWallet.
- Approvals must be issued by the QuipWallet.
- The owner EOA must not be substituted automatically.
- `claim` and `reclaim` have no such gate; any account (EOA, relayer, contract) may call them.
- In tests, `QuipFactoryMock.registerWallet` makes plain EOAs pass the gate; this is a test convenience, not a production pattern.

The repository does not include the QuipWallet implementation itself. Do not build wallet infrastructure or an ERC-4337 integration. Design the client so a Viem client whose account/sender is a QuipWallet-compatible contract can be supplied later, and so the eligibility preflight (`vaultIdOf`) works against any factory the deployed Omnibus points to.

---

# 29. Makefile Integration

Extend the root `Makefile` with clear targets such as:

```text
sdk-install
sdk-generate
sdk-typecheck
sdk-test
sdk-test-integration
sdk-test-cross-chain
sdk-build
check
```

Keep all existing Foundry targets working.

Create a root verification target that runs all reasonable checks.

Cross-chain tests may remain a separate slower target, but document them clearly.

Update stale comments and environment-variable references only where the correct replacement can be verified from active code (e.g. the `deploy-local` comment references `PORTAL_ADMIN`, which no active script consumes). Do not rewrite the deployment scripts as part of this task; flag their stale constructor encoding in the final report instead.

---

# 30. Documentation

Create a practical:

```text
sdk/README.md
```

It must include:

1. What the SDK does.
2. Installation instructions.
3. ABI generation.
4. Creating Viem clients.
5. Creating an Omnibus SDK client.
6. Asset builders.
7. Creating terms — including the three lifecycle timestamps and the strict interleaving rule.
8. The timing-window model, with a diagram or table of the five action windows.
9. Secret and lock generation.
10. The QuipWallet gate on commit and the eligibility preflight.
11. Approval checking.
12. Same-chain flow (proposer commit, wait, taker commit, claim).
13. Claim flow, including that one same-chain claim settles both legs.
14. Reclaim flow, including dual-leg reclaim and reclaim-from-Free.
15. Cross-chain flow, role assignment (secret holder = proposer), and the mandatory off-chain commitment check before the taker commits.
16. Buffer selection guidance.
17. Error handling.
18. Running unit / integration / two-chain tests.
19. Security limitations.
20. Deployment-registry behavior and the stale-deploy-script caveat.

Update the root README sufficiently so a new developer can discover the SDK and run its tests.

Do not leave the root README as only a generic Foundry template.

Do not place:

- Real private keys
- RPC secrets
- Production credentials
- Real swap secrets

in documentation or examples.

---

# 31. Code-Quality Requirements

Use:

```text
strict TypeScript
no implicit any
no silent catch blocks
no secret logging
no floating promises
```

Prefer:

- Small functions
- Readonly inputs
- Explicit return types for public APIs
- Centralized ABI definitions
- Clear error messages
- Deterministic tests
- Minimal dependencies

Avoid:

- One giant SDK class
- Mutating caller-supplied terms
- Hidden global state
- Unsafe type casts
- Duplicated ABI tuple definitions
- Heavy dependencies without justification

## Docstrings and Comments (mandatory)

The codebase must be self-explanatory to a developer who has never read the Solidity. Apply the following rules throughout the SDK and its test infrastructure.

### TSDoc on every export

Every exported type, interface, enum, constant, class, and function must carry a complete TSDoc block:

- `@param` for every parameter, stating units (seconds vs milliseconds, wei, basis points) and valid ranges.
- `@returns` describing the value, not just its type.
- `@throws` for every error class or rejection the function can produce, including which `QuipSdkErrorDetails.code` it maps to.
- `@example` with a short, runnable snippet for the primary entry points: asset builders, `createTerms`, the validators, the hashing functions, secret generation, `createOmnibusClient`, the approval planner, the event decoders, and both workflow helpers.
- `@see` references back to the Solidity source of truth, naming the contract and function, e.g. `@see TermsLib.validateTermPairing` or `@see Omnibus.commit (onlyQuipWallet)`. Every function that mirrors Solidity behavior must name exactly what it mirrors.

### Document the protocol, not just the signature

Docstrings on protocol-level functions must state the invariant they uphold and the consequence of violating it, in plain language. Required at minimum:

- `digestTerms` / `digestTermsCanonically` / `generateLock`: the exact encoding (seven-field `abi.encode`, smaller-digest-first concatenation, keccak256 of the raw 32-byte secret) and that any deviation breaks cross-chain hash agreement.
- Every field of the `Terms` interface: per-field doc comments mirroring the Solidity natspec (`reclaimRecipient` receives on reclaim, `recipient` receives the COUNTERPARTY's assets, the three timestamps and what each gates).
- Window helpers: that windows are half-open `[lower, upper)`, why the upper bound is exclusive (adjacent windows share a boundary; exactly one accepts the shared instant), and which contract call enforces each window.
- Pairing helpers: the full interleaving inequality and that the proposer is the side with the smaller `commitmentDeadline`.
- Commit helpers: the QuipWallet gate, the exact-`msg.value` rule, and that the taker's window opens only after the proposer's deadline elapses.
- Claim helpers: that claiming is permissionless, that one same-chain claim settles both legs, and that the `Claim` event publicly reveals the secret.
- Reclaim helpers: permissionless, pays `reclaimRecipient`, dual-leg behavior, valid from `Free`.
- Cross-chain validators: secret holder must be the proposer, the reaction-buffer formula, and the mandatory off-chain commitment check before the taker commits.
- Secret generation: the secrecy lifecycle (lock shareable, secret private until claim, early reveal compromises the flow, loss makes claiming impossible).

### Inline comments

- Comment the WHY, not the what. Do not narrate obvious code (`// increment i`); do explain every protocol-driven decision, e.g. why structural validation deliberately skips deadline freshness, why ERC-721 amounts are canonicalized to `1n` when the contract only requires non-zero, why digests are compared as unsigned bigints rather than strings, why the fee is re-read immediately before simulation.
- Wherever TypeScript logic is a transcription of Solidity, include a short comment quoting or paraphrasing the corresponding Solidity lines so a reviewer can diff the two by eye.
- Mark every deliberate divergence from contract behavior (there should be very few; ERC-721 canonicalization is the known one) with a clearly searchable comment such as `// SDK-STRICTER-THAN-CONTRACT: ...`.
- Annotate security-sensitive lines (secret handling, value calculation, address checks) so they survive future refactors.

### Tests and scripts

- Each test file opens with a block comment stating what part of the protocol it covers and which Solidity tests it parallels.
- Each non-trivial test case gets a one-to-three-line comment stating the invariant under test and, for revert tests, the exact contract error expected and why the setup triggers it.
- Differential tests must document that the Solidity harness is the oracle and which harness function each comparison targets.
- The Anvil runners must comment the lifecycle (port selection, readiness wait, deployment order including QuipFactory registration, timestamp control, teardown) step by step.
- The ABI generation script must document its input artifact, output guarantees (deterministic, ABI-only, `as const`), and failure behavior.

### Style

- Use standard TSDoc syntax so editors and `typedoc` can consume it; do not invent custom tag formats.
- Keep docstrings accurate over verbose: every claim in a docstring must be true of the code as written and verified against the contracts. An incorrect docstring is a bug; treat doc/code divergence found during testing as a failure to fix, not a nit.
- Do not let comments restate stale assumptions from older protocol versions (signatory, single deadline, `execute`); these terms must not appear anywhere in the SDK.

---

# 32. Protocol-Safety Requirements

Pay special attention to these invariants:

1. TypeScript hashing must match Solidity exactly (seven-field Terms encoding).
2. Commit must send exact `msg.value = totalNative(party) + commitmentFee`.
3. Only registered QuipWallets can commit; the SDK must preflight `vaultIdOf`.
4. ERC-721 represents one specific NFT; the SDK canonicalizes `amount: 1n` even though the contract only enforces `amount != 0`.
5. ERC-20 assets must have `id == 0n` (contract-enforced).
6. For commit and reclaim, only `party.chainId` must match the connected chain; for claim, `counterparty.chainId` must (the claimed leg is local).
7. Lifecycle timestamps must strictly interleave across sides; the proposer is the side with the earlier `commitmentDeadline` and commits first.
8. The taker's commit window opens only when the proposer's commitment deadline elapses. All windows are half-open `[lower, upper)` with an exclusive upper bound.
9. A cross-chain local commit moves Unused -> Committed; a same-chain first commit moves Unused -> Free; the second distinct-side commit moves Free -> Committed; Free -> Spent is a valid reclaim path.
10. `claim` may be called by anyone who possesses the secret; one same-chain claim settles both legs.
11. `reclaim` is permissionless, gated only by the local leg's `reclaimRelease`, pays `reclaimRecipient`, and can settle both legs when the counterparty leg is local and the lock is Committed.
12. In a cross-chain swap the secret holder must be the proposer; the taker's post-reveal reaction buffer is `proposer.reclaimRelease - proposer.claimDeadline`.
13. The taker must verify the proposer's remote commitment off-chain before committing; the contract cannot.
14. A transaction hash is not final confirmation.
15. Events can be duplicated or reorganized; `Reclaimed` can legitimately appear twice in one transaction.
16. Approval must not be assumed merely because a transaction was submitted; fee-on-transfer tokens fail commit despite sufficient allowance.
17. Deployment addresses must not be guessed, and the stale deploy scripts must not be used for address derivation.
18. SDK validation does not replace contract enforcement.
19. Secrets must never be logged.
20. Token ID zero is valid for ERC-721 and ERC-1155 and must not be rejected.
21. Caller-supplied objects must not be silently mutated.

---

# 33. Do Not Silently Change Solidity Semantics

The main task is SDK development and test integration.

Do not modify production Solidity behavior merely because it makes the SDK easier to implement.

You may:

- Add test-only harness methods (the existing harnesses likely already cover everything needed).
- Add mock contracts.
- Add regression tests.
- Fix an unambiguous bug required for correctness.

Before changing production Solidity:

1. Identify the exact bug.
2. Explain the current behavior.
3. Add a failing regression test.
4. Make the smallest possible fix.
5. Run the complete Foundry and SDK suites.
6. Document the change prominently.

The stale deployment scripts (single-argument constructor encoding) are a known issue: report it; only fix it if you can verify the intended `quipFactory` argument source, and never invent a factory address.

Do not perform unnecessary refactoring of audited contract code.

---

# 34. Required Commands

At minimum, execute and report the real results of:

```bash
forge fmt --check
forge build
forge test
```

Then execute from `sdk/`:

```bash
bun install
bun run generate:abi
bun run typecheck
bun run test:unit
bun run test
bun run build
bun run test:integration
bun run test:cross-chain
```

Use the exact commands you create if script names differ.

Also run the root Makefile verification targets you add.

Do not claim a command passed unless it was actually executed successfully.

If a command cannot run because of an environmental limitation:

1. Show the exact command.
2. Show the exact failure.
3. Explain whether it is an implementation failure or an environment failure.
4. Complete every other task that can still be completed.
5. Do not mark the blocked test as passing.

---

# 35. Final Deliverables

When complete, provide a final report with the following sections.

## Architecture

Explain the implemented layers:

```text
Pure protocol helpers (assets, terms, pairing, windows, hashing, secrets)
ABI generation
Read client
Write client (with QuipWallet preflight)
Approval planner
Receipt helpers
Event helpers
Same-chain workflow
Cross-chain workflow
Test infrastructure
```

## Files changed

List all significant created and modified files.

## Public API

Show the main exported:

```text
Types
Builders
Validators (structural, pairing, windows, cross-chain schedule)
Hashing functions
Client methods
Approval functions
Event functions
Workflow helpers
```

## Testing

Report the results of:

```text
Foundry tests
Vitest unit tests
Mocked-client tests
Single-chain integration tests
Solidity/TypeScript differential tests
Two-chain end-to-end tests
```

Include actual test counts when available.

## Documentation coverage

Confirm that every exported symbol carries the TSDoc required by Section 31, list the `@example`-bearing entry points, and list every `SDK-STRICTER-THAN-CONTRACT` marker present in the code with a one-line justification for each.

## Commands

List the exact commands another developer should run to reproduce all checks.

## Security decisions

Explain:

```text
Secret generation
Hash compatibility
Exact msg.value
ERC-721 canonicalization
ERC-20 id-zero rule
QuipWallet gating and preflight
Window validation
Cross-chain role assignment and buffer validation
Event confirmations
Deployment-address handling (including the stale-script finding)
```

## Outstanding work

Clearly identify anything still requiring external information:

```text
Verified testnet deployment addresses
Production deployment addresses (Omnibus AND QuipFactory per chain)
The real QuipFactory address(es) and QuipWallet integration details
Supported-chain registry
Recommended production confirmation counts
Recommended cross-chain schedule buffers
Final npm package name
Publishing registry
Production RPC policy
```

Do not fabricate any of these values.

---

# 36. Execution Requirements

Work autonomously through the implementation.

Do not stop after:

- Explaining the architecture
- Writing a plan
- Creating package scaffolding
- Writing only types
- Writing only mocked tests
- Writing only unit tests

Run tests incrementally.

When a test fails, determine whether the cause is:

```text
SDK implementation
Test implementation
Solidity contract behavior
ABI generation
Hash encoding
Window / timestamp handling in Anvil
QuipFactory registration setup
Anvil setup
Process cleanup
Environment limitation
```

Fix the root cause rather than weakening the assertion.

The final repository state must contain a working SDK with reproducible tests, not merely a design proposal.