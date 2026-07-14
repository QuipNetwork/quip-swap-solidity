/**
 * Builders for synthetic, ABI-correct Omnibus event logs.
 *
 * Used by the pure unit tests (`receipts.test.ts`, `events.test.ts`) to
 * construct decodable `Commitment` / `Claim` / `Reclaimed` logs — including
 * logs at the WRONG contract address (to prove address-scoped decoding) and
 * a fake `Claim` whose secret does not open its lock (to prove
 * `extractRevealedSecret`'s hash verification). No chain required.
 *
 * NOT exported from the SDK package — test infrastructure only.
 */
import {encodeAbiParameters, encodeEventTopics} from 'viem'
import type {Address, Hex, Log} from 'viem'
import {omnibusAbi} from '../../src/generated/omnibusAbi.js'
import {termsAbiParameter} from '../../src/hashing.js'
import type {Hex32, Terms} from '../../src/types.js'

const BLOCK_HASH = `0x${'bb'.repeat(32)}` as Hex
const TX_HASH = `0x${'cc'.repeat(32)}` as Hex

/** Common positional fields viem's decoders/`parseEventLogs` read off a log. */
function baseLog(address: Address, topics: readonly (Hex | Hex[] | null)[], data: Hex, logIndex: number): Log {
  return {
    address,
    topics: topics as [Hex, ...Hex[]],
    data,
    blockHash: BLOCK_HASH,
    blockNumber: 1n,
    transactionHash: TX_HASH,
    transactionIndex: 0,
    logIndex,
    removed: false,
  } as unknown as Log
}

/** The mutable tuple shape viem encodes for the `Terms` struct. */
function toTuple(terms: Terms) {
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

/** Builds a `Commitment(bytes32 indexed lock, Terms party, bytes signer, address indexed sender)` log. */
export function commitmentLog(args: {
  address: Address
  lock: Hex32
  sender: Address
  /** The committing identity blob (defaults to the bare sender address). */
  signer?: Hex
  party: Terms
  logIndex?: number
}): Log {
  const topics = encodeEventTopics({
    abi: omnibusAbi,
    eventName: 'Commitment',
    args: {lock: args.lock, sender: args.sender},
  })
  // non-indexed data: (Terms party, bytes signer)
  const data = encodeAbiParameters(
    [termsAbiParameter, {name: 'signer', type: 'bytes'}],
    [toTuple(args.party), args.signer ?? args.sender],
  )
  return baseLog(args.address, topics, data, args.logIndex ?? 0)
}

/** Builds a `Claim(address recipient, bytes32 indexed lock, bytes32 secret)` log. */
export function claimLog(args: {
  address: Address
  lock: Hex32
  secret: Hex32
  recipient: Address
  logIndex?: number
}): Log {
  const topics = encodeEventTopics({abi: omnibusAbi, eventName: 'Claim', args: {lock: args.lock}})
  const data = encodeAbiParameters(
    [
      {name: 'recipient', type: 'address'},
      {name: 'secret', type: 'bytes32'},
    ],
    [args.recipient, args.secret],
  )
  return baseLog(args.address, topics, data, args.logIndex ?? 0)
}

/** Builds a `Reclaimed(address caller, bytes32 indexed lock, address indexed recipient)` log. */
export function reclaimedLog(args: {
  address: Address
  lock: Hex32
  caller: Address
  recipient: Address
  logIndex?: number
}): Log {
  const topics = encodeEventTopics({
    abi: omnibusAbi,
    eventName: 'Reclaimed',
    args: {lock: args.lock, recipient: args.recipient},
  })
  const data = encodeAbiParameters([{name: 'caller', type: 'address'}], [args.caller])
  return baseLog(args.address, topics, data, args.logIndex ?? 0)
}
