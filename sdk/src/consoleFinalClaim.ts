import { readFile } from 'node:fs/promises'
import { join, resolve } from 'node:path'
import { createPublicClient, createWalletClient, decodeEventLog, decodeFunctionData, defineChain, http } from 'viem'
import type { Address, Hash, Hex, PublicClient, TransactionReceipt, WalletClient } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { applyPartyCommand } from './cliCommands.js'
import type { PersistedInclusion } from './clientState.js'
import { REVEALING_CLAIM_REFERENCE_SCHEMA } from './consoleReveal.js'
import { loadConsoleRuntimeConfig } from './consoleTrade.js'
import type { ConsoleRuntimeConfig } from './consoleTrade.js'
import { CrossChainLegState, settlementLock, tradeId } from './protocol.js'
import type { ProtocolTerms } from './protocol.js'
import { createProtocolClient } from './protocolClient.js'
import { crossChainWrapperAbi } from './generated/crossChainWrapperAbi.js'
import { loadConsoleConfigIdentity, publishLockedWorkspaceWorkflowState, restoreWorkspaceWorkflowState, withWorkspaceMutation, writeLockedWorkspaceJournal } from './consoleWorkspace.js'
import type { Hex32 } from './types.js'

export const REVEAL_OBSERVATION_SCHEMA = 'quip-swap-reveal-observation.v1' as const
export const FINAL_CLAIM_JOURNAL_SCHEMA = 'quip-swap-transaction-journal.v1' as const
const ANVIL_BOB_KEY = '0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a' as Hex
const ANVIL_EXECUTOR_KEY = '0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6' as Hex

interface RevealReference {
  readonly networkId: string
  readonly tradeId: Hex32
  readonly chainId: 31338
  readonly wrapper: Address
  readonly transactionHash: Hash
  readonly sender: Address
  readonly nonce: number
  readonly submittedAtBlock: string
}
export type RevealLifecycle = 'pending' | 'included-non-final' | 'final' | 'reorganized' | 'reverted' | 'missing'
export interface RevealObservation {
  readonly schema: typeof REVEAL_OBSERVATION_SCHEMA
  readonly networkId: string
  readonly tradeId: Hex32
  readonly chainId: 31338
  readonly wrapper: Address
  readonly transactionHash: Hash
  readonly lifecycle: RevealLifecycle
  readonly observedHead: string
  readonly confirmations: string
  readonly requiredConfirmations: string
  readonly inclusion?: PersistedInclusion
  readonly finalClaimEnabled: boolean
  readonly warning?: string
}
interface InspectedReveal {
  readonly lifecycle: RevealLifecycle
  readonly observedHead: string
  readonly confirmations: string
  readonly inclusion?: PersistedInclusion
  readonly secret?: Hex32
}
export interface RevealObservationBoundary {
  inspect(args: { readonly reference: RevealReference; readonly terms: ProtocolTerms; readonly lock: Hex32; readonly requiredConfirmations: bigint; readonly alice: Address }): Promise<InspectedReveal>
}
export interface FinalClaimPreview {
  readonly chainId: 31337
  readonly wrapper: Address
  readonly htlc: Address
  readonly submitter: Address
  readonly recipient: Address
  readonly payouts: readonly {
    readonly token: Address
    readonly amount: string
    readonly htlcChange: string
    readonly recipientChange: string
  }[]
  readonly successPathDelay: 'none'
}
export interface FinalClaimBoundary {
  state(terms: ProtocolTerms, lock: Hex32): Promise<CrossChainLegState>
  htlc(terms: ProtocolTerms, lock: Hex32): Promise<Address>
  transaction(hash: Hash): Promise<'pending' | 'success' | 'reverted' | 'missing'>
  submit(args: { readonly terms: ProtocolTerms; readonly lock: Hex32; readonly secret: Hex32 }): Promise<Hash>
}

const object = (value: unknown, label: string): Record<string, unknown> => {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) throw new Error(`${label} must be an object`)
  return value as Record<string, unknown>
}
const isHex32 = (value: unknown): value is Hex32 => typeof value === 'string' && /^0x[0-9a-fA-F]{64}$/.test(value)
const isAddress = (value: unknown): value is Address => typeof value === 'string' && /^0x[0-9a-fA-F]{40}$/.test(value)

function parseReference(serialized: string): RevealReference {
  const value = object(JSON.parse(serialized), 'revealing-claim reference')
  if (value['schema'] !== REVEALING_CLAIM_REFERENCE_SCHEMA || typeof value['networkId'] !== 'string' || !isHex32(value['tradeId']) || value['chainId'] !== 31338 || !isAddress(value['wrapper']) || !isHex32(value['transactionHash']) || !isAddress(value['sender']) || !Number.isSafeInteger(value['nonce']) || typeof value['submittedAtBlock'] !== 'string' || !/^[0-9]+$/.test(value['submittedAtBlock'])) throw new Error('invalid revealing-claim reference')
  return value as unknown as RevealReference
}

export function createLocalRevealObservationBoundary(config: ConsoleRuntimeConfig): RevealObservationBoundary {
  const route = config.chains[1]
  const chain = defineChain({
    id: 31338,
    name: 'anvil-31338',
    nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
    rpcUrls: { default: { http: [route.rpcUrl] } },
  })
  const publicClient = createPublicClient({
    chain,
    transport: http(route.rpcUrl),
  }) as PublicClient
  const client = createProtocolClient({
    addresses: route.addresses as unknown as Parameters<typeof createProtocolClient>[0]['addresses'],
    publicClient,
  })
  return {
    inspect: async ({ reference, terms, lock, requiredConfirmations, alice }) => {
      const head = await publicClient.getBlockNumber()
      let receipt: TransactionReceipt
      try {
        receipt = await publicClient.getTransactionReceipt({
          hash: reference.transactionHash,
        })
      } catch {
        try {
          await publicClient.getTransaction({
            hash: reference.transactionHash,
          })
          return {
            lifecycle: 'pending',
            observedHead: head.toString(),
            confirmations: '0',
          }
        } catch {
          return {
            lifecycle: 'missing',
            observedHead: head.toString(),
            confirmations: '0',
          }
        }
      }
      if (receipt.status !== 'success')
        return {
          lifecycle: 'reverted',
          observedHead: head.toString(),
          confirmations: '0',
        }
      if (receipt.blockHash === null) throw new Error('revealing-claim receipt lacks block hash')
      const inclusion = {
        transactionHash: receipt.transactionHash,
        blockNumber: receipt.blockNumber.toString(),
        blockHash: receipt.blockHash as Hex32,
      }
      let canonical: Hex32 | undefined
      try {
        canonical = (await publicClient.getBlock({ blockNumber: receipt.blockNumber })).hash as Hex32
      } catch {}
      if (canonical !== receipt.blockHash)
        return {
          lifecycle: 'reorganized',
          observedHead: head.toString(),
          confirmations: '0',
          inclusion,
        }
      const transaction = await publicClient.getTransaction({
        hash: reference.transactionHash,
      })
      if (transaction.to?.toLowerCase() !== reference.wrapper.toLowerCase() || transaction.from.toLowerCase() !== alice.toLowerCase()) throw new Error('revealing-claim transaction actor or wrapper mismatch')
      const decoded = decodeFunctionData({
        abi: crossChainWrapperAbi,
        data: transaction.input,
      })
      if (decoded.functionName !== 'claim' || !Array.isArray(decoded.args) || decoded.args.length !== 4) throw new Error('revealing transaction is not the expected claim call')
      const [decodedTerms, party, decodedLock, secret] = decoded.args as unknown as [ProtocolTerms, boolean, Hex32, Hex32]
      if (party !== false || decodedLock !== lock || !isHex32(secret) || tradeId(decodedTerms) !== reference.tradeId || settlementLock(reference.tradeId, secret) !== lock) throw new Error('revealing-claim calldata binding mismatch')
      const events = receipt.logs
        .filter((log) => log.address.toLowerCase() === reference.wrapper.toLowerCase())
        .filter((log) => {
          try {
            const event = decodeEventLog({
              abi: crossChainWrapperAbi,
              data: log.data,
              topics: log.topics,
              strict: true,
            })
            const args = event.args as unknown as Record<string, unknown>
            return event.eventName === 'Claimed' && args['tradeId'] === reference.tradeId && args['lock'] === lock && args['side'] === 1
          } catch {
            return false
          }
        })
      if (events.length !== 1) throw new Error('revealing transaction lacks one exact Claimed event')
      if ((await client.getCrossChainState(terms, false, lock)) !== CrossChainLegState.Claimed) throw new Error('revealing claim event disagrees with wrapper state')
      const confirmations = head - receipt.blockNumber + 1n
      return {
        lifecycle: confirmations >= requiredConfirmations ? 'final' : 'included-non-final',
        observedHead: head.toString(),
        confirmations: confirmations.toString(),
        inclusion,
        secret,
      }
    },
  }
}

export async function observeReveal(args: { readonly workspace: string; readonly configPath: string; readonly boundary?: RevealObservationBoundary }): Promise<RevealObservation> {
  const config = await loadConsoleRuntimeConfig(args.configPath, 'bob')
  return withWorkspaceMutation(args.workspace, async () => {
    const expected = {
      party: 'bob' as const,
      networkId: config.identity.networkId,
      configDigest: config.identity.digest,
    }
    const restored = await restoreWorkspaceWorkflowState(args.workspace, expected)
    if (restored.publicState.party !== 'bob' || restored.publicState.stage !== 'bob-committed') throw new Error('reveal observation requires Bob committed state')
    const reference = parseReference(await readFile(join(resolve(config.exchangeDirectory), `revealing-claim-${restored.publicState.tradeId.slice(2)}.json`), 'utf8'))
    if (reference.networkId !== config.identity.networkId || reference.tradeId !== restored.publicState.tradeId || reference.wrapper.toLowerCase() !== config.chains[1].wrapper.toLowerCase() || reference.sender.toLowerCase() !== config.actors.alice.toLowerCase()) throw new Error('revealing-claim reference binding mismatch')
    const inspected = await (args.boundary ?? createLocalRevealObservationBoundary(config)).inspect({
      reference,
      terms: restored.terms,
      lock: restored.publicState.derived.settlementLock,
      requiredConfirmations: config.requiredConfirmations,
      alice: config.actors.alice,
    })
    const final = inspected.lifecycle === 'final'
    if (final && inspected.secret === undefined) throw new Error('final revealing observation lacks authenticated preimage')
    const result: RevealObservation = {
      schema: REVEAL_OBSERVATION_SCHEMA,
      networkId: config.identity.networkId,
      tradeId: restored.publicState.tradeId,
      chainId: 31338,
      wrapper: config.chains[1].wrapper,
      transactionHash: reference.transactionHash,
      lifecycle: inspected.lifecycle,
      observedHead: inspected.observedHead,
      confirmations: inspected.confirmations,
      requiredConfirmations: config.requiredConfirmations.toString(),
      ...(inspected.inclusion === undefined ? {} : { inclusion: inspected.inclusion }),
      finalClaimEnabled: final,
      ...(!final
        ? {
            warning: `Revealing claim is ${inspected.lifecycle}; final claim remains disabled.`,
          }
        : {}),
    }
    const next = final
      ? applyPartyCommand(restored.publicState, restored.secretState, {
          command: 'observe-reveal',
          settlementSecret: inspected.secret!,
          inclusion: inspected.inclusion!,
        })
      : applyPartyCommand(restored.publicState, restored.secretState, {
          command: 'record-observation',
        })
    await publishLockedWorkspaceWorkflowState({
      root: args.workspace,
      expected: {
        ...expected,
        tradeId: restored.publicState.tradeId,
        generation: restored.publicState.generation,
      },
      publicState: next.publicState,
      secretState: next.secretState,
      publicArtifacts: {
        'reveal-observation.json': `${JSON.stringify(result, null, 2)}\n`,
      },
    })
    return result
  })
}

export function createLocalFinalClaimBoundary(config: ConsoleRuntimeConfig, submitter: 'bob' | 'configured-executor' = 'bob'): { readonly executor: Address; readonly boundary: FinalClaimBoundary } {
  const route = config.chains[0]
  const chain = defineChain({
    id: 31337,
    name: 'anvil-31337',
    nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
    rpcUrls: { default: { http: [route.rpcUrl] } },
  })
  const account = privateKeyToAccount(submitter === 'bob' ? ANVIL_BOB_KEY : ANVIL_EXECUTOR_KEY)
  const executor = submitter === 'bob' ? config.actors.bob : config.actors.executor
  if (account.address.toLowerCase() !== executor.toLowerCase()) throw new Error('local final-claim account does not match configuration')
  const publicClient = createPublicClient({
    chain,
    transport: http(route.rpcUrl),
  }) as PublicClient
  const walletClient = createWalletClient({
    chain,
    transport: http(route.rpcUrl),
    account,
  }) as WalletClient
  const client = createProtocolClient({
    addresses: route.addresses as unknown as Parameters<typeof createProtocolClient>[0]['addresses'],
    publicClient,
    walletClient,
  })
  return {
    executor,
    boundary: {
      state: (terms, lock) => client.getCrossChainState(terms, true, lock),
      htlc: (terms, lock) => client.getCrossChainHTLC(terms, true, lock),
      transaction: async (hash) => {
        try {
          const receipt = await publicClient.getTransactionReceipt({ hash })
          return receipt.status === 'success' ? 'success' : 'reverted'
        } catch {
          try {
            await publicClient.getTransaction({ hash })
            return 'pending'
          } catch {
            return 'missing'
          }
        }
      },
      submit: ({ terms, lock, secret }) => client.claimCrossChain(terms, true, lock, secret),
    },
  }
}

export async function submitFinalClaim(args: { readonly workspace: string; readonly configPath: string; readonly boundary?: FinalClaimBoundary; readonly executor?: Address; readonly onPreview?: (preview: FinalClaimPreview) => void }): Promise<{
  readonly tradeId: Hex32
  readonly transactionHash: Hash
  readonly lifecycle: 'pending' | 'success'
  readonly reused: boolean
  readonly preview: FinalClaimPreview
}> {
  const config = await loadConsoleRuntimeConfig(args.configPath, 'bob')
  const local = args.boundary === undefined ? createLocalFinalClaimBoundary(config) : undefined
  const boundary = args.boundary ?? local!.boundary
  const executor = args.executor ?? local!.executor
  return withWorkspaceMutation(args.workspace, async () => {
    const expected = {
      party: 'bob' as const,
      networkId: config.identity.networkId,
      configDigest: config.identity.digest,
    }
    const restored = await restoreWorkspaceWorkflowState(args.workspace, expected)
    if (restored.publicState.party !== 'bob' || restored.secretState.party !== 'bob' || !['reveal-final', 'final-claim'].includes(restored.publicState.stage) || restored.secretState.settlementSecret === undefined) throw new Error('final claim requires Bob verified reveal state')
    if (!restored.publicState.selected.finalClaimExecutors.some((value) => value.toLowerCase() === executor.toLowerCase())) throw new Error('final-claim executor is not selected')
    const side = restored.terms.partySide
    const view: FinalClaimPreview = {
      chainId: 31337,
      wrapper: config.chains[0].wrapper,
      htlc: await boundary.htlc(restored.terms, restored.publicState.derived.settlementLock),
      submitter: executor,
      recipient: side.recipient,
      payouts: side.assets.map((asset) => ({
        token: asset.target,
        amount: asset.amount.toString(),
        htlcChange: `-${asset.amount}`,
        recipientChange: `+${asset.amount}`,
      })),
      successPathDelay: 'none',
    }
    args.onPreview?.(view)
    const journalPath = join(resolve(args.workspace), 'journal', 'final-claim.json')
    try {
      const existing = object(JSON.parse(await readFile(journalPath, 'utf8')), 'final-claim journal')
      if (!isHex32(existing['transactionHash']) || existing['tradeId'] !== restored.publicState.tradeId || typeof existing['executor'] !== 'string' || existing['executor'].toLowerCase() !== executor.toLowerCase()) throw new Error('final-claim journal binding mismatch')
      const lifecycle = await boundary.transaction(existing['transactionHash'])
      if (lifecycle === 'missing' || lifecycle === 'reverted') throw new Error(`recorded final claim is ${lifecycle}; observe or recover before resending`)
      return {
        tradeId: restored.publicState.tradeId,
        transactionHash: existing['transactionHash'],
        lifecycle,
        reused: true,
        preview: view,
      }
    } catch (error) {
      if (!(error instanceof Error && 'code' in error && error.code === 'ENOENT')) throw error
    }
    if (restored.publicState.stage !== 'reveal-final') throw new Error('final claim state lacks a transaction journal; refusing resend')
    if ((await boundary.state(restored.terms, restored.publicState.derived.settlementLock)) !== CrossChainLegState.Committed) throw new Error('Alice leg is not in the exact committed state')
    const hash = await boundary.submit({
      terms: restored.terms,
      lock: restored.publicState.derived.settlementLock,
      secret: restored.secretState.settlementSecret,
    })
    await writeLockedWorkspaceJournal(args.workspace, 'final-claim', `${JSON.stringify({ schema: FINAL_CLAIM_JOURNAL_SCHEMA, action: 'final-claim', networkId: config.identity.networkId, tradeId: restored.publicState.tradeId, chainId: 31337, wrapper: config.chains[0].wrapper, transactionHash: hash, executor }, null, 2)}\n`)
    const next = applyPartyCommand(restored.publicState, restored.secretState, {
      command: 'handoff-final-claim',
      executor,
      transactionHash: hash,
    })
    await publishLockedWorkspaceWorkflowState({
      root: args.workspace,
      expected: {
        ...expected,
        tradeId: restored.publicState.tradeId,
        generation: restored.publicState.generation,
      },
      publicState: next.publicState,
      secretState: next.secretState,
    })
    return {
      tradeId: restored.publicState.tradeId,
      transactionHash: hash,
      lifecycle: 'pending',
      reused: false,
      preview: view,
    }
  })
}
