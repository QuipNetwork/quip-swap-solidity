/**
 * The Omnibus SDK client: typed reads, preflighted writes, and admin
 * operations against one deployed Omnibus contract.
 *
 * Design rules:
 * - Accepts EXISTING Viem clients — browser wallets, local private-key
 *   accounts, backends, hardware-wallet transports, and (in production)
 *   clients whose sender is a QuipWallet contract. The SDK never takes
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
import {BaseError, InsufficientFundsError} from 'viem'
import type {Address, Hash, PublicClient, WalletClient} from 'viem'
import {totalNative} from './assets.js'
import {QuipSwapError, wrapContractError} from './errors.js'
import {prepareTx} from './gas.js'
import type {TxOptions} from './gas.js'
import {omnibusAbi} from './generated/omnibusAbi.js'
import {assertHex32, digestTerms, digestTermsCanonically, generateLock} from './hashing.js'
import {proposedBy, validateTermPairing, validateTerms} from './terms.js'
import {LockState} from './types.js'
import type {Hex32, Terms} from './types.js'
import {validateClaimWindow, validateCommitWindow, validateReclaimWindow} from './windows.js'

/**
 * Minimal `IQuipFactory` surface consumed by the SDK — exactly what the
 * Omnibus `onlyQuipWallet` modifier reads.
 *
 * @see IQuipFactory.vaultIdOf
 */
export const quipFactoryAbi = [
  {
    type: 'function',
    name: 'vaultIdOf',
    stateMutability: 'view',
    inputs: [{name: 'wallet', type: 'address'}],
    outputs: [{name: 'vaultId', type: 'bytes32'}],
  },
] as const

/** Arguments for {@link createOmnibusClient}. */
export interface CreateOmnibusClientArgs {
  /** The deployed Omnibus contract address (see {@link resolveDeployment}). */
  readonly address: Address
  /** A Viem public client connected to the chain the contract lives on. */
  readonly publicClient: PublicClient
  /**
   * A Viem wallet client for writes. Optional: a read-only client works
   * without one, and writes then fail with `MISSING_WALLET_CLIENT`. In
   * production the COMMIT sender must be a QuipWallet contract; claim and
   * reclaim may be sent by any account.
   */
  readonly walletClient?: WalletClient
}

/** Arguments for {@link OmnibusClient.commit}. */
export interface CommitArgs {
  /** The hashlock (`generateLock(secret)`); the proposer generates the secret. */
  readonly lock: Hex32
  /** The committing side's terms — the sender acts for this side. */
  readonly party: Terms
  /** The other side's terms. */
  readonly counterparty: Terms
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
   * in one parallel read batch: `lockState(lock)` must be `Committed`
   * (`INVALID_LOCK_STATE` otherwise, with the actual state and likely
   * cause), `termsHash(lock)` must equal the canonical digest, and the
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
   * When `true` (default), preflight additionally verifies on-chain state
   * in one parallel read batch: `lockState(lock)` must be `Free` or
   * `Committed` (`INVALID_LOCK_STATE` otherwise — `Unused` was never
   * committed, `Spent` was already settled), `termsHash(lock)` must equal
   * the canonical digest, and the party's side must be `posted`
   * (`TERMS_NOT_ON_CHAIN` otherwise).
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
   * NOT withdrawable — only accrued fees.
   *
   * @param to - The recipient of the accrued fees.
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
}

/**
 * A typed client bound to one deployed Omnibus contract.
 *
 * Created by {@link createOmnibusClient}. Read methods mirror the
 * contract's getters one-to-one; write methods preflight, estimate gas
 * with a safety buffer, and submit. Write methods return the transaction
 * HASH only — pair them with {@link waitForOmnibusReceipt} to confirm
 * success and decode events.
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
  /** Reads the QuipFactory address whose registry gates commit. @see Omnibus.QUIP_FACTORY */
  getQuipFactory(): Promise<Address>
  /** Reads the current commitment fee in wei. @see Omnibus.commitmentFee */
  getCommitmentFee(): Promise<bigint>
  /** Reads the withdrawable accrued fees in wei. @see Omnibus.accruedFees */
  getAccruedFees(): Promise<bigint>
  /** Reads a lock's lifecycle state. @see Omnibus.lockState */
  getLockState(lock: Hex32): Promise<LockState>
  /** Reads the canonical terms digest bound to a lock (zero if none). @see Omnibus.termsHash */
  getTermsHash(lock: Hex32): Promise<Hex32>
  /** Reads whether a side's terms digest was posted for a lock. @see Omnibus.posted */
  getPosted(lock: Hex32, termsDigest: Hex32): Promise<boolean>
  /** Reads the current owner. @see Ownable.owner */
  getOwner(): Promise<Address>
  /** Reads the pending owner of an in-flight two-step transfer. @see Ownable2Step.pendingOwner */
  getPendingOwner(): Promise<Address>
  /**
   * Checks whether `account` passes the `onlyQuipWallet` gate: reads
   * `vaultIdOf(account)` on the contract's `QUIP_FACTORY` and reports
   * whether it is non-zero. Only factory-deployed QuipWallets can commit;
   * `commit` runs this as a preflight and rejects with `NOT_QUIP_WALLET`.
   *
   * @param account - The would-be commit sender (the QuipWallet contract
   *   address, NOT its owner's EOA).
   * @returns `true` iff `vaultIdOf(account)` is non-zero (the account can commit).
   * @see Omnibus.commit (onlyQuipWallet), IQuipFactory.vaultIdOf
   */
  isQuipWallet(account: Address): Promise<boolean>

  // ---- writes (preflight → estimate+buffer → write; hash returned, NOT finality) ----

  /**
   * Commits the sender's side of a swap. QuipWallet-gated and payable.
   *
   * The contract gates commit with `onlyQuipWallet`
   * (`QUIP_FACTORY.vaultIdOf(msg.sender) != 0`), so the SDK preflights the
   * gate via {@link OmnibusClient.isQuipWallet} and rejects a non-wallet
   * sender with `NOT_QUIP_WALLET` BEFORE any estimation round-trip — this is
   * the most likely integration failure. The committer must be the QuipWallet
   * CONTRACT address, never its owner's EOA.
   *
   * Preflight (in order, all before any transaction exists):
   * 1. Both terms structurally valid; 2. pairing strictly interleaves;
   * 3. `party.chainId` matches the connected chain (`counterparty.chainId`
   *    may differ — cross-chain); 4. the sender passes the QuipWallet gate
   *    (`vaultIdOf != 0`); 5. the chain's current timestamp is inside the
   *    sender's commit window — proposer `[0, party.commitmentDeadline)`,
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
   *   | `CHAIN_ID_MISMATCH` | `NOT_QUIP_WALLET` | `WINDOW_VIOLATED` |
   *   `INVALID_LOCK_STATE` | `TERMS_ALREADY_POSTED` | `TERMS_NOT_ON_CHAIN` |
   *   `GAS_ESTIMATION_FAILED` | `BALANCE_TOO_LOW` | `CONTRACT_REVERT`.
   * @see Omnibus.commit (onlyQuipWallet)
   * @example
   * ```ts
   * const hash = await client.commit({lock, party: myTerms, counterparty: theirTerms})
   * const result = await waitForOmnibusReceipt(client.publicClient, hash)
   * ```
   */
  commit(args: CommitArgs, opts?: TxOptions): Promise<Hash>

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
   * timestamp is inside the claimant role's window; unless disabled, the
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
   * Reclaims escrowed assets after the local leg's `reclaimRelease`.
   * PERMISSIONLESS — assets always go to the terms' `reclaimRecipient`
   * regardless of caller, so the SDK adds no caller restriction.
   *
   * Dual-leg note: when the counterparty leg is also local and the lock is
   * `Committed`, one reclaim returns BOTH legs to their respective
   * `reclaimRecipient` addresses and emits two `Reclaimed` events. Reclaim
   * is also valid from `Free` (a half-committed same-chain swap).
   *
   * Preflight: terms valid and paired; `party.chainId` matches the
   * connected chain; current timestamp `>= party.reclaimRelease`; unless
   * disabled, the lock is `Free` or `Committed` and its
   * `termsHash`/`posted` state matches (see
   * {@link ReclaimArgs.verifyOnChainState}); then balance preflight,
   * estimate+buffer gas (the pre-submission revert check), submit.
   *
   * @param args - See {@link ReclaimArgs}.
   * @param opts - Optional per-transaction gas/fee/nonce options.
   * @returns The transaction hash (not finality).
   * @throws QuipSwapError structural/pairing codes | `CHAIN_ID_MISMATCH` |
   *   `WINDOW_VIOLATED` | `INVALID_LOCK_STATE` | `TERMS_NOT_ON_CHAIN` |
   *   `MISSING_WALLET_CLIENT` | `GAS_ESTIMATION_FAILED` |
   *   `BALANCE_TOO_LOW` | `CONTRACT_REVERT`.
   * @see Omnibus.reclaim
   */
  reclaim(args: ReclaimArgs, opts?: TxOptions): Promise<Hash>

  /** Owner-only operations, namespaced to avoid mixing with user flows. */
  readonly admin: OmnibusAdmin
}

/** Convert SDK Terms (readonly) into the mutable tuple shape viem encodes. */
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
export function createOmnibusClient(args: CreateOmnibusClientArgs): OmnibusClient {
  const {address, publicClient, walletClient} = args
  const contract = {address, abi: omnibusAbi} as const

  /** Cached QUIP_FACTORY address — immutable on-chain, safe to cache per client. */
  let quipFactoryAddress: Address | undefined

  async function getQuipFactory(): Promise<Address> {
    if (quipFactoryAddress === undefined) {
      const factory = await read<Address>('QUIP_FACTORY')
      quipFactoryAddress = factory
      return factory
    }
    return quipFactoryAddress
  }

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

  // The onlyQuipWallet gate: QUIP_FACTORY.vaultIdOf(account) != bytes32(0).
  // commit() preflights this so a non-wallet sender fails as NOT_QUIP_WALLET.
  async function isQuipWallet(account: Address): Promise<boolean> {
    const factory = await getQuipFactory()
    try {
      const vaultId = await publicClient.readContract({
        address: factory,
        abi: quipFactoryAbi,
        functionName: 'vaultIdOf',
        args: [account],
      })
      return BigInt(vaultId) !== 0n
    } catch (error) {
      throw wrapContractError(error, 'Reading vaultIdOf from QUIP_FACTORY')
    }
  }

  /**
   * One parallel batch of the three on-chain lock reads every
   * `verifyOnChainState` preflight uses — a single round of reads, no
   * sequential extra latency.
   */
  async function readLockBatch(
    lock: Hex32,
    postedDigest: Hex32,
  ): Promise<{state: LockState; onChainTermsHash: Hex32; isPosted: boolean}> {
    const [state, onChainTermsHash, isPosted] = await Promise.all([
      read<number>('lockState', [lock]),
      read<Hex32>('termsHash', [lock]),
      read<boolean>('posted', [lock, postedDigest]),
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
    const {state, onChainTermsHash, isPosted} = await readLockBatch(lock, digestTerms(counterparty))
    if (state !== LockState.Committed) {
      const cause =
        state === LockState.Unused
          ? 'nothing has been committed under this lock on this chain — either the swap was never committed here, or the supplied secret is not the preimage for this swap (a wrong secret derives a different lock)'
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
   * Reclaim preflight against on-chain state: `_advanceLockTo` permits
   * only Free→Spent and Committed→Spent, so the lock must be `Free` or
   * `Committed`; the termsHash must bind this pairing; and the reclaimed
   * (party) side must be posted.
   */
  async function verifyReclaimState(lock: Hex32, party: Terms, counterparty: Terms): Promise<void> {
    const {state, onChainTermsHash, isPosted} = await readLockBatch(lock, digestTerms(party))
    if (state !== LockState.Free && state !== LockState.Committed) {
      const cause =
        state === LockState.Unused
          ? 'nothing has been committed under this lock on this chain'
          : 'the lock was already claimed or reclaimed'
      throw new QuipSwapError({
        code: 'INVALID_LOCK_STATE',
        message:
          `Cannot reclaim: lock state is ${lockStateName(state)} but reclaim requires Free or Committed — ` +
          `${cause} (contract would revert InvalidLockAdvancement)`,
        details: {lock, lockState: state, required: 'Free or Committed'},
      })
    }
    checkTermsHash(lock, onChainTermsHash, party, counterparty)
    checkPosted(lock, isPosted)
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
    // all three reads go out in one parallel batch; the Free-only checks
    // simply ignore the extra values for other states
    const {state, onChainTermsHash, isPosted} = await readLockBatch(lock, digestTerms(party))
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
  }

  return {
    address,
    publicClient,
    getVersion: () => read('VERSION'),
    getMaxFee: () => read('MAX_FEE'),
    getQuipFactory,
    getCommitmentFee: () => read('commitmentFee'),
    getAccruedFees: () => read('accruedFees'),
    getLockState: async (lock: Hex32) => {
      assertHex32(lock, 'lock')
      const state = await read<number>('lockState', [lock])
      return state as LockState
    },
    getTermsHash: (lock: Hex32) => {
      assertHex32(lock, 'lock')
      return read('termsHash', [lock])
    },
    getPosted: (lock: Hex32, termsDigest: Hex32) => {
      assertHex32(lock, 'lock')
      assertHex32(termsDigest, 'termsDigest')
      return read('posted', [lock, termsDigest])
    },
    getOwner: () => read('owner'),
    getPendingOwner: () => read('pendingOwner'),

    isQuipWallet,

    async commit({lock, party, counterparty, verifyOnChainState = true}: CommitArgs, opts?: TxOptions): Promise<Hash> {
      assertHex32(lock, 'lock')
      const {wallet, sender} = requireWallet()

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

      // 4. QuipWallet gate — only factory-deployed QuipWallets can commit
      // (Omnibus.commit is onlyQuipWallet). Preflight it here, before the
      // estimation round-trip, since a non-wallet sender is the most likely
      // integration failure; surfaces as NOT_QUIP_WALLET with a clear cause.
      if (!(await isQuipWallet(sender))) {
        throw new QuipSwapError({
          code: 'NOT_QUIP_WALLET',
          message:
            `Sender ${sender} is not a factory-deployed QuipWallet (QUIP_FACTORY.vaultIdOf is zero); ` +
            'only QuipWallet contracts can commit (contract: CallerNotQuipWallet). The committer must be the ' +
            "QuipWallet CONTRACT address — never substitute the wallet owner's EOA",
          details: {sender},
        })
      }

      // 5. role-aware commit window; surfaces "taker too early" clearly
      const timestamp = await chainTimestamp()
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

      // 9-11. balance preflight + estimate (revert check) + buffer + submit
      return submitWrite({
        wallet,
        sender,
        functionName: 'commit',
        args: [lock, toAbiTerms(party), toAbiTerms(counterparty)],
        value,
        opts,
        context: 'commit',
      })
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
