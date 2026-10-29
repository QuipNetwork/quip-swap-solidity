/**
 * The Omnibus SDK client: typed reads, preflighted writes, and admin
 * operations against one deployed Omnibus contract.
 *
 * Design rules:
 * - Accepts EXISTING Viem clients — browser wallets, local private-key
 *   accounts, backends, and hardware-wallet transports. The SDK never takes
 *   custody of private keys, raw RPC URLs, or a specific wallet impl.
 * - Every write runs the protocol preflights first, then `prepareTx`
 *   (a balance preflight on the bare call value, then node-side gas
 *   estimation — which surfaces would-be reverts before submission — with
 *   a safety-buffered gas limit), then `writeContract`. Nothing is sent
 *   blind.
 * - Every write preflights the same conditions the contract enforces, so
 *   integration failures surface as actionable errors BEFORE a transaction
 *   exists. Preflight mirrors but never replaces on-chain enforcement.
 * - User operations (`commit`/`claim`/`reclaim`) and owner administration
 *   (`admin.*`) are exposed on separate namespaces so they cannot be
 *   confused.
 */
import {BaseError, InsufficientFundsError, encodeFunctionData, size} from 'viem'
import type {Address, Hash, Hex, PublicClient, WalletClient} from 'viem'
import {totalNative} from './assets.js'
import {assertSignerBlob} from './commitAuth.js'
import type {CommitAuth} from './commitAuth.js'
import {QuipSwapError, wrapContractError} from './errors.js'
import {prepareTx} from './gas.js'
import type {TxOptions} from './gas.js'
import {omnibusAbi} from './generated/omnibusAbi.js'
import {assertHex32, digestTerms, digestTermsCanonically, generateLock, swapId} from './hashing.js'
import {proposedBy, validateTermPairing, validateTerms} from './terms.js'
import {waitForOmnibusReceipt} from './receipts.js'
import type {OmnibusReceipt, WaitOptions} from './receipts.js'
import {AssetType, LockState} from './types.js'
import type {Hex32, Terms} from './types.js'
import {validateClaimWindow, validateCommitWindow, validateReclaimWindow} from './windows.js'

/** Arguments for {@link createOmnibusClient}. */
export interface CreateOmnibusClientArgs {
  /** The deployed Omnibus contract address (see {@link resolveDeployment}). */
  readonly address: Address
  /** A Viem public client connected to the chain the contract lives on. */
  readonly publicClient: PublicClient
  /**
   * A Viem wallet client for writes. Optional: a read-only client works
   * without one, and writes then fail with `MISSING_WALLET_CLIENT`. All
   * writes are permissionless — but note the FUNDING MODEL: the commit
   * SENDER funds the party's leg + fee; the identity in `auth` only
   * authorizes.
   */
  readonly walletClient?: WalletClient
}

/** Arguments for {@link OmnibusClient.commit}. */
export interface CommitArgs {
  /** The hashlock (`generateLock(secret)`); the proposer generates the secret. */
  readonly lock: Hex32
  /** The committing side's terms — the auth identity endorses this side. */
  readonly party: Terms
  /** The other side's terms. */
  readonly counterparty: Terms
  /**
   * The committing side's identity blob + signature over the commit digest
   * (see {@link computeCommitDigest} / {@link buildKeyedSigner}). The SDK
   * never signs: `signature` is opaque bytes from the keyholder's own tooling.
   */
  readonly auth: CommitAuth
  /**
   * When `true` (default), preflight additionally reads the lock's
   * on-chain state: a `Spent` or `Committed` lock rejects with
   * `INVALID_LOCK_STATE` (no commit can advance from those states), and a
   * `Free` lock requires the canonical `termsHash` to match
   * (`TERMS_NOT_ON_CHAIN` otherwise) and the committing side to not
   * already be posted (`TERMS_ALREADY_POSTED` otherwise — the second
   * same-chain commit must post the OTHER side). Costs three extra
   * parallel reads; with the flag off, gas estimation still catches every
   * case as a decoded `CONTRACT_REVERT`.
   */
  readonly verifyOnChainState?: boolean
  /**
   * When `true`, skips the reasonableness guard that rejects a `reclaimRelease`
   * more than {@link MAX_RECLAIM_HORIZON_SECONDS} (two weeks) beyond the chain's
   * current time. The guard exists because a far-future `reclaimRelease` leaves a
   * leg unrecoverable until then if the swap fails — but a long window may be
   * intentional, so this flag is the explicit opt-out. Default `false` (guard on).
   */
  readonly allowDistantReclaimRelease?: boolean
}

/**
 * A single contract call in the ERC-5792 / ERC-4337 shape: the exact
 * `{to, value, data}` a transaction (or a smart account's `execute`) must
 * carry. Produced by {@link OmnibusClient.prepareCommit} and
 * {@link prepareApproval}; the SDK never executes a `Call` on behalf of a
 * smart account — that is the account's own tooling's job.
 */
export interface Call {
  /** The contract to call. */
  readonly to: Address
  /** Native value to attach (wei). */
  readonly value: bigint
  /** ABI-encoded calldata. */
  readonly data: Hex
}

/** Options for {@link OmnibusClient.prepareCommit}. */
export interface PrepareCallOptions {
  /**
   * The account that will be `msg.sender` when the call executes — for a
   * smart account (e.g. a quip wallet), the ACCOUNT CONTRACT's address, not
   * the key that signs or the EOA that pays gas. Every account-dependent
   * preflight (balance, factory membership, revert simulation) runs against
   * this address, because on-chain the assets are pulled from `msg.sender`
   * and `msg.value` is the account's own balance.
   */
  readonly account: Address
  /**
   * Skips ONLY the balance preflight (`getBalance(account) >= value`), never
   * the protocol preflights. Default `false`.
   */
  readonly skipPreflightChecks?: boolean
}

/** Arguments for {@link OmnibusClient.claim}. */
export interface ClaimArgs {
  /** The 32-byte preimage of the lock. Sending it on-chain reveals it publicly. */
  readonly secret: Hex32
  /** The claimant role's terms (the side the claimant acts for). */
  readonly party: Terms
  /** The other side's terms — the leg being claimed; must be local. */
  readonly counterparty: Terms
  /**
   * When `true` (default), preflight additionally verifies on-chain state
   * in one parallel read batch: `lockState(swapId)` must be `Committed`
   * (`INVALID_LOCK_STATE` otherwise, with the actual state and likely
   * cause), `termsHash(swapId)` must equal the canonical digest, and the
   * counterparty's side must be `posted` (`TERMS_NOT_ON_CHAIN` otherwise).
   * Costs three extra parallel reads; disable only if you have just
   * verified the state yourself — estimation still catches everything.
   */
  readonly verifyOnChainState?: boolean
}

/** Arguments for {@link OmnibusClient.reclaim}. */
export interface ReclaimArgs {
  /** The hashlock identifying the swap. */
  readonly lock: Hex32
  /** The terms of the leg being reclaimed (must be local to this chain). */
  readonly party: Terms
  /** The other side's terms. */
  readonly counterparty: Terms
  /**
   * When `true` (default), preflight additionally verifies on-chain state in
   * one parallel read batch, mirroring the per-side `Omnibus.reclaim`:
   * `termsHash(swapId)` must equal the canonical digest and the party's side
   * must be `posted` (`TERMS_NOT_ON_CHAIN` otherwise); the party side must
   * not have already reclaimed; and the lock must permit this side's reclaim
   * — `Free`/`Committed` are the first reclaim, a `Spent` lock is allowed
   * ONLY mid-reclaim (the counterparty already reclaimed, this side has not),
   * while a claim-settled `Spent` and an `Unused` lock reject with
   * `INVALID_LOCK_STATE`. Reads `lockState`, `termsHash`, `posted`, and both
   * sides' `reclaimed` flags.
   */
  readonly verifyOnChainState?: boolean
}

/** Owner-only administrative operations (Ownable2Step). */
export interface OmnibusAdmin {
  /**
   * Sets the commitment fee. Owner only; reverts `FeeExceedsMax` above
   * `MAX_FEE`, `OwnableUnauthorizedAccount` for non-owners.
   *
   * @param newFee - The new fee in wei; must be `<= MAX_FEE`.
   * @param opts - Optional per-transaction gas/fee/nonce options.
   * @returns The transaction hash.
   * @throws QuipSwapError `MISSING_WALLET_CLIENT` | `CONTRACT_REVERT` |
   *   `GAS_ESTIMATION_FAILED` | `BALANCE_TOO_LOW`.
   * @see Omnibus.setCommitmentFee
   */
  setCommitmentFee(newFee: bigint, opts?: TxOptions): Promise<Hash>
  /**
   * Withdraws all accrued fees to `to`. Owner only. Escrowed swap native is
   * NOT withdrawable — only accrued fees. Reverts `ZeroFeeRecipient` for the
   * zero address, so a mistaken `to` cannot burn the accrued balance.
   *
   * @param to - The recipient of the accrued fees (non-zero).
   * @param opts - Optional per-transaction gas/fee/nonce options.
   * @returns The transaction hash.
   * @throws QuipSwapError `MISSING_WALLET_CLIENT` | `CONTRACT_REVERT` |
   *   `GAS_ESTIMATION_FAILED` | `BALANCE_TOO_LOW`.
   * @see Omnibus.withdrawFees
   */
  withdrawFees(to: Address, opts?: TxOptions): Promise<Hash>
  /**
   * Starts the two-step ownership transfer (Ownable2Step): the new owner
   * must later call {@link acceptOwnership}.
   *
   * @param newOwner - The proposed new owner.
   * @param opts - Optional per-transaction gas/fee/nonce options.
   * @returns The transaction hash.
   * @see Ownable2Step.transferOwnership
   */
  transferOwnership(newOwner: Address, opts?: TxOptions): Promise<Hash>
  /**
   * Completes a pending two-step ownership transfer; must be sent by the
   * pending owner.
   *
   * @param opts - Optional per-transaction gas/fee/nonce options.
   * @returns The transaction hash.
   * @see Ownable2Step.acceptOwnership
   */
  acceptOwnership(opts?: TxOptions): Promise<Hash>
  /**
   * Sets the activity status of an ERC-7913 verifier for the keyed commit
   * route. Owner only; reverts `ZeroVerifier` for the zero address.
   *
   * WARNING: this takes effect immediately, with no grace window. Deactivating a
   * verifier that has swaps in flight strands any keyed leg already escrowed under
   * it: the counterparty can no longer complete the keyed route, so the escrowed
   * leg is stuck (its commitmentFee forfeited) until that party reaches its own
   * reclaimRelease. Avoid deactivating a verifier with in-flight keyed swaps, or
   * warn affected users first. The wallet route never reads this and is unaffected.
   *
   * @param verifier - The verifier contract address (non-zero).
   * @param active - The new activity status.
   * @param opts - Optional per-transaction gas/fee/nonce options.
   * @returns The transaction hash.
   * @see Omnibus.setVerifierActivity
   */
  setVerifierActivity(verifier: Address, active: boolean, opts?: TxOptions): Promise<Hash>
}

/**
 * A typed client bound to one deployed Omnibus contract.
 *
 * Created by {@link createOmnibusClient}. Read methods mirror the
 * contract's getters one-to-one; write methods preflight, estimate gas
 * with a safety buffer, and submit. Write methods return the transaction
 * HASH only — pair them with {@link OmnibusClient.waitForReceipt} to
 * confirm success and decode events (it scopes decoding to this client's
 * Omnibus address automatically).
 */
export interface OmnibusClient {
  /** The Omnibus contract address this client is bound to. */
  readonly address: Address
  /** The underlying public client (exposed for receipt/event helpers). */
  readonly publicClient: PublicClient

  // ---- reads ----

  /** Reads the contract version. @see Omnibus.VERSION */
  getVersion(): Promise<bigint>
  /** Reads the maximum settable commitment fee in wei. @see Omnibus.MAX_FEE */
  getMaxFee(): Promise<bigint>
  /** Reads the current commitment fee in wei. @see Omnibus.commitmentFee */
  getCommitmentFee(): Promise<bigint>
  /** Reads the withdrawable accrued fees in wei. @see Omnibus.accruedFees */
  getAccruedFees(): Promise<bigint>
  /** Reads a swap's lifecycle state; key with {@link swapId}. @see Omnibus.lockState */
  getLockState(swapIdKey: Hex32): Promise<LockState>
  /** Reads the canonical terms digest recorded for a swap (zero if none); key with {@link swapId}. @see Omnibus.termsHash */
  getTermsHash(swapIdKey: Hex32): Promise<Hex32>
  /** Reads whether a side's terms digest was posted for a swap; key with {@link swapId}. @see Omnibus.posted */
  getPosted(swapIdKey: Hex32, termsDigest: Hex32): Promise<boolean>
  /** Reads whether a side has already reclaimed its own leg; key with {@link swapId} and that side's terms digest. @see Omnibus.reclaimed */
  getReclaimed(swapIdKey: Hex32, sideDigest: Hex32): Promise<boolean>
  /** Reads the current owner. @see Ownable.owner */
  getOwner(): Promise<Address>
  /** Reads the pending owner of an in-flight two-step transfer. @see Ownable2Step.pendingOwner */
  getPendingOwner(): Promise<Address>
  /**
   * Reads whether an ERC-7913 verifier is active on the contract — the
   * keyed route (`signer` blob longer than 20 bytes) reverts
   * `VerifierNotActive` unless its leading 20 bytes name an active verifier.
   *
   * @param verifier - The ERC-7913 verifier contract address.
   * @returns `true` iff the verifier is active.
   * @see Omnibus.verifierActive
   */
  isVerifierActive(verifier: Address): Promise<boolean>
  /**
   * Reads the quip WalletFactory the wallet commit route trusts (baked
   * immutably at construction).
   *
   * @returns The wallet factory address.
   * @see Omnibus.WALLET_FACTORY
   */
  getWalletFactory(): Promise<Address>
  /**
   * Reads whether `account` is a wallet deployed by the contract's
   * WalletFactory — the wallet commit route's membership check. An
   * empty-signature commit succeeds only when the SENDER passes this check
   * (`commitmentOf(account) != 0`; the contract reverts `NotQuipWallet`
   * otherwise).
   *
   * @param account - The address to test for factory membership.
   * @returns `true` iff `account` was deployed by the wallet factory.
   * @see IWalletFactory.commitmentOf
   */
  isQuipWallet(account: Address): Promise<boolean>
  /**
   * Reads the contract's commit digest for the given inputs — the on-chain
   * counterpart of {@link computeCommitDigest} (which computes the same
   * value locally without an RPC round-trip). Useful for digest-parity
   * assertions and debugging signature rejections.
   *
   * @param lock - The hashlock.
   * @param party - The committing side's terms.
   * @param counterparty - The other side's terms.
   * @param signerHash - `keccak256` of the committing side's identity blob.
   * @returns The 32-byte commit digest.
   * @see Omnibus.commitDigest
   */
  getCommitDigest(lock: Hex32, party: Terms, counterparty: Terms, signerHash: Hex32): Promise<Hex32>

  // ---- writes (preflight → estimate+buffer → write; hash returned, NOT finality) ----

  /**
   * Commits a side of a swap. PERMISSIONLESS and payable — the contract
   * authenticates the PAYLOAD (`args.auth`), not the caller.
   *
   * FUNDING MODEL: the SENDER (the wallet client's account, an EOA) funds the
   * party's leg + fee — assets are pulled from `msg.sender` and `msg.value`
   * must cover `totalNative(party) + commitmentFee`. Funding is independent
   * of authorization: the identity in `auth.signer` only endorses the
   * payload, it never pays. For a SMART ACCOUNT (e.g. a quip wallet) that
   * must itself be `msg.sender`, use {@link prepareCommit} and execute the
   * returned Call from the account.
   *
   * Preflight (in order, all before any transaction exists):
   * 1. Both terms structurally valid; 2. pairing strictly interleaves;
   * 3. `party.chainId` matches the connected chain (`counterparty.chainId`
   *    may differ — cross-chain); 4. `auth.signer` is a well-formed blob
   *    (more than 20 bytes — the contract reverts `MalformedSigner` at 20
   *    or fewer; signature VALIDITY is left to the contract's verifier call);
   *    5. the chain's current timestamp is inside the committing side's
   *    commit window — proposer `[0, party.commitmentDeadline)`,
   *    taker `[counterparty.commitmentDeadline, party.commitmentDeadline)`
   *    (the taker's window OPENS only when the proposer's deadline
   *    elapses); 6. unless `verifyOnChainState` is disabled, the lock's
   *    on-chain state permits this commit (see
   *    {@link CommitArgs.verifyOnChainState}); 7. the fee is re-read;
   *    8. `msg.value` is computed as exactly
   *    `totalNative(party) + commitmentFee` — the contract checks strict
   *    equality (`IncorrectNativeAmountReceived`), so over- and
   *    underpayment both revert; 9. the balance preflight runs (bare
   *    `msg.value` only — gas funding is not preflighted); 10. gas is
   *    estimated node-side (a would-be revert surfaces here, decoded) and
   *    buffered by the safety multiplier; 11. submit.
   *
   * Unused gas is refunded, so the default 1.2x buffer costs nothing at
   * execution; it exists to prevent out-of-gas failures from state drift
   * between estimation and inclusion — which matters here because writes
   * happen inside closing time windows.
   *
   * @remarks
   * ⚠️ ASSET-LOSS RISK (cross-chain takers). If you are the TAKER in a
   * cross-chain swap and you commit before the PROPOSER has actually
   * committed on their chain, the proposer — who holds the secret — can
   * claim your escrowed leg while never funding their own, and your assets
   * are gone. The contract enforces the same-chain *window* ordering (the
   * taker cannot commit until the proposer's commitment deadline has passed)
   * and the same-chain lock-state guards prevent a taker-first commit from
   * ever draining the taker — but it CANNOT protect you cross-chain (your
   * chain cannot read the proposer's chain), where a taker-first commit
   * against an uncommitted proposer loses your funds. Before a cross-chain
   * taker commit, verify the
   * proposer's commitment yourself with
   * {@link verifyRemoteCommitment} against the proposer's chain and apply
   * your own confirmation depth; only then call `commit`. See the
   * "Security & risks" section of USAGE.md.
   *
   * @param args - See {@link CommitArgs}.
   * @param opts - Optional per-transaction gas/fee/nonce options
   *   ({@link TxOptions}); `skipPreflightChecks` skips ONLY the balance
   *   check, never the protocol preflights.
   * @returns The transaction hash (not finality — wait for the receipt).
   * @throws QuipSwapError `MISSING_WALLET_CLIENT` | `MISSING_ACCOUNT` |
   *   structural codes from {@link validateTerms} | `DISORDERED_DEADLINES`
   *   | `CHAIN_ID_MISMATCH` | `ASSET_TYPE_MISMATCH` | `RECLAIM_RELEASE_TOO_DISTANT` |
   *   `MALFORMED_SIGNER` | `WINDOW_VIOLATED` |
   *   `INVALID_LOCK_STATE` | `TERMS_ALREADY_POSTED` | `TERMS_NOT_ON_CHAIN` |
   *   `GAS_ESTIMATION_FAILED` | `BALANCE_TOO_LOW` | `CONTRACT_REVERT`.
   * @see Omnibus.commit, Omnibus._enforceCommitAuthorized
   * @example
   * ```ts
   * // ERC-7913 keyed: the identity signed computeCommitDigest(...) off-band
   * const signer = buildKeyedSigner(verifierAddress, key)
   * const hash = await client.commit({lock, party, counterparty, auth: {signer, signature}})
   * const result = await client.waitForReceipt(hash) // address-scoped decoding
   * ```
   */
  commit(args: CommitArgs, opts?: TxOptions): Promise<Hash>

  /**
   * Plans a commit for `options.account` and returns the exact
   * {@link Call} that account must execute — WITHOUT sending anything.
   *
   * This is the smart-account entry point. A quip wallet is `msg.sender` to
   * the Omnibus, so its own ETH funds `value`, its own tokens are pulled, and
   * the wallet route's factory-membership check is evaluated against it. The
   * SDK cannot (and does not) submit for a smart account: hand the returned
   * `Call` to the wallet's tooling, which signs and calls `execute(to, value,
   * data, …)`. EOA callers should use {@link commit} instead.
   *
   * Runs every {@link commit} preflight, all against `options.account`:
   * balance (`getBalance(account) >= value`; skip with
   * `skipPreflightChecks`), wallet-route membership (`NOT_QUIP_WALLET` if
   * `auth.signature` is empty and the account is not a factory wallet), and a
   * node-side simulation `from: account` so a would-be revert surfaces here,
   * decoded. Gas is NOT part of the result: the estimate covers the inner
   * call only, and the outer transaction (or `execute`) is the executor's
   * concern.
   *
   * @remarks The `Call` is a snapshot. `value` embeds the fee read at planning
   * time and the contract checks it for EXACT equality; a fee change between
   * planning and execution reverts `IncorrectNativeAmountReceived`, so
   * execute promptly. A smart account must additionally hold whatever its own
   * `execute` charges (e.g. a factory execute fee) — the SDK does not know
   * about it.
   *
   * @param args - See {@link CommitArgs}.
   * @param options - See {@link PrepareCallOptions}; `account` is required.
   * @returns The `{to: omnibus, value, data}` to execute from `account`.
   * @throws Every {@link commit} preflight code except `MISSING_WALLET_CLIENT`
   *   / `MISSING_ACCOUNT` (no wallet client is needed to plan).
   * @example
   * ```ts
   * // quip wallet: plan against the WALLET address, execute via the wallet
   * const call = await client.prepareCommit({lock, party, counterparty, auth}, {account: wallet})
   * await walletTooling.execute(call.to, call.value, call.data)
   * ```
   */
  prepareCommit(args: CommitArgs, options: PrepareCallOptions): Promise<Call>

  /**
   * Claims a swap by revealing the secret. PERMISSIONLESS — the contract
   * allows anyone holding the secret to claim; the SDK adds no caller
   * restriction. The transaction makes the secret PUBLIC.
   *
   * Same-chain note: when `party.chainId == counterparty.chainId`, one
   * claim settles BOTH legs (counterparty's assets to `party.recipient`,
   * party's assets to `counterparty.recipient`).
   *
   * Preflight: secret is valid 32-byte hex; both terms valid and paired;
   * `counterparty.chainId` matches the connected chain (the CLAIMED leg is
   * local; `party.chainId` may be remote in a cross-chain claim); the
   * timestamp is inside the window the contract enforces for this pairing
   * (derived from the terms' roles and chains, not argument order); unless
   * disabled, the
   * lock is `Committed` and its `termsHash`/`posted` state matches (see
   * {@link ClaimArgs.verifyOnChainState}); then balance preflight,
   * estimate+buffer gas (the pre-submission revert check), submit.
   *
   * @param args - See {@link ClaimArgs}.
   * @param opts - Optional per-transaction gas/fee/nonce options.
   * @returns The transaction hash (not finality).
   * @throws QuipSwapError `INVALID_HEX32` | structural/pairing codes |
   *   `CHAIN_ID_MISMATCH` | `WINDOW_VIOLATED` | `INVALID_LOCK_STATE` |
   *   `TERMS_NOT_ON_CHAIN` | `MISSING_WALLET_CLIENT` |
   *   `GAS_ESTIMATION_FAILED` | `BALANCE_TOO_LOW` | `CONTRACT_REVERT`.
   * @see Omnibus.claim
   */
  claim(args: ClaimArgs, opts?: TxOptions): Promise<Hash>

  /**
   * Reclaims THIS party's own escrowed leg after its `reclaimRelease`.
   * PERMISSIONLESS — the assets always go to the terms' `reclaimRecipient`
   * regardless of caller, so the SDK adds no caller restriction.
   *
   * Per-side note: reclaim returns ONLY the party's own leg to
   * `party.reclaimRecipient` and emits exactly ONE `Reclaimed` event — each
   * side reclaims independently, in either order. For a same-chain swap that
   * means TWO reclaim transactions (each party pulls its own leg); a hostile
   * or blocklisted counterparty recipient therefore can never block this
   * party's recovery. Reclaim is valid from `Committed` or from `Free` (a
   * half-committed same-chain swap); once one side has reclaimed the lock is
   * `Spent`, yet the other side may still reclaim its leg.
   *
   * Shortfall note: fungible payouts are clamped on-chain to the balance the
   * contract actually holds, so reclaim cannot be permanently blocked by a
   * balance-mutable (rebasing/slashable) token shrinking the pooled escrow.
   * With well-behaved tokens the clamp never engages. See the token
   * compatibility warning in `Omnibus.commit` — such tokens are unsupported.
   *
   * Preflight: terms valid and paired; `party.chainId` matches the
   * connected chain; current timestamp `>= party.reclaimRelease`; unless
   * disabled, this party side has not already reclaimed, the lock permits
   * this side's reclaim, and its `termsHash`/`posted` state matches (see
   * {@link ReclaimArgs.verifyOnChainState}); then balance preflight,
   * estimate+buffer gas (the pre-submission revert check), submit.
   *
   * @param args - See {@link ReclaimArgs}.
   * @param opts - Optional per-transaction gas/fee/nonce options.
   * @returns The transaction hash (not finality).
   * @throws QuipSwapError structural/pairing codes | `CHAIN_ID_MISMATCH` |
   *   `WINDOW_VIOLATED` | `INVALID_LOCK_STATE` (also the already-reclaimed
   *   and claim-settled cases) | `TERMS_NOT_ON_CHAIN` |
   *   `MISSING_WALLET_CLIENT` | `GAS_ESTIMATION_FAILED` |
   *   `BALANCE_TOO_LOW` | `CONTRACT_REVERT`.
   * @see Omnibus.reclaim
   */
  reclaim(args: ReclaimArgs, opts?: TxOptions): Promise<Hash>

  /**
   * Waits for a write's receipt, verifies success, and decodes the Omnibus
   * events — scoped to THIS client's Omnibus address, so a same-signature
   * event from another contract in the same transaction is never decoded as
   * genuine. This is the preferred way to confirm a `commit`/`claim`/
   * `reclaim`; you do not pass the address again.
   *
   * @param hash - The transaction hash returned by a write method.
   * @param options - Confirmation count and timeout ({@link WaitOptions});
   *   `address` is always set to this client's Omnibus address, so you do
   *   not pass it.
   * @returns The typed {@link OmnibusReceipt} with address-scoped events.
   * @throws QuipSwapError `TRANSACTION_REVERTED` | `CONTRACT_REVERT`.
   * @see waitForOmnibusReceipt
   * @example
   * ```ts
   * const hash = await client.commit({lock, party, counterparty})
   * const {commitments} = await client.waitForReceipt(hash, {confirmations: 3})
   * ```
   */
  waitForReceipt(hash: Hash, options?: WaitOptions): Promise<OmnibusReceipt>

  /** Owner-only operations, namespaced to avoid mixing with user flows. */
  readonly admin: OmnibusAdmin
}

/** Convert SDK Terms (readonly) into the mutable tuple shape viem encodes. */
/** The ABI-typed argument tuple of `Omnibus.commit`. */
type CommitAbiArgs = readonly [Hex32, ReturnType<typeof toAbiTerms>, ReturnType<typeof toAbiTerms>, {signer: Hex; signature: Hex}]

function toAbiTerms(terms: Terms) {
  return {
    chainId: terms.chainId,
    reclaimRecipient: terms.reclaimRecipient,
    recipient: terms.recipient,
    commitmentDeadline: terms.commitmentDeadline,
    claimDeadline: terms.claimDeadline,
    reclaimRelease: terms.reclaimRelease,
    assets: terms.assets.map(a => ({assetType: a.assetType, target: a.target, id: a.id, amount: a.amount})),
  }
}

/** Human-readable name of a lock state for error messages. */
function lockStateName(state: LockState): string {
  return LockState[state] ?? `unknown(${state})`
}

/**
 * Creates a typed {@link OmnibusClient} bound to one deployed Omnibus.
 *
 * @param args - The contract address plus existing Viem clients; see
 *   {@link CreateOmnibusClientArgs}. No private keys, RPC URLs, or
 *   provider-specific objects are accepted — bring your own Viem clients.
 * @returns The client; see {@link OmnibusClient} for every method.
 * @example
 * ```ts
 * import {createPublicClient, createWalletClient, custom, http} from 'viem'
 *
 * const publicClient = createPublicClient({transport: http(rpcUrl)})
 * const walletClient = createWalletClient({transport: custom(window.ethereum)})
 * const client = createOmnibusClient({address: omnibusAddress, publicClient, walletClient})
 * const fee = await client.getCommitmentFee()
 * ```
 */
/** Minimal IWalletFactory surface for the wallet-route membership read. */
const walletFactoryAbi = [
  {
    type: 'function',
    name: 'commitmentOf',
    stateMutability: 'view',
    inputs: [{name: 'wallet', type: 'address'}],
    outputs: [{name: 'commitment', type: 'bytes32'}],
  },
] as const

/** Minimal ERC-165 surface for the ERC20-vs-ERC721 asset-type probe. */
const erc165Abi = [
  {
    type: 'function',
    name: 'supportsInterface',
    stateMutability: 'view',
    inputs: [{name: 'interfaceId', type: 'bytes4'}],
    outputs: [{name: '', type: 'bool'}],
  },
] as const

/** ERC-165 interface ids used by the asset-type probe (see {@link answersAsErc721}). */
const ERC165_INTERFACE_ID = '0x01ffc9a7' as const
const ERC165_INVALID_INTERFACE_ID = '0xffffffff' as const
const ERC721_INTERFACE_ID = '0x80ac58cd' as const

/**
 * Default maximum horizon (seconds) between a commit and either leg's `reclaimRelease` —
 * two weeks. An SDK-only *reasonableness* guard: the contract only rejects the malformed
 * `type(uint256).max` (see {@link validateTerms}), but a `reclaimRelease` far in the future is
 * a well-formed schedule that leaves an unrecoverable-until-then leg if the swap fails.
 * `commit` rejects a schedule beyond this horizon with `RECLAIM_RELEASE_TOO_DISTANT` unless the
 * caller passes {@link CommitArgs.allowDistantReclaimRelease}. There is no on-chain equivalent —
 * a determined caller can bypass it, exactly as with the buffer checks.
 */
export const MAX_RECLAIM_HORIZON_SECONDS = 14n * 24n * 60n * 60n

export function createOmnibusClient(args: CreateOmnibusClientArgs): OmnibusClient {
  const {address, publicClient, walletClient} = args
  const contract = {address, abi: omnibusAbi} as const

  /** Typed read with revert wrapping. */
  async function read<T>(functionName: string, fnArgs: readonly unknown[] = []): Promise<T> {
    try {
      return (await publicClient.readContract({
        ...contract,
        functionName,
        args: fnArgs as unknown[],
      } as Parameters<PublicClient['readContract']>[0])) as T
    } catch (error) {
      throw wrapContractError(error, `Reading ${functionName}`)
    }
  }

  /**
   * The wallet commit route's membership check: `commitmentOf(account) != 0` on
   * the contract's baked WalletFactory (write-once registry, non-zero iff
   * factory-deployed).
   */
  async function isQuipWallet(account: Address): Promise<boolean> {
    const factory = await read<Address>('WALLET_FACTORY')
    try {
      const commitment = await publicClient.readContract({
        address: factory,
        abi: walletFactoryAbi,
        functionName: 'commitmentOf',
        args: [account],
      })
      return BigInt(commitment) !== 0n
    } catch (error) {
      throw wrapContractError(error, 'Reading commitmentOf on the wallet factory')
    }
  }

  /** A single ERC-165 query, swallowing any revert / bad return as `false`. */
  async function safeSupportsInterface(target: Address, interfaceId: string): Promise<boolean> {
    try {
      return (await publicClient.readContract({
        address: target,
        abi: erc165Abi,
        functionName: 'supportsInterface',
        args: [interfaceId as `0x${string}`],
      })) as boolean
    } catch {
      return false
    }
  }

  /**
   * True iff `target` answers as an ERC-721 through ERC-165 — a faithful mirror
   * of OpenZeppelin `ERC165Checker.supportsInterface`, which the contract uses
   * to reject the ERC20-declared/ERC721-actual selector-collision trap at
   * deposit (TermsLib.AssetTypeMismatch). Replicating its exact logic — genuine
   * ERC-165 support (answers the 0x01ffc9a7 id, rejects the 0xffffffff id)
   * BEFORE querying the ERC-721 id — keeps the SDK verdict from ever diverging
   * from the contract's, so this preflight neither over- nor under-rejects.
   */
  async function answersAsErc721(target: Address): Promise<boolean> {
    const [supportsErc165, rejectsInvalid] = await Promise.all([
      safeSupportsInterface(target, ERC165_INTERFACE_ID),
      safeSupportsInterface(target, ERC165_INVALID_INTERFACE_ID),
    ])
    // no genuine ERC-165 (or a contract that claims every id) → not treated as ERC-721
    if (!supportsErc165 || rejectsInvalid) return false
    return safeSupportsInterface(target, ERC721_INTERFACE_ID)
  }

  /**
   * Reject any ERC20-declared asset in the LOCAL party leg whose target answers
   * as an ERC721 (mirrors the contract's deposit-path guard, which probes only
   * the local leg). The counterparty leg may be remote and unprobeable here; it
   * is validated at its own home-chain commit.
   */
  async function assertNoErc20Erc721Collision(party: Terms): Promise<void> {
    const targets = Array.from(
      new Set(party.assets.filter(a => a.assetType === AssetType.ERC20).map(a => a.target)),
    )
    if (targets.length === 0) return
    const verdicts = await Promise.all(targets.map(t => answersAsErc721(t)))
    const offender = targets.find((_t, i) => verdicts[i])
    if (offender !== undefined) {
      throw new QuipSwapError({
        code: 'ASSET_TYPE_MISMATCH',
        message:
          `Asset declared ERC20 at ${offender} answers as an ERC721 (ERC-165). ERC20 transferFrom/balanceOf ` +
          'share selectors with ERC721, so this deposit would reconcile but every payout via transfer() would ' +
          'revert forever — a freeze same-chain, a theft cross-chain. The contract rejects it at deposit ' +
          '(AssetTypeMismatch); fix the declared assetType or point at a real ERC20',
        details: {target: offender},
      })
    }
  }

  /** Resolves the wallet client + account or throws actionable errors. */
  function requireWallet(): {wallet: WalletClient; sender: Address} {
    if (walletClient === undefined) {
      throw new QuipSwapError({
        code: 'MISSING_WALLET_CLIENT',
        message: 'This operation submits a transaction; create the client with a walletClient to use it',
      })
    }
    const account = walletClient.account
    if (account === undefined) {
      throw new QuipSwapError({
        code: 'MISSING_ACCOUNT',
        message: 'The wallet client has no account; hoist an account onto the wallet client',
      })
    }
    return {wallet: walletClient, sender: account.address}
  }

  /** The chain's current block timestamp — windows are judged against this, not the local clock. */
  async function chainTimestamp(): Promise<bigint> {
    const block = await publicClient.getBlock()
    return block.timestamp
  }

  /**
   * One parallel batch of the three on-chain lock reads every
   * `verifyOnChainState` preflight uses — a single round of reads, no
   * sequential extra latency.
   */
  async function readLockBatch(
    swapIdKey: Hex32,
    postedDigest: Hex32,
  ): Promise<{state: LockState; onChainTermsHash: Hex32; isPosted: boolean}> {
    const [state, onChainTermsHash, isPosted] = await Promise.all([
      read<number>('lockState', [swapIdKey]),
      read<Hex32>('termsHash', [swapIdKey]),
      read<boolean>('posted', [swapIdKey, postedDigest]),
    ])
    return {state: state as LockState, onChainTermsHash, isPosted}
  }

  /** Throws TERMS_NOT_ON_CHAIN when the on-chain termsHash disagrees with the supplied pairing. */
  function checkTermsHash(lock: Hex32, onChainTermsHash: Hex32, party: Terms, counterparty: Terms): void {
    const expected = digestTermsCanonically(party, counterparty)
    if (onChainTermsHash.toLowerCase() !== expected.toLowerCase()) {
      throw new QuipSwapError({
        code: 'TERMS_NOT_ON_CHAIN',
        message:
          'The on-chain termsHash for this lock does not match the canonical digest of the supplied terms ' +
          '(contract would revert TermsMismatch)',
        details: {lock, onChainTermsHash, expected},
      })
    }
  }

  /** Throws TERMS_NOT_ON_CHAIN when the required side has not been posted for the lock. */
  function checkPosted(lock: Hex32, isPosted: boolean): void {
    if (!isPosted) {
      throw new QuipSwapError({
        code: 'TERMS_NOT_ON_CHAIN',
        message:
          "The required side's terms have not been posted for this lock (contract would revert TermsNotPosted)",
        details: {lock},
      })
    }
  }

  /**
   * Claim preflight against on-chain state: the lock must be `Committed`
   * (`Omnibus._enforceCommittedLock`), the termsHash must bind this exact
   * pairing, and the claimed (counterparty) side must be posted.
   *
   * Deliberately NOT checked: `posted(lock, digestTerms(party))`. The
   * contract's party-side `_enforcePosted` in `claim` runs only when
   * `party.chainId == block.chainid` — unreachable in a cross-chain claim
   * (the claimant's own leg is on the other chain by definition). For
   * same-chain swaps, `Committed` is reachable only via
   * Unused→Free→Committed where the second commit must match the same
   * canonical termsHash and post the not-yet-posted side, so Committed
   * (same-chain) provably implies BOTH sides are posted. With the
   * `Committed` check above in place, a party-side posted read can never
   * fire — zero information content, so it is skipped. (The counterparty
   * read below is, strictly, also implied; it is KEPT because it costs no
   * extra latency inside the Promise.all and, since the three reads are
   * not atomic, it localizes which value disagrees under an RPC race or a
   * violated invariant instead of leaving a confusing revert.)
   */
  async function verifyClaimState(lock: Hex32, party: Terms, counterparty: Terms): Promise<void> {
    const swapIdKey = swapId(lock, party, counterparty)
    const {state, onChainTermsHash, isPosted} = await readLockBatch(swapIdKey, digestTerms(counterparty))
    if (state !== LockState.Committed) {
      const cause =
        state === LockState.Unused
          ? 'nothing has been committed under this swap id on this chain — the swap was never committed here, the supplied secret is not the preimage for this swap (a wrong secret derives a different lock), or the supplied terms differ from the committed pairing (different terms derive a different swap id)'
          : state === LockState.Free
            ? 'the counterparty has not committed yet (same-chain swap is half-committed)'
            : 'the lock was already claimed or reclaimed'
      throw new QuipSwapError({
        code: 'INVALID_LOCK_STATE',
        message:
          `Cannot claim: lock state is ${lockStateName(state)} but claim requires Committed — ${cause} ` +
          '(contract would revert InvalidLockState)',
        details: {lock, lockState: state, required: 'Committed'},
      })
    }
    checkTermsHash(lock, onChainTermsHash, party, counterparty)
    checkPosted(lock, isPosted)
  }

  /**
   * Reclaim preflight against on-chain state, mirroring the per-side
   * `Omnibus.reclaim` (Finding 4): reclaim returns ONLY the party's own leg,
   * so the state check is per side, not per lock.
   *
   * The termsHash must bind this pairing and the party side must be posted.
   * Then, in the contract's order: the party side must not have already
   * reclaimed (`AlreadyReclaimed`); and the lock must permit this side's
   * reclaim — `Free`/`Committed` advance to `Spent` (`_advanceLockTo`),
   * while `Spent` is allowed ONLY mid-reclaim (the counterparty side already
   * reclaimed and this side has not), a claim-settled `Spent` is rejected
   * (`InvalidLockState`), and `Unused` is rejected (`InvalidLockAdvancement`).
   */
  async function verifyReclaimState(lock: Hex32, party: Terms, counterparty: Terms): Promise<void> {
    const swapIdKey = swapId(lock, party, counterparty)
    const partyDigest = digestTerms(party)
    const [state, onChainTermsHash, isPosted, partyReclaimed, counterpartyReclaimed] = await Promise.all([
      read<number>('lockState', [swapIdKey]),
      read<Hex32>('termsHash', [swapIdKey]),
      read<boolean>('posted', [swapIdKey, partyDigest]),
      read<boolean>('reclaimed', [swapIdKey, partyDigest]),
      read<boolean>('reclaimed', [swapIdKey, digestTerms(counterparty)]),
    ])
    checkTermsHash(lock, onChainTermsHash, party, counterparty)
    checkPosted(lock, isPosted)
    if (partyReclaimed) {
      throw new QuipSwapError({
        code: 'INVALID_LOCK_STATE',
        message:
          'Cannot reclaim: this party side has already reclaimed its leg ' +
          '(contract would revert AlreadyReclaimed)',
        details: {lock, side: partyDigest},
      })
    }
    if (state === LockState.Spent && !counterpartyReclaimed) {
      // Spent with no counterparty reclaim = the lock was claim-settled;
      // the party leg is gone and this reclaim would revert InvalidLockState.
      throw new QuipSwapError({
        code: 'INVALID_LOCK_STATE',
        message:
          'Cannot reclaim: the lock is Spent from a claim (not mid-reclaim) — this leg was already settled by ' +
          'claim (contract would revert InvalidLockState)',
        details: {lock, lockState: state},
      })
    }
    if (state === LockState.Unused) {
      throw new QuipSwapError({
        code: 'INVALID_LOCK_STATE',
        message:
          'Cannot reclaim: nothing has been committed under this swap id on this chain ' +
          '(contract would revert InvalidLockAdvancement)',
        details: {lock, lockState: state},
      })
    }
    // Free / Committed -> first reclaim; Spent && counterpartyReclaimed -> second side mid-reclaim: both allowed.
  }

  /**
   * Commit preflight against on-chain state: `Spent`/`Committed` can never
   * accept another commit; a `Free` lock (second same-chain commit) must
   * carry the same canonical termsHash and must NOT already have the
   * committing side posted — the second commit posts the OTHER side
   * (`Omnibus.commit`: `if (posted[lock][partyDigest]) revert
   * TermsAlreadyPosted()`); `Unused` needs nothing extra.
   */
  async function verifyCommitState(lock: Hex32, party: Terms, counterparty: Terms): Promise<void> {
    const swapIdKey = swapId(lock, party, counterparty)
    // all three reads go out in one parallel batch; the Free-only checks
    // simply ignore the extra values for other states
    const {state, onChainTermsHash, isPosted} = await readLockBatch(swapIdKey, digestTerms(party))
    if (state === LockState.Spent || state === LockState.Committed) {
      throw new QuipSwapError({
        code: 'INVALID_LOCK_STATE',
        message:
          `Cannot commit: lock state is ${lockStateName(state)} and no commit can advance from it ` +
          '(contract would revert InvalidLockAdvancement)',
        details: {lock, lockState: state, required: 'Unused or Free'},
      })
    }
    if (state === LockState.Free) {
      checkTermsHash(lock, onChainTermsHash, party, counterparty)
      if (isPosted) {
        throw new QuipSwapError({
          code: 'TERMS_ALREADY_POSTED',
          message:
            "This side's terms are already posted for the lock; the second same-chain commit must post the " +
            'OTHER side (contract would revert TermsAlreadyPosted)',
          details: {lock, partyDigest: digestTerms(party)},
        })
      }
    }
    // Unused: no extra requirement
  }

  /**
   * Shared write path: prepare (balance preflight on the bare call value,
   * then node-side gas estimation — a would-be revert surfaces here
   * decoded — with the safety multiplier applied) and submit with the
   * prepared gas/fees/nonce.
   */
  async function submitWrite(params: {
    wallet: WalletClient
    sender: Address
    functionName: string
    args: readonly unknown[]
    value?: bigint
    opts: TxOptions | undefined
    context: string
  }): Promise<Hash> {
    const prepared = await prepareTx({
      publicClient,
      contractParams: {
        address,
        abi: omnibusAbi,
        functionName: params.functionName,
        args: params.args,
        ...(params.value !== undefined ? {value: params.value} : {}),
        account: params.sender,
      },
      totalValue: params.value ?? 0n,
      ...(params.opts !== undefined ? {opts: params.opts} : {}),
    })
    try {
      return await params.wallet.writeContract({
        ...contract,
        functionName: params.functionName,
        args: params.args as unknown[],
        account: params.wallet.account ?? params.sender,
        chain: params.wallet.chain ?? publicClient.chain ?? null,
        ...(params.value !== undefined ? {value: params.value} : {}),
        gas: prepared.gas,
        ...prepared.fees,
        ...(prepared.nonce !== undefined ? {nonce: prepared.nonce} : {}),
        // dynamic functionName + optional payable value cannot satisfy viem's
        // conditional parameter types statically; the runtime shape is
        // exercised by the mocked-client and Anvil integration suites
      } as unknown as Parameters<WalletClient['writeContract']>[0])
    } catch (error) {
      // value-less calls (claim/reclaim/admin) carry no balance preflight,
      // so a gas-unfunded sender's failure surfaces at SEND time — map it
      // to BALANCE_TOO_LOW instead of mislabeling it CONTRACT_REVERT
      if (error instanceof BaseError && error.walk(e => e instanceof InsufficientFundsError) !== null) {
        throw new QuipSwapError({
          code: 'BALANCE_TOO_LOW',
          message: `Sender cannot cover gas for ${params.functionName}; fund the account and retry`,
          cause: error,
        })
      }
      throw wrapContractError(error, params.context)
    }
  }

  const admin: OmnibusAdmin = {
    async setCommitmentFee(newFee: bigint, opts?: TxOptions): Promise<Hash> {
      const {wallet, sender} = requireWallet()
      return submitWrite({wallet, sender, functionName: 'setCommitmentFee', args: [newFee], opts, context: 'setCommitmentFee'})
    },
    async withdrawFees(to: Address, opts?: TxOptions): Promise<Hash> {
      const {wallet, sender} = requireWallet()
      return submitWrite({wallet, sender, functionName: 'withdrawFees', args: [to], opts, context: 'withdrawFees'})
    },
    async transferOwnership(newOwner: Address, opts?: TxOptions): Promise<Hash> {
      const {wallet, sender} = requireWallet()
      return submitWrite({
        wallet,
        sender,
        functionName: 'transferOwnership',
        args: [newOwner],
        opts,
        context: 'transferOwnership',
      })
    },
    async acceptOwnership(opts?: TxOptions): Promise<Hash> {
      const {wallet, sender} = requireWallet()
      return submitWrite({wallet, sender, functionName: 'acceptOwnership', args: [], opts, context: 'acceptOwnership'})
    },
    async setVerifierActivity(verifier: Address, active: boolean, opts?: TxOptions): Promise<Hash> {
      const {wallet, sender} = requireWallet()
      return submitWrite({
        wallet,
        sender,
        functionName: 'setVerifierActivity',
        args: [verifier, active],
        opts,
        context: 'setVerifierActivity',
      })
    },
  }

  /**
   * The commit preflights (steps 1-8 of {@link OmnibusClient.commit}) for a
   * given acting account, shared by `commit` (account = the wallet client's
   * EOA) and `prepareCommit` (account = whatever will be `msg.sender`, e.g. a
   * quip wallet). Returns the ABI args and the exact `msg.value`.
   */
  async function planCommit(
    {lock, party, counterparty, auth, verifyOnChainState = true, allowDistantReclaimRelease = false}: CommitArgs,
    account: Address,
  ): Promise<{abiArgs: CommitAbiArgs; value: bigint}> {
    assertHex32(lock, 'lock')
    // 1-2. structural + pairing validation (mirrors the contract's order)
    validateTerms(party)
    validateTerms(counterparty)
    validateTermPairing(party, counterparty)

    // 3. only the LOCAL side's chainId must match; the counterparty may be remote
    const connectedChainId = BigInt(await publicClient.getChainId())
    if (party.chainId !== connectedChainId) {
      throw new QuipSwapError({
        code: 'CHAIN_ID_MISMATCH',
        message:
          `party.chainId (${party.chainId}) does not match the connected chain (${connectedChainId}); ` +
          "commit must be sent on the chain holding the party's assets (contract: ChainIdMismatch)",
        details: {partyChainId: party.chainId, connectedChainId},
      })
    }

    // 3b. asset-type probe — reject an ERC20-declared leg whose target is really an
    // ERC721 (selector-collision trap). Only the LOCAL party leg is probed, matching
    // the contract's deposit-path guard; the counterparty leg is validated on its own
    // chain. Runs before estimation so the failure is a clear ASSET_TYPE_MISMATCH
    // rather than a decoded AssetTypeMismatch revert.
    await assertNoErc20Erc721Collision(party)

    // 4. signer-blob shape preflight — the contract reverts MalformedSigner
    // at 20 bytes or fewer. Signature VALIDITY is left to the contract's
    // ERC-7913 verifier call: the
    // SDK cannot know the route's semantics off-chain, and gas estimation
    // surfaces a would-be InvalidCommitSignature as a decoded revert.
    // NOTE the funding model: `account` (not auth.signer) funds the leg + fee.
    assertSignerBlob(auth.signer)

    // 4b. wallet-route preflight — an EMPTY signature selects the wallet
    // route, where the contract requires the SENDER to be a factory-deployed
    // quip wallet. Membership is a plain read, so catch it before estimation
    if (size(auth.signature) === 0 && !(await isQuipWallet(account))) {
      throw new QuipSwapError({
        code: 'NOT_QUIP_WALLET',
        message:
          `An empty auth.signature selects the wallet commit route, but the account ${account} is not a wallet ` +
          'deployed by the WalletFactory (contract: NotQuipWallet). Provide a signature over the commit digest ' +
          'for the keyed route, or send from a quip wallet',
        details: {account},
      })
    }

    // 5. role-aware commit window; surfaces "taker too early" clearly
    const timestamp = await chainTimestamp()

    // 5b. reasonableness guard (SDK-only, no contract equivalent): a reclaimRelease far
    // beyond now leaves an unrecoverable-until-then leg if the swap fails. Check BOTH legs
    // (pure timestamp arithmetic, so the remote leg is fair game) so a distant value is
    // caught at the first commit. Opt out per-call with allowDistantReclaimRelease.
    if (!allowDistantReclaimRelease) {
      const horizon = timestamp + MAX_RECLAIM_HORIZON_SECONDS
      const distant = party.reclaimRelease > horizon ? party : counterparty.reclaimRelease > horizon ? counterparty : undefined
      if (distant !== undefined) {
        throw new QuipSwapError({
          code: 'RECLAIM_RELEASE_TOO_DISTANT',
          message:
            `reclaimRelease ${distant.reclaimRelease} is more than ${MAX_RECLAIM_HORIZON_SECONDS}s ` +
            `(~2 weeks) beyond the chain time ${timestamp}; a far-future reclaimRelease strands the leg ` +
            'until then if the swap fails. Pass allowDistantReclaimRelease: true to commit anyway',
          details: {reclaimRelease: distant.reclaimRelease, timestamp, horizon},
        })
      }
    }

    try {
      validateCommitWindow(party, counterparty, timestamp)
    } catch (error) {
      if (
        error instanceof QuipSwapError &&
        error.code === 'WINDOW_VIOLATED' &&
        proposedBy(party, counterparty) === 'counterparty' &&
        timestamp < counterparty.commitmentDeadline
      ) {
        throw new QuipSwapError({
          code: 'WINDOW_VIOLATED',
          message:
            `Taker commit window has not opened yet: it opens at the proposer's commitmentDeadline ` +
            `(${counterparty.commitmentDeadline}) and the chain time is ${timestamp}. Wait for the proposer's ` +
            'deadline to elapse before committing',
          details: {opensAt: counterparty.commitmentDeadline, timestamp},
          cause: error,
        })
      }
      throw error
    }

    // 6. lock-state preflight (Spent/Committed cannot accept a commit;
    // Free requires matching termsHash and an un-posted party side)
    if (verifyOnChainState) {
      await verifyCommitState(lock, party, counterparty)
    }

    // 7-8. SECURITY: re-read the fee immediately before estimating — the
    // owner can change it, and the contract checks msg.value for EXACT
    // equality (IncorrectNativeAmountReceived); a stale fee bricks the tx
    // in either direction (under- AND overpayment revert)
    const fee = await read<bigint>('commitmentFee')
    const value = totalNative(party) + fee

    const abiArgs: CommitAbiArgs = [
      lock,
      toAbiTerms(party),
      toAbiTerms(counterparty),
      {signer: auth.signer, signature: auth.signature},
    ]
    return {abiArgs, value}
  }

  return {
    address,
    publicClient,
    getVersion: () => read('VERSION'),
    getMaxFee: () => read('MAX_FEE'),
    getCommitmentFee: () => read('commitmentFee'),
    getAccruedFees: () => read('accruedFees'),
    getLockState: async (swapIdKey: Hex32) => {
      assertHex32(swapIdKey, 'swapId')
      const state = await read<number>('lockState', [swapIdKey])
      return state as LockState
    },
    getTermsHash: (swapIdKey: Hex32) => {
      assertHex32(swapIdKey, 'swapId')
      return read('termsHash', [swapIdKey])
    },
    getPosted: (swapIdKey: Hex32, termsDigest: Hex32) => {
      assertHex32(swapIdKey, 'swapId')
      assertHex32(termsDigest, 'termsDigest')
      return read('posted', [swapIdKey, termsDigest])
    },
    getReclaimed: (swapIdKey: Hex32, sideDigest: Hex32) => {
      assertHex32(swapIdKey, 'swapId')
      assertHex32(sideDigest, 'sideDigest')
      return read('reclaimed', [swapIdKey, sideDigest])
    },
    getOwner: () => read('owner'),
    getPendingOwner: () => read('pendingOwner'),
    isVerifierActive: (verifier: Address) => read('verifierActive', [verifier]),
    getWalletFactory: () => read('WALLET_FACTORY'),
    isQuipWallet,
    getCommitDigest: (lock: Hex32, party: Terms, counterparty: Terms, signerHash: Hex32) => {
      assertHex32(lock, 'lock')
      assertHex32(signerHash, 'signerHash')
      return read<Hex32>('commitDigest', [lock, toAbiTerms(party), toAbiTerms(counterparty), signerHash])
    },

    // confirm a write and decode events, always scoped to this client's
    // Omnibus address (the client knows the right address for its chain)
    waitForReceipt: (hash: Hash, options: WaitOptions = {}) =>
      waitForOmnibusReceipt(publicClient, hash, {...options, address}),

    // @audit-ok
    async commit(args: CommitArgs, opts?: TxOptions): Promise<Hash> {
      const {wallet, sender} = requireWallet()
      const {abiArgs, value} = await planCommit(args, sender)
      // 9-11. balance preflight + estimate (revert check) + buffer + submit
      return submitWrite({wallet, sender, functionName: 'commit', args: abiArgs, value, opts, context: 'commit'})
    },

    async prepareCommit(args: CommitArgs, options: PrepareCallOptions): Promise<Call> {
      const {account} = options
      const {abiArgs, value} = await planCommit(args, account)
      // 9-10. balance preflight + simulation FROM THE ACCOUNT — the same two
      // gates commit runs before sending; the gas figure is discarded (it is
      // the inner call's, not the executor's)
      await prepareTx({
        publicClient,
        contractParams: {address, abi: omnibusAbi, functionName: 'commit', args: abiArgs, value, account},
        totalValue: value,
        ...(options.skipPreflightChecks === true ? {opts: {skipPreflightChecks: true}} : {}),
      })
      return {to: address, value, data: encodeFunctionData({abi: omnibusAbi, functionName: 'commit', args: abiArgs})}
    },


    async claim(
      {secret, party, counterparty, verifyOnChainState = true}: ClaimArgs,
      opts?: TxOptions,
    ): Promise<Hash> {
      // 1-2. validate the secret and derive the lock from it
      assertHex32(secret, 'secret')
      const lock = generateLock(secret)
      const {wallet, sender} = requireWallet()

      // 3. structural + pairing validation
      validateTerms(party)
      validateTerms(counterparty)
      validateTermPairing(party, counterparty)

      // 4. the CLAIMED leg (counterparty) must be local; party may be remote
      const connectedChainId = BigInt(await publicClient.getChainId())
      if (counterparty.chainId !== connectedChainId) {
        throw new QuipSwapError({
          code: 'CHAIN_ID_MISMATCH',
          message:
            `counterparty.chainId (${counterparty.chainId}) does not match the connected chain ` +
            `(${connectedChainId}); claim must be sent on the chain holding the counterparty's assets ` +
            '(contract: ChainIdMismatch)',
          details: {counterpartyChainId: counterparty.chainId, connectedChainId},
        })
      }

      // 5. role-aware claim window
      const timestamp = await chainTimestamp()
      validateClaimWindow(party, counterparty, timestamp)

      // 6. optional on-chain state verification (lockState + termsHash + posted)
      if (verifyOnChainState) {
        await verifyClaimState(lock, party, counterparty)
      }

      // 7-9. balance preflight + estimate (revert check) + buffer + submit.
      // NOTE: claim is permissionless — any sender with the secret may
      // claim; no caller check is added here
      return submitWrite({
        wallet,
        sender,
        functionName: 'claim',
        args: [secret, toAbiTerms(party), toAbiTerms(counterparty)],
        opts,
        context: 'claim',
      })
    },

    async reclaim(
      {lock, party, counterparty, verifyOnChainState = true}: ReclaimArgs,
      opts?: TxOptions,
    ): Promise<Hash> {
      assertHex32(lock, 'lock')
      const {wallet, sender} = requireWallet()

      // 1. structural + pairing validation
      validateTerms(party)
      validateTerms(counterparty)
      validateTermPairing(party, counterparty)

      // 2. the reclaimed leg must be local
      const connectedChainId = BigInt(await publicClient.getChainId())
      if (party.chainId !== connectedChainId) {
        throw new QuipSwapError({
          code: 'CHAIN_ID_MISMATCH',
          message:
            `party.chainId (${party.chainId}) does not match the connected chain (${connectedChainId}); ` +
            "reclaim must be sent on the chain holding the party's assets (contract: ChainIdMismatch)",
          details: {partyChainId: party.chainId, connectedChainId},
        })
      }

      // 3. reclaim window: [party.reclaimRelease, +inf). NOTE: reclaim is
      // permissionless and pays reclaimRecipient regardless of caller
      const timestamp = await chainTimestamp()
      validateReclaimWindow(party, timestamp)

      // 4. optional on-chain state verification (lockState + termsHash + posted)
      if (verifyOnChainState) {
        await verifyReclaimState(lock, party, counterparty)
      }

      // 5-7. balance preflight + estimate (revert check) + buffer + submit
      return submitWrite({
        wallet,
        sender,
        functionName: 'reclaim',
        args: [lock, toAbiTerms(party), toAbiTerms(counterparty)],
        opts,
        context: 'reclaim',
      })
    },

    admin,
  }
}
