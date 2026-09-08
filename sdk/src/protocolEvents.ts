import {decodeEventLog} from 'viem'
import type {Abi, Address, Hash, Log, PublicClient, TransactionReceipt} from 'viem'
import {assetSupportRegistryAbi} from './generated/assetSupportRegistryAbi.js'
import {crossChainWrapperAbi} from './generated/crossChainWrapperAbi.js'
import {directAuthorizationAbi} from './generated/directAuthorizationAbi.js'
import {quipWalletAbi} from './generated/quipWalletAbi.js'
import {sameChainWrapperAbi} from './generated/sameChainWrapperAbi.js'
import {swapHTLCAbi} from './generated/swapHTLCAbi.js'
import type {ProtocolAddresses} from './protocolClient.js'

export type ProtocolEventSource =
  | 'assetSupportRegistry'
  | 'directAuthorization'
  | 'quipWallet'
  | 'crossChainWrapper'
  | 'sameChainWrapper'
  | 'swapHTLC'

export interface ProtocolEvent {
  readonly source: ProtocolEventSource
  readonly address: Address
  readonly eventName: string
  readonly args: unknown
  readonly blockNumber: bigint | null
  readonly transactionHash: Hash | null
  readonly logIndex: number | null
}

const abiBySource: Readonly<Record<ProtocolEventSource, Abi>> = {
  assetSupportRegistry: assetSupportRegistryAbi as Abi,
  directAuthorization: directAuthorizationAbi as Abi,
  quipWallet: quipWalletAbi as Abi,
  crossChainWrapper: crossChainWrapperAbi as Abi,
  sameChainWrapper: sameChainWrapperAbi as Abi,
  swapHTLC: swapHTLCAbi as Abi,
}

/**
 * Decodes known events only from caller-supplied protocol, wallet, and HTLC addresses, compared without
 * case sensitivity. Wallets and dynamic HTLC clones must be listed explicitly; they are not discovered.
 * Unknown or undecodable logs are skipped. Address scoping prevents unrelated emitters from masquerading
 * as these contracts, but the caller still owns deployment authenticity and exact trade/event validation.
 */
export function decodeProtocolEvents(
  logs: readonly Log[],
  addresses: ProtocolAddresses,
  quipWallets: readonly Address[] = [],
  swapHTLCs: readonly Address[] = [],
): ProtocolEvent[] {
  const sourceByAddress = new Map<string, ProtocolEventSource>([
    [addresses.assetSupportRegistry.toLowerCase(), 'assetSupportRegistry'],
    [addresses.directAuthorization.toLowerCase(), 'directAuthorization'],
    [addresses.crossChainWrapper.toLowerCase(), 'crossChainWrapper'],
    [addresses.sameChainWrapper.toLowerCase(), 'sameChainWrapper'],
  ])

  for (const wallet of quipWallets)
    sourceByAddress.set(wallet.toLowerCase(), 'quipWallet')
  for (const htlc of swapHTLCs)
    sourceByAddress.set(htlc.toLowerCase(), 'swapHTLC')

  const events: ProtocolEvent[] = []

  for (const log of logs) {
    const source = sourceByAddress.get(log.address.toLowerCase())

    if (source === undefined)
      continue

    try {
      const decoded = decodeEventLog({
        abi: abiBySource[source],
        data: log.data,
        topics: log.topics,
        strict: true
      })

      if (decoded.eventName === undefined)
        continue

      events.push({
        source,
        address: log.address,
        eventName: decoded.eventName,
        args: decoded.args,
        blockNumber: log.blockNumber,
        transactionHash: log.transactionHash,
        logIndex: log.logIndex,
      })
    }
    catch {
      // Ignore non-event and unknown logs emitted by a known contract.
    }
  }

  return events
}

/**
 * Waits using Viem's receipt/replacement behavior and rejects a reverted receipt. An omitted confirmation
 * count uses the client's default; choose the route's reviewed threshold explicitly when finality matters.
 * Returns the actual receipt and address-scoped events, which can be empty. A successful receipt does not
 * prove the intended trade, side, state transition, or payout: verify those fields and any replacement
 * transaction before advancing the workflow. Confirmation counts do not preclude later reorganizations.
 */
export async function waitForProtocolReceipt(
  publicClient: PublicClient,
  hash: Hash,
  addresses: ProtocolAddresses,
  confirmations?: number,
  quipWallets: readonly Address[] = [],
  swapHTLCs: readonly Address[] = [],
): Promise<{
  readonly receipt: TransactionReceipt;
  readonly events: readonly ProtocolEvent[]
}> {
  const receipt = await publicClient.waitForTransactionReceipt({
    hash,
    ...(confirmations === undefined ? {} : {
      confirmations
    }),
  })

  if (receipt.status !== 'success')
    throw new Error(`Protocol transaction reverted: ${hash}`)

  return {
    receipt,
    events: decodeProtocolEvents(receipt.logs, addresses, quipWallets, swapHTLCs)
  }
}
