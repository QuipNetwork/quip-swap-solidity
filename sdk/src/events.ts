/**
 * Typed decoding and query helpers for all active Omnibus events:
 *
 * ```solidity
 * event Commitment(bytes32 indexed lock, Terms party, bytes signer, address indexed sender);
 * event Claim(address recipient, bytes32 indexed lock, bytes32 secret);
 * event Reclaimed(address caller, bytes32 indexed lock, address indexed recipient);
 * event FeeUpdated(uint256 oldFee, uint256 newFee);
 * event FeesWithdrawn(address indexed to, uint256 amount);
 * ```
 *
 * Operational caveats every consumer must respect:
 * - Observing an event ONCE is not finality: logs can be duplicated by
 *   RPC providers and removed/re-emitted across chain reorganizations.
 *   Apply your own confirmation policy before treating a log as final.
 * - `Reclaimed` is legitimately emitted TWICE in one transaction when a
 *   reclaim settles both legs locally — helpers return arrays.
 * - `Claim.secret` lives in event DATA (not a topic): the lock is the only
 *   filterable topic, and the secret becomes public the moment the event
 *   is emitted.
 */
import {parseEventLogs} from 'viem'
import type {Address, BlockNumber, BlockTag, Hex, Log, PublicClient} from 'viem'
import {QuipSwapError} from './errors.js'
import {generateLock} from './hashing.js'
import {omnibusAbi} from './generated/omnibusAbi.js'
import {AssetType} from './types.js'
import type {Hex32, Terms} from './types.js'

/** A decoded `Commitment` event. */
export interface CommitmentEvent {
  /** The hashlock the commitment is bound to (indexed topic). */
  readonly lock: Hex32
  /** The committing side's FULL terms, recovered from event data. */
  readonly party: Terms
  /**
   * The identity blob that endorsed this commit (event data) — the event's
   * attribution field. A client that cares WHICH identity posted a side
   * (e.g. requiring the counterparty's agreed PQ identity before revealing
   * the secret) checks THIS field off-chain; the contract never does.
   */
  readonly signer: Hex
  /** The address that submitted and FUNDED the commit (indexed topic). */
  readonly sender: Address
  /** Block number the log was found in (`null` for pending logs). */
  readonly blockNumber: bigint | null
  /** Transaction hash the log was found in (`null` for pending logs). */
  readonly transactionHash: Hex32 | null
  /** Log index within the block (`null` for pending logs). */
  readonly logIndex: number | null
}

/** A decoded `Claim` event. The `secret` field is public once emitted. */
export interface ClaimEvent {
  /** The address that called `claim` (event data, NOT the asset recipient per se). */
  readonly recipient: Address
  /** The hashlock that was claimed (indexed topic — the only filterable field). */
  readonly lock: Hex32
  /** The revealed 32-byte preimage. Public from this moment on. */
  readonly secret: Hex32
  readonly blockNumber: bigint | null
  readonly transactionHash: Hex32 | null
  readonly logIndex: number | null
}

/** A decoded `Reclaimed` event. Two may appear in a single transaction. */
export interface ReclaimedEvent {
  /** The address that called `reclaim` (permissionless — any account). */
  readonly caller: Address
  /** The hashlock that was reclaimed (indexed topic). */
  readonly lock: Hex32
  /** The `reclaimRecipient` that received this leg's assets (indexed topic). */
  readonly recipient: Address
  readonly blockNumber: bigint | null
  readonly transactionHash: Hex32 | null
  readonly logIndex: number | null
}

/** Narrow a decoded uint8 to the {@link AssetType} enum, rejecting out-of-range values. */
function toAssetType(value: number): AssetType {
  if (value === 0 || value === 1 || value === 2 || value === 3) return value as AssetType
  throw new QuipSwapError({
    code: 'INVALID_ASSET_TYPE',
    message: `Decoded asset type ${value} is out of range`,
  })
}

/** Shape of the Terms tuple as viem decodes it from the ABI. */
interface DecodedTermsTuple {
  readonly chainId: bigint
  readonly reclaimRecipient: Address
  readonly recipient: Address
  readonly commitmentDeadline: bigint
  readonly claimDeadline: bigint
  readonly reclaimRelease: bigint
  readonly assets: readonly {
    readonly assetType: number
    readonly target: Address
    readonly id: bigint
    readonly amount: bigint
  }[]
}

/** Convert a viem-decoded Terms tuple into the SDK's typed, frozen {@link Terms}. */
function toTerms(decoded: DecodedTermsTuple): Terms {
  return Object.freeze({
    chainId: decoded.chainId,
    reclaimRecipient: decoded.reclaimRecipient,
    recipient: decoded.recipient,
    commitmentDeadline: decoded.commitmentDeadline,
    claimDeadline: decoded.claimDeadline,
    reclaimRelease: decoded.reclaimRelease,
    assets: Object.freeze(
      decoded.assets.map(a =>
        Object.freeze({assetType: toAssetType(a.assetType), target: a.target, id: a.id, amount: a.amount}),
      ),
    ),
  })
}

/**
 * Decodes every `Commitment` event in a list of logs (e.g. from a receipt
 * or `getLogs`), recovering the committing side's full typed {@link Terms}
 * from event data — this is how a coordinator reconstructs a side's terms
 * from chain history without an off-chain channel.
 *
 * Non-`Commitment` logs are skipped, not errors.
 *
 * NOTE: a raw ABI decoder — it does NOT verify `log.address`, so it decodes
 * any `Commitment`-shaped log in `logs`. Scope `logs` to the known Omnibus
 * deployment first (prefer `client.waitForReceipt` /
 * `waitForOmnibusReceipt(..., {address})`, or the address-scoped
 * {@link getCommitmentEvents}).
 *
 * @param logs - Pre-scoped logs (a receipt's `logs` array or a `getLogs` result).
 * @returns All decoded `Commitment` events, in log order.
 * @see IOmnibus.Commitment
 * @example
 * ```ts
 * // PREFERRED: client.waitForReceipt scopes decoding to the Omnibus address
 * const {commitments} = await client.waitForReceipt(hash)
 * commitments[0]?.party.assets // typed Asset[]
 *
 * // low-level: only on logs ALREADY scoped to the Omnibus address
 * const scoped = receipt.logs.filter(l => l.address.toLowerCase() === omnibus.toLowerCase())
 * const [commitment] = decodeCommitmentEvents(scoped)
 * ```
 */
export function decodeCommitmentEvents(logs: readonly Log[]): CommitmentEvent[] {
  const parsed = parseEventLogs({abi: omnibusAbi, eventName: 'Commitment', logs: logs as Log[], strict: true})
  return parsed.map(log => ({
    lock: log.args.lock,
    party: toTerms(log.args.party),
    signer: log.args.signer,
    sender: log.args.sender,
    blockNumber: log.blockNumber,
    transactionHash: log.transactionHash,
    logIndex: log.logIndex,
  }))
}

/**
 * Decodes every `Claim` event in a list of logs.
 *
 * The `secret` field is the revealed preimage: in a cross-chain swap this
 * is how the taker (or a relayer) learns the secret after the proposer
 * claims — watch the counterparty chain for `Claim` on the shared lock and
 * extract `secret`.
 *
 * NOTE: This helper does NOT filter by Omnibus contract address — it decodes
 * any log in `logs` whose shape matches the `Claim` ABI. Callers passing
 * unscoped logs (e.g. a full receipt or a broad `getLogs` result) may pick up
 * unrelated contracts. {@link extractRevealedSecret} inherits this behavior
 * and can then return a spoofed secret if a non-Omnibus log mimics `Claim`.
 * Prefer {@link getClaimEvents} / {@link watchClaimEvents} (address-scoped)
 * or pre-filter `logs` to the known Omnibus deployment before decoding.
 *
 * @param logs - Raw logs to scan; non-`Claim` logs are skipped.
 * @returns All decoded `Claim` events, in log order.
 * @see IOmnibus.Claim
 * @example
 * ```ts
 * // PREFERRED: client.waitForReceipt scopes decoding to the Omnibus address
 * const {claims} = await client.waitForReceipt(hash)
 * const secret = extractSecretFromClaims(claims, lock) // verified + scoped
 *
 * // low-level: only on logs ALREADY scoped to the Omnibus address
 * const scoped = receipt.logs.filter(l => l.address.toLowerCase() === omnibus.toLowerCase())
 * const someClaim = decodeClaimEvents(scoped)[0]?.secret // now public on-chain
 * ```
 */
export function decodeClaimEvents(logs: readonly Log[]): ClaimEvent[] {
  const parsed = parseEventLogs({abi: omnibusAbi, eventName: 'Claim', logs: logs as Log[], strict: true})
  return parsed.map(log => ({
    recipient: log.args.recipient,
    lock: log.args.lock,
    secret: log.args.secret,
    blockNumber: log.blockNumber,
    transactionHash: log.transactionHash,
    logIndex: log.logIndex,
  }))
}

/**
 * Extracts the revealed secret for a specific lock from a list of logs.
 *
 * Verifies the cryptographic relationship before returning: a `Claim` event
 * is accepted only when both its indexed `lock` equals the requested lock
 * AND `generateLock(event.secret)` hashes back to that lock. This rejects a
 * same-shaped fake `Claim(lock, wrongSecret)` whose `secret` does not
 * actually open the lock.
 *
 * Idempotent by construction: duplicate `Claim` logs for the same lock
 * carry the same secret (the lock is `keccak256(secret)`, so only one
 * preimage can ever satisfy it), so processing the same event twice
 * returns the same value.
 *
 * SECURITY: this does NOT filter by `log.address` — it inherits the
 * raw-log/address behavior of the decoders. Scope `logs` to the correct
 * Omnibus address first (prefer `client.waitForReceipt`,
 * `waitForOmnibusReceipt(..., {address})`, or the address-scoped
 * `getClaimEvents`/`watchClaimEvents`), or extract from an already-scoped
 * decoded {@link ClaimEvent} array via {@link extractSecretFromClaims}.
 *
 * @param logs - Raw logs to scan (receipt logs or a `getLogs` result).
 * @param lock - The lock whose secret to extract.
 * @returns The 32-byte secret, or `undefined` when no `Claim` for the lock
 *   carries a secret that hashes to it.
 * @see IOmnibus.Claim, Omnibus._generateLock
 * @example
 * ```ts
 * // prefer scoped claims; only use raw logs you have already address-scoped
 * const secret = extractRevealedSecret(scopedChainBLogs, lock)
 * if (secret) await chainAClient.claim({secret, party: bobTerms, counterparty: aliceTerms})
 * ```
 */
export function extractRevealedSecret(logs: readonly Log[], lock: Hex32): Hex32 | undefined {
  return extractSecretFromClaims(decodeClaimEvents(logs), lock)
}

/**
 * Extracts the revealed secret for a lock from already-decoded `Claim`
 * events — the safe, address-scoped path (the events typically come from
 * {@link OmnibusReceipt.claims}, which `client.waitForReceipt` /
 * `waitForOmnibusReceipt(..., {address})` already filter by `log.address`).
 *
 * Like {@link extractRevealedSecret} it verifies `generateLock(secret)`
 * hashes back to the requested lock, so a fake `Claim(lock, wrongSecret)`
 * is ignored.
 *
 * @param claims - Decoded `Claim` events (e.g. `receipt.claims`).
 * @param lock - The lock whose secret to extract.
 * @returns The 32-byte secret, or `undefined` when none matches.
 * @see IOmnibus.Claim, Omnibus._generateLock
 * @example
 * ```ts
 * const receipt = await aliceOnB.waitForReceipt(claimHash)
 * const secret = extractSecretFromClaims(receipt.claims, lock)
 * ```
 */
export function extractSecretFromClaims(claims: readonly ClaimEvent[], lock: Hex32): Hex32 | undefined {
  const lockLower = lock.toLowerCase()
  for (const event of claims) {
    if (event.lock.toLowerCase() !== lockLower) continue
    // verify the secret actually opens the lock — rejects a same-shaped fake
    if (generateLock(event.secret).toLowerCase() !== lockLower) continue
    return event.secret
  }
  return undefined
}

/**
 * Decodes every `Reclaimed` event in a list of logs.
 *
 * IMPORTANT: one reclaim transaction can legitimately emit TWO `Reclaimed`
 * events — when the counterparty leg is local and the lock was `Committed`,
 * both legs return to their respective `reclaimRecipient` addresses in one
 * call. Always handle the array, never assume a single event.
 *
 * NOTE: a raw ABI decoder — it does NOT verify `log.address`. Scope `logs`
 * to the known Omnibus deployment first (prefer `client.waitForReceipt` /
 * `waitForOmnibusReceipt(..., {address})`, or {@link getReclaimedEvents}).
 *
 * @param logs - Pre-scoped logs to scan; non-`Reclaimed` logs are skipped.
 * @returns All decoded `Reclaimed` events, in log order.
 * @see IOmnibus.Reclaimed, Omnibus.reclaim
 */
export function decodeReclaimedEvents(logs: readonly Log[]): ReclaimedEvent[] {
  const parsed = parseEventLogs({abi: omnibusAbi, eventName: 'Reclaimed', logs: logs as Log[], strict: true})
  return parsed.map(log => ({
    caller: log.args.caller,
    lock: log.args.lock,
    recipient: log.args.recipient,
    blockNumber: log.blockNumber,
    transactionHash: log.transactionHash,
    logIndex: log.logIndex,
  }))
}

/** Common arguments for historical event queries. */
export interface EventQueryArgs {
  /** The Viem public client to query through. */
  readonly publicClient: PublicClient
  /** The Omnibus contract address — always filter by contract address. */
  readonly address: Address
  /** Restrict results to one lock (indexed topic) when provided. */
  readonly lock?: Hex32
  /** Inclusive starting block; supply a deployment block to bound the scan. */
  readonly fromBlock?: BlockNumber | BlockTag
  /** Inclusive ending block. */
  readonly toBlock?: BlockNumber | BlockTag
}

/**
 * Queries historical `Commitment` events via `publicClient.getLogs`.
 *
 * Reorg caveat: a log returned here reflects the chain at query time only.
 * Re-query (or compare block hashes) after your confirmation depth before
 * acting on it.
 *
 * @param args - See {@link EventQueryArgs}.
 * @returns Decoded events in chain order.
 * @example
 * ```ts
 * const history = await getCommitmentEvents({publicClient, address, lock})
 * ```
 */
export async function getCommitmentEvents(args: EventQueryArgs): Promise<CommitmentEvent[]> {
  const logs = await getOmnibusLogs(args, 'Commitment')
  return decodeCommitmentEvents(logs)
}

/**
 * Queries historical `Claim` events via `publicClient.getLogs`.
 *
 * @param args - See {@link EventQueryArgs}.
 * @returns Decoded events in chain order. Apply your confirmation policy
 *   before treating a revealed secret's claim as settled.
 */
export async function getClaimEvents(args: EventQueryArgs): Promise<ClaimEvent[]> {
  const logs = await getOmnibusLogs(args, 'Claim')
  return decodeClaimEvents(logs)
}

/**
 * Queries historical `Reclaimed` events via `publicClient.getLogs`.
 *
 * @param args - See {@link EventQueryArgs}.
 * @returns Decoded events in chain order (possibly two per transaction).
 */
export async function getReclaimedEvents(args: EventQueryArgs): Promise<ReclaimedEvent[]> {
  const logs = await getOmnibusLogs(args, 'Reclaimed')
  return decodeReclaimedEvents(logs)
}

/** Shared `getLogs` plumbing: contract-address filter + optional lock topic. */
async function getOmnibusLogs(
  args: EventQueryArgs,
  eventName: 'Commitment' | 'Claim' | 'Reclaimed',
): Promise<Log[]> {
  const event = omnibusAbi.find(
    (entry): entry is Extract<(typeof omnibusAbi)[number], {type: 'event'}> =>
      entry.type === 'event' && entry.name === eventName,
  )
  /* v8 ignore next 3 -- the generated ABI always contains all three events */
  if (event === undefined) {
    throw new QuipSwapError({code: 'EVENT_NOT_FOUND', message: `Event ${eventName} missing from generated ABI`})
  }
  return (await args.publicClient.getLogs({
    address: args.address,
    event,
    ...(args.lock !== undefined ? {args: {lock: args.lock}} : {}),
    ...(args.fromBlock !== undefined ? {fromBlock: args.fromBlock} : {}),
    ...(args.toBlock !== undefined ? {toBlock: args.toBlock} : {}),
  } as Parameters<PublicClient['getLogs']>[0])) as Log[]
}

/**
 * Watches for live `Claim` events on a lock — the cross-chain coordinator's
 * tool for learning the revealed secret promptly.
 *
 * This is an OPTIONAL convenience; the SDK never requires a permanently
 * running watcher. The callback may fire more than once for the same claim
 * (duplicates, reorg re-emission) — {@link extractRevealedSecret}'s
 * idempotence makes acting on duplicates safe.
 *
 * @param args - Query args plus the callback.
 * @param args.onClaim - Invoked with each decoded `Claim` event observed.
 * @returns The unwatch function from Viem; call it to stop watching.
 * @example
 * ```ts
 * const stop = watchClaimEvents({publicClient, address, lock, onClaim: e => use(e.secret)})
 * ```
 */
export function watchClaimEvents(
  args: Omit<EventQueryArgs, 'fromBlock' | 'toBlock'> & {readonly onClaim: (event: ClaimEvent) => void},
): () => void {
  return args.publicClient.watchContractEvent({
    address: args.address,
    abi: omnibusAbi,
    eventName: 'Claim',
    ...(args.lock !== undefined ? {args: {lock: args.lock}} : {}),
    onLogs: logs => {
      for (const event of decodeClaimEvents(logs as Log[])) args.onClaim(event)
    },
  })
}
