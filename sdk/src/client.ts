/**
 * The Omnibus SDK client: typed reads, preflighted writes, and admin
 * operations against one deployed Omnibus contract.
 *
 * Design rules:
 * - Accepts EXISTING Viem clients — browser wallets, local private-key
 *   accounts, backends, hardware-wallet transports, and (in production)
 *   clients whose sender is a QuipWallet contract. The SDK never takes
 *   custody of private keys, raw RPC URLs, or a specific wallet impl.
 * - Every write simulates first (`simulateContract` → `writeContract`);
 *   nothing is sent blind.
 * - Every write preflights the same conditions the contract enforces, so
 *   integration failures surface as actionable errors BEFORE a transaction
 *   exists. Preflight mirrors but never replaces on-chain enforcement.
 * - User operations (`commit`/`claim`/`reclaim`) and owner administration
 *   (`admin.*`) are exposed on separate namespaces so they cannot be
 *   confused.
 */
import type {Address, Hash, PublicClient, WalletClient} from 'viem'
import {totalNative} from './assets.js'
import {QuipSdkError, wrapContractError} from './errors.js'
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
   * When `true` (default), preflight additionally verifies on-chain state:
   * `termsHash(lock)` equals the canonical digest and the counterparty's
   * side is `posted`. Costs two extra reads; disable only if you have just
   * verified the state yourself.
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
  /** As in {@link ClaimArgs.verifyOnChainState}; default `true`. */
  readonly verifyOnChainState?: boolean
}

/** Owner-only administrative operations (Ownable2Step). */
export interface OmnibusAdmin {
  /**
   * Sets the commitment fee. Owner only; reverts `FeeExceedsMax` above
   * `MAX_FEE`, `OwnableUnauthorizedAccount` for non-owners.
   *
   * @param newFee - The new fee in wei; must be `<= MAX_FEE`.
   * @returns The transaction hash.
   * @throws QuipSdkError `MISSING_WALLET_CLIENT` | `CONTRACT_REVERT`.
   * @see Omnibus.setCommitmentFee
   */
  setCommitmentFee(newFee: bigint): Promise<Hash>
  /**
   * Withdraws all accrued fees to `to`. Owner only. Escrowed swap native is
   * NOT withdrawable — only accrued fees.
   *
   * @param to - The recipient of the accrued fees.
   * @returns The transaction hash.
   * @throws QuipSdkError `MISSING_WALLET_CLIENT` | `CONTRACT_REVERT`.
   * @see Omnibus.withdrawFees
   */
  withdrawFees(to: Address): Promise<Hash>
  /**
   * Starts the two-step ownership transfer (Ownable2Step): the new owner
   * must later call {@link acceptOwnership}.
   *
   * @param newOwner - The proposed new owner.
   * @returns The transaction hash.
   * @see Ownable2Step.transferOwnership
   */
  transferOwnership(newOwner: Address): Promise<Hash>
  /**
   * Completes a pending two-step ownership transfer; must be sent by the
   * pending owner.
   *
   * @returns The transaction hash.
   * @see Ownable2Step.acceptOwnership
   */
  acceptOwnership(): Promise<Hash>
}

/**
 * A typed client bound to one deployed Omnibus contract.
 *
 * Created by {@link createOmnibusClient}. Read methods mirror the
 * contract's getters one-to-one; write methods preflight, simulate, and
 * submit. Write methods return the transaction HASH only — pair them with
 * {@link waitForOmnibusReceipt} to confirm success and decode events.
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
   * whether it is non-zero. Only factory-deployed QuipWallets can commit.
   *
   * @param account - The would-be commit sender (the QuipWallet contract
   *   address, NOT its owner's EOA).
   * @returns `true` iff the account can commit.
   * @see Omnibus.commit (onlyQuipWallet), IQuipFactory.vaultIdOf
   */
  isQuipWallet(account: Address): Promise<boolean>

  // ---- writes (simulate → write; hash returned, NOT finality) ----

  /**
   * Commits the sender's side of a swap. QuipWallet-gated and payable.
   *
   * Preflight (in order, all before any transaction exists):
   * 1. Both terms structurally valid; 2. pairing strictly interleaves;
   * 3. `party.chainId` matches the connected chain (`counterparty.chainId`
   *    may differ — cross-chain); 4. the sender passes the QuipWallet gate
   *    (`vaultIdOf != 0`); 5. the chain's current timestamp is inside the
   *    sender's commit window — proposer `[0, party.commitmentDeadline)`,
   *    taker `[counterparty.commitmentDeadline, party.commitmentDeadline)`
   *    (the taker's window OPENS only when the proposer's deadline
   *    elapses); 6. the fee is re-read; 7. `msg.value` is computed as
   *    exactly `totalNative(party) + commitmentFee` — the contract checks
   *    strict equality (`IncorrectNativeAmountReceived`), so over- and
   *    underpayment both revert; 8. simulate; 9. submit the simulated
   *    request.
   *
   * @param args - See {@link CommitArgs}.
   * @returns The transaction hash (not finality — wait for the receipt).
   * @throws QuipSdkError `MISSING_WALLET_CLIENT` | `MISSING_ACCOUNT` |
   *   structural codes from {@link validateTerms} | `DISORDERED_DEADLINES`
   *   | `CHAIN_ID_MISMATCH` | `NOT_QUIP_WALLET` | `WINDOW_VIOLATED` |
   *   `CONTRACT_REVERT`.
   * @see Omnibus.commit (onlyQuipWallet)
   * @example
   * ```ts
   * const hash = await client.commit({lock, party: myTerms, counterparty: theirTerms})
   * const result = await waitForOmnibusReceipt(client.publicClient, hash)
   * ```
   */
  commit(args: CommitArgs): Promise<Hash>

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
   * timestamp is inside the claimant role's window; optionally the lock's
   * on-chain `termsHash`/`posted` state is verified; then simulate/submit.
   *
   * @param args - See {@link ClaimArgs}.
   * @returns The transaction hash (not finality).
   * @throws QuipSdkError `INVALID_HEX32` | structural/pairing codes |
   *   `CHAIN_ID_MISMATCH` | `WINDOW_VIOLATED` | `TERMS_NOT_ON_CHAIN` |
   *   `MISSING_WALLET_CLIENT` | `CONTRACT_REVERT`.
   * @see Omnibus.claim
   */
  claim(args: ClaimArgs): Promise<Hash>

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
   * connected chain; current timestamp `>= party.reclaimRelease`;
   * optionally on-chain `termsHash`/`posted` verified; simulate/submit.
   *
   * @param args - See {@link ReclaimArgs}.
   * @returns The transaction hash (not finality).
   * @throws QuipSdkError structural/pairing codes | `CHAIN_ID_MISMATCH` |
   *   `WINDOW_VIOLATED` | `TERMS_NOT_ON_CHAIN` | `MISSING_WALLET_CLIENT` |
   *   `CONTRACT_REVERT`.
   * @see Omnibus.reclaim
   */
  reclaim(args: ReclaimArgs): Promise<Hash>

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
      throw new QuipSdkError({
        code: 'MISSING_WALLET_CLIENT',
        message: 'This operation submits a transaction; create the client with a walletClient to use it',
      })
    }
    const account = walletClient.account
    if (account === undefined) {
      throw new QuipSdkError({
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

  /** The onlyQuipWallet gate: QUIP_FACTORY.vaultIdOf(account) != bytes32(0). */
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

  /** Preflight check that the lock's on-chain termsHash/posted state matches the supplied terms. */
  async function verifyPostedState(lock: Hex32, party: Terms, counterparty: Terms, postedSide: Terms): Promise<void> {
    const [onChainTermsHash, isPosted] = await Promise.all([
      read<Hex32>('termsHash', [lock]),
      read<boolean>('posted', [lock, digestTerms(postedSide)]),
    ])
    const expected = digestTermsCanonically(party, counterparty)
    if (onChainTermsHash.toLowerCase() !== expected.toLowerCase()) {
      throw new QuipSdkError({
        code: 'TERMS_NOT_ON_CHAIN',
        message:
          'The on-chain termsHash for this lock does not match the canonical digest of the supplied terms ' +
          '(contract would revert TermsMismatch)',
        details: {lock, onChainTermsHash, expected},
      })
    }
    if (!isPosted) {
      throw new QuipSdkError({
        code: 'TERMS_NOT_ON_CHAIN',
        message:
          "The required side's terms have not been posted for this lock (contract would revert TermsNotPosted)",
        details: {lock},
      })
    }
  }

  const admin: OmnibusAdmin = {
    async setCommitmentFee(newFee: bigint): Promise<Hash> {
      const {wallet, sender} = requireWallet()
      try {
        const {request} = await publicClient.simulateContract({
          ...contract,
          functionName: 'setCommitmentFee',
          args: [newFee],
          account: sender,
        })
        return await wallet.writeContract(request)
      } catch (error) {
        throw wrapContractError(error, 'setCommitmentFee')
      }
    },
    async withdrawFees(to: Address): Promise<Hash> {
      const {wallet, sender} = requireWallet()
      try {
        const {request} = await publicClient.simulateContract({
          ...contract,
          functionName: 'withdrawFees',
          args: [to],
          account: sender,
        })
        return await wallet.writeContract(request)
      } catch (error) {
        throw wrapContractError(error, 'withdrawFees')
      }
    },
    async transferOwnership(newOwner: Address): Promise<Hash> {
      const {wallet, sender} = requireWallet()
      try {
        const {request} = await publicClient.simulateContract({
          ...contract,
          functionName: 'transferOwnership',
          args: [newOwner],
          account: sender,
        })
        return await wallet.writeContract(request)
      } catch (error) {
        throw wrapContractError(error, 'transferOwnership')
      }
    },
    async acceptOwnership(): Promise<Hash> {
      const {wallet, sender} = requireWallet()
      try {
        const {request} = await publicClient.simulateContract({
          ...contract,
          functionName: 'acceptOwnership',
          account: sender,
        })
        return await wallet.writeContract(request)
      } catch (error) {
        throw wrapContractError(error, 'acceptOwnership')
      }
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

    async commit({lock, party, counterparty}: CommitArgs): Promise<Hash> {
      assertHex32(lock, 'lock')
      const {wallet, sender} = requireWallet()

      // 1-2. structural + pairing validation (mirrors the contract's order)
      validateTerms(party)
      validateTerms(counterparty)
      validateTermPairing(party, counterparty)

      // 3. only the LOCAL side's chainId must match; the counterparty may be remote
      const connectedChainId = BigInt(await publicClient.getChainId())
      if (party.chainId !== connectedChainId) {
        throw new QuipSdkError({
          code: 'CHAIN_ID_MISMATCH',
          message:
            `party.chainId (${party.chainId}) does not match the connected chain (${connectedChainId}); ` +
            "commit must be sent on the chain holding the party's assets (contract: ChainIdMismatch)",
          details: {partyChainId: party.chainId, connectedChainId},
        })
      }

      // 4. QuipWallet gate — the most likely integration failure, so check
      // it before burning a simulation round-trip
      if (!(await isQuipWallet(sender))) {
        throw new QuipSdkError({
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
          error instanceof QuipSdkError &&
          error.code === 'WINDOW_VIOLATED' &&
          proposedBy(party, counterparty) === 'counterparty' &&
          timestamp < counterparty.commitmentDeadline
        ) {
          throw new QuipSdkError({
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

      // 6-7. SECURITY: re-read the fee immediately before simulation — the
      // owner can change it, and the contract checks msg.value for EXACT
      // equality (IncorrectNativeAmountReceived); a stale fee bricks the tx
      // in either direction (under- AND overpayment revert)
      const fee = await read<bigint>('commitmentFee')
      const value = totalNative(party) + fee

      // 8-9. simulate, then submit the SIMULATED request
      try {
        const {request} = await publicClient.simulateContract({
          ...contract,
          functionName: 'commit',
          args: [lock, toAbiTerms(party), toAbiTerms(counterparty)],
          value,
          account: sender,
        })
        return await wallet.writeContract(request)
      } catch (error) {
        throw wrapContractError(error, 'commit')
      }
    },

    async claim({secret, party, counterparty, verifyOnChainState = true}: ClaimArgs): Promise<Hash> {
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
        throw new QuipSdkError({
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

      // 6. optional on-chain state verification (termsHash + posted)
      if (verifyOnChainState) {
        await verifyPostedState(lock, party, counterparty, counterparty)
      }

      // 7-8. simulate, then submit. NOTE: claim is permissionless — any
      // sender with the secret may claim; no caller check is added here
      try {
        const {request} = await publicClient.simulateContract({
          ...contract,
          functionName: 'claim',
          args: [secret, toAbiTerms(party), toAbiTerms(counterparty)],
          account: sender,
        })
        return await wallet.writeContract(request)
      } catch (error) {
        throw wrapContractError(error, 'claim')
      }
    },

    async reclaim({lock, party, counterparty, verifyOnChainState = true}: ReclaimArgs): Promise<Hash> {
      assertHex32(lock, 'lock')
      const {wallet, sender} = requireWallet()

      // 1. structural + pairing validation
      validateTerms(party)
      validateTerms(counterparty)
      validateTermPairing(party, counterparty)

      // 2. the reclaimed leg must be local
      const connectedChainId = BigInt(await publicClient.getChainId())
      if (party.chainId !== connectedChainId) {
        throw new QuipSdkError({
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

      // 4. optional on-chain state verification (party's side must be posted)
      if (verifyOnChainState) {
        await verifyPostedState(lock, party, counterparty, party)
      }

      // 5-6. simulate, then submit
      try {
        const {request} = await publicClient.simulateContract({
          ...contract,
          functionName: 'reclaim',
          args: [lock, toAbiTerms(party), toAbiTerms(counterparty)],
          account: sender,
        })
        return await wallet.writeContract(request)
      } catch (error) {
        throw wrapContractError(error, 'reclaim')
      }
    },

    admin,
  }
}
