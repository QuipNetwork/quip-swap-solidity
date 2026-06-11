# Quip Swap SDK — Build Task List

A phased checklist for implementing the TypeScript SDK under `sdk/`. Work top-to-bottom; later phases depend on earlier ones.

Reference spec: [`../quip_swap_sdk_claude_code_prompt.md`](../quip_swap_sdk_claude_code_prompt.md)

---

## Phase 0 — Understand the protocol (before writing SDK code)

- [ ] Read source of truth: `Omnibus.sol`, `TermsLib.sol`, `IOmnibus.sol`, `IQuipFactory.sol`
- [ ] Read Foundry tests — especially `Omnibus.t.sol` — for canonical timing, lock states, and commit/claim/reclaim sequencing
- [ ] Read harnesses and mocks (`QuipFactoryMock`, `TermsLibHarness`, etc.)
- [ ] Run `forge build` and `forge test`; note pre-existing failures separately from new ones
- [ ] Catalog every contract function, event, custom error, and lock-state transition the SDK must support
- [ ] Verify hashing semantics (`digestTerms`, `digestTermsCanonically`, `generateLock`) against Solady — no guessing

---

## Phase 1 — Project scaffolding

- [ ] Create `sdk/` with Bun + TypeScript (strict) + Vitest + tsup
- [ ] Configure ESM exports, `peerDependencies` on Viem, build/typecheck/test scripts
- [ ] Wire root `Makefile` targets (`sdk-install`, `sdk-test`, etc.)
- [ ] Implement ABI generation script (`forge build` → `src/generated/omnibusAbi.ts`, `as const`, deterministic, fails clearly if artifact missing)

---

## Phase 2 — Core types and errors

- [ ] Mirror Solidity types in `types.ts`: `AssetType`, `Asset`, `Terms`, `LockState`, `Hex32`
- [ ] Use `bigint` for all integers; Viem `Address` / `Hex` / `Hash` where appropriate
- [ ] Build `QuipSdkError` with stable codes, contract error decoding, preserved `cause`
- [ ] Map every relevant Solidity custom error to a decodable SDK code/name

---

## Phase 3 — Pure protocol layer (no RPC)

Testable without a chain; must mirror `TermsLib` exactly.

- [ ] **Assets** (`assets.ts`): builders for Native/ERC-20/ERC-721/ERC-1155, `validateAsset`, `totalNative`
- [ ] **Terms** (`terms.ts`): `createTerms`, `validateTerms`, `validateTermPairing`, `proposedBy`
- [ ] **Windows** (`windows.ts`): half-open `[lower, upper)` math, per-action windows (commit/claim/reclaim), `enforceWithin`
- [ ] **Hashing** (`hashing.ts`): `digestTerms`, `digestTermsCanonically`, `generateLock`, ABI encoding helpers — byte-for-byte match with Solidity
- [ ] **Secrets** (`secrets.ts`): CSPRNG secret generation, `secretToPair`, never log secrets in errors
- [ ] **Deployments** (`deployments.ts`): empty-by-default registry, explicit `resolveDeployment(chainId, address)`

---

## Phase 4 — Chain client layer

- [ ] **Client** (`client.ts`): `createOmnibusClient` with typed reads (`getVersion`, `getLockState`, `getCommitmentFee`, …)
- [ ] Implement writes: `commit`, `claim`, `reclaim` with simulation + preflight before send
- [ ] Preflight checks: terms validation, window validation, chain ID match, QuipWallet gate (`isQuipWallet` via `vaultIdOf`)
- [ ] Admin surface: `setCommitmentFee`, `withdrawFees` behind typed interface
- [ ] **Approvals** (`approvals.ts`): `planApprovals` (ERC-20 allowance aggregation, ERC-721/1155 approval checks), `submitApproval` with explicit ERC-20 mode (`exact` | `unlimited`, never defaulted)
- [ ] **Receipts** (`receipts.ts`): `waitForOmnibusReceipt` with confirmations/timeout
- [ ] **Events** (`events.ts`): decode/query `Commitment`, `Claim`, `Reclaimed`; `extractRevealedSecret` from claim logs

---

## Phase 5 — Workflow helpers

- [ ] **Same-chain** (`workflows/sameChain.ts`): `planSameChainSwap` (role normalization), `getSameChainSwapStatus`
- [ ] **Cross-chain** (`workflows/crossChain.ts`): `validateCrossChainSchedule` (secret holder = proposer, minimum buffers), `verifyRemoteCommitment`, `deriveSharedLock`
- [ ] Document non-atomic cross-chain risks and mandatory off-chain verification step

---

## Phase 6 — Public API surface

- [ ] Barrel export in `index.ts` — clear layering: pure helpers → chain access → workflows
- [ ] Do **not** export test utilities (Anvil runners, deploy helpers)

---

## Phase 7 — Testing pyramid

- [ ] **Unit tests** (no chain): assets, terms, windows, hashing, secrets, cross-chain schedule logic
- [ ] **Mocked client tests**: Viem client mocks for preflight, error wrapping, write orchestration
- [ ] **Differential tests**: TS vs deployed `TermsLibHarness` / `OmnibusHarness` on Anvil — hashing, windows, pairing as oracle
- [ ] **Integration tests**: single Anvil node, deploy real artifacts, full commit → claim / reclaim flows
- [ ] **Cross-chain E2E**: two Anvil nodes, proposer on chain A, taker on chain B, secret reveal via claim event, remote claim
- [ ] Test infra: `run-integration-tests.ts`, `run-cross-chain-tests.ts`, fixtures, `QuipFactoryMock.registerWallet` for commit gate

---

## Phase 8 — Docs and hardening

- [ ] Write `sdk/README.md`: install, ABI gen, client setup, asset/terms model, timing windows, same-chain and cross-chain flows, approvals, errors, test commands
- [ ] Document security limits: SDK is preflight only, no key custody, fee-on-transfer caveat, empty deployment registry, stale deploy scripts
- [ ] Code quality pass: no silent semantic drift from Solidity, actionable error messages, `SDK-STRICTER-THAN-CONTRACT` cases documented (e.g. ERC-721 amount canonicalization)
- [ ] Final gate: `typecheck`, unit + mocked tests, integration, cross-chain, `build`

---

## Build order (summary)

```text
Understand Solidity
       ↓
Scaffold + ABI gen
       ↓
Types + errors
       ↓
Pure protocol (assets → terms → windows → hashing → secrets)
       ↓
Client + approvals + receipts + events
       ↓
Workflows (same-chain, cross-chain)
       ↓
Tests (unit → mocked → differential → integration → E2E)
       ↓
README + Makefile + polish
```

---

## Highest-effort areas

These typically consume the most time and deserve differential / integration coverage:

1. **Hashing/encoding parity** with Solidity
2. **Half-open window math** matching `TermsLib.enforceWithin`
3. **Cross-chain schedule validation** (free-option attack, buffer requirements)
4. **Approval planning** across four asset types without auto-approving
5. **QuipWallet commit gate** preflight (`NOT_QUIP_WALLET` is the common integration failure)

---

## Final deliverables checklist

- [ ] `sdk/src/` — all modules implemented and exported via `index.ts`
- [ ] `sdk/src/generated/omnibusAbi.ts` — generated, not hand-maintained
- [ ] `sdk/test/` — unit, mocked, differential, integration, cross-chain
- [ ] `sdk/README.md` — complete integration guide
- [ ] Root `Makefile` — SDK targets wired
- [ ] `bun run check` passes (typecheck + unit/mocked tests + build)
- [ ] `bun run test:integration` passes
- [ ] `bun run test:cross-chain` passes
