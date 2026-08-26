import { mkdir, open, readFile } from 'node:fs/promises'
import { join, resolve } from 'node:path'
import { concatHex, createPublicClient, createWalletClient, decodeEventLog, defineChain, encodeAbiParameters, encodeFunctionData, http, keccak256, sliceHex, stringToHex } from 'viem'
import type { Address, Hash, Hex, PublicClient, Transaction, TransactionReceipt, WalletClient } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { applyPartyCommand } from './cliCommands.js'
import type { PersistedInclusion } from './clientState.js'
import { loadConsoleRuntimeConfig, parseConsoleOffer, TRADE_ACCEPTANCE_SCHEMA } from './consoleTrade.js'
import type { ConsoleRuntimeConfig } from './consoleTrade.js'
import { CrossChainLegState, ExpectedSourceState, KeyRole, commitPayloadHash, keyPossessionDigest, registrationDigest, tradeId } from './protocol.js'
import type { CommitAuthorizationRequest, InitialRegistration, ProtocolTerms } from './protocol.js'
import { createProtocolClient } from './protocolClient.js'
import { crossChainWrapperAbi } from './generated/crossChainWrapperAbi.js'
import { directAuthorizationAbi } from './generated/directAuthorizationAbi.js'
import { loadConsoleConfigIdentity, publishLockedWorkspaceWorkflowState, restoreWorkspaceWorkflowState, withWorkspaceMutation, writeLockedWorkspaceJournal } from './consoleWorkspace.js'
import type { Hex32 } from './types.js'

export const BOB_COMMIT_INPUT_SCHEMA = 'quip-swap-bob-commit.v1' as const
export const BOB_COMMIT_REFERENCE_SCHEMA = 'quip-swap-bob-commit-reference.v1' as const
export const BOB_COMMIT_OBSERVATION_SCHEMA = 'quip-swap-bob-commit-observation.v1' as const
const JOURNAL_SCHEMA = 'quip-swap-transaction-journal.v1' as const
const ANVIL_BOB_KEY = '0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a' as Hex

interface BobReference {
  readonly networkId: string
  readonly tradeId: Hex32
  readonly chainId: 31338
  readonly wrapper: Address
  readonly transactionHash: Hash
  readonly sender: Address
  readonly nonce: number
  readonly submittedAtBlock: string
}
export interface BobCommitPreview {
  readonly chainId: 31338
  readonly wrapper: Address
  readonly htlc: Address
  readonly principal: Address
  readonly recipient: Address
  readonly assets: readonly {
    readonly token: Address
    readonly amount: string
    readonly principalChange: string
    readonly htlcChange: string
  }[]
  readonly commitmentDeadline: string
  readonly claimDeadline: string
  readonly reclaimRelease: string
  readonly authorizationExpiry: string
  readonly authorizationMode: 'RegisteredDirect'
  readonly progressionGate: 'required-on-chain-preimage'
}
export interface BobCommitBoundary {
  state(terms: ProtocolTerms, lock: Hex32): Promise<CrossChainLegState>
  predictHTLC(terms: ProtocolTerms, lock: Hex32): Promise<Address>
  transaction(hash: Hash): Promise<'pending' | 'success' | 'reverted' | 'missing'>
  submit(args: { readonly terms: ProtocolTerms; readonly lock: Hex32; readonly actionNonce: Hex32; readonly expiry: bigint; readonly payloadHash: Hex32; readonly bobCommitSecret: Hex32 }): Promise<{
    readonly hash: Hash
    readonly nonce: number
    readonly submittedAtBlock: bigint
  }>
}
export type BobCommitLifecycle = 'pending' | 'committed' | 'replaced' | 'dropped' | 'reorganized' | 'reverted'
export interface BobCommitObservation {
  readonly schema: typeof BOB_COMMIT_OBSERVATION_SCHEMA
  readonly networkId: string
  readonly tradeId: Hex32
  readonly chainId: 31338
  readonly wrapper: Address
  readonly transactionHash: Hash
  readonly lifecycle: BobCommitLifecycle
  readonly observedHead: string
  readonly inclusion?: PersistedInclusion
  readonly replacementHash?: Hash
  readonly aliceClaimEnabled: boolean
  readonly warning?: string
}
export interface BobCommitObservationBoundary {
  inspect(args: { readonly reference: BobReference; readonly terms: ProtocolTerms; readonly lock: Hex32; readonly principal: Address }): Promise<Omit<BobCommitObservation, 'schema' | 'networkId' | 'tradeId' | 'chainId' | 'wrapper' | 'transactionHash' | 'aliceClaimEnabled' | 'warning'>>
}

const object = (value: unknown, label: string): Record<string, unknown> => {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) throw new Error(`${label} must be an object`)
  return value as Record<string, unknown>
}
const hex32 = (value: unknown): value is Hex32 => typeof value === 'string' && /^0x[0-9a-fA-F]{64}$/.test(value)
const address = (value: unknown): value is Address => typeof value === 'string' && /^0x[0-9a-fA-F]{40}$/.test(value)
const pqKey = (verifier: Address, label: string): Hex => concatHex([verifier, keccak256(stringToHex(label))])
const pqSignature = (key: Hex, digest: Hex32): Hex => encodeAbiParameters([{ type: 'bytes' }, { type: 'bytes32' }], [sliceHex(key, 20), digest])

function confirmation(serialized: string): void {
  const value = object(JSON.parse(serialized), 'Bob commit confirmation')
  if (value['schema'] !== BOB_COMMIT_INPUT_SCHEMA || value['confirmed'] !== true) throw new Error('Bob commit requires explicit confirmed=true input')
  if (/settlementSecret|bobCommitSecret|privateKey|signature/i.test(serialized)) throw new Error('Bob commit confirmation contains sensitive material')
}
function preview(config: ConsoleRuntimeConfig, terms: ProtocolTerms, expiry: string, htlc: Address): BobCommitPreview {
  const side = terms.counterpartySide
  return {
    chainId: 31338,
    wrapper: config.chains[1].wrapper,
    htlc,
    principal: side.principal,
    recipient: side.recipient,
    assets: side.assets.map((asset) => ({
      token: asset.target,
      amount: asset.amount.toString(),
      principalChange: `-${asset.amount}`,
      htlcChange: `+${asset.amount}`,
    })),
    commitmentDeadline: side.commitmentDeadline.toString(),
    claimDeadline: side.claimDeadline.toString(),
    reclaimRelease: side.reclaimRelease.toString(),
    authorizationExpiry: expiry,
    authorizationMode: 'RegisteredDirect',
    progressionGate: 'required-on-chain-preimage',
  }
}
function parseReference(serialized: string): BobReference {
  const value = object(JSON.parse(serialized), 'Bob commit reference')
  if (value['schema'] !== JOURNAL_SCHEMA && value['schema'] !== BOB_COMMIT_REFERENCE_SCHEMA) throw new Error('unsupported Bob commit reference')
  if (typeof value['networkId'] !== 'string' || !hex32(value['tradeId']) || value['chainId'] !== 31338 || !address(value['wrapper']) || !hex32(value['transactionHash']) || !address(value['sender']) || !Number.isSafeInteger(value['nonce']) || typeof value['submittedAtBlock'] !== 'string' || !/^[0-9]+$/.test(value['submittedAtBlock'])) throw new Error('invalid Bob commit reference')
  return value as unknown as BobReference
}

async function readObservationReference(path: string, localParty: 'alice' | 'bob'): Promise<BobReference> {
  try {
    return parseReference(await readFile(path, 'utf8'))
  } catch (error) {
    if (error instanceof Error && 'code' in error && error.code === 'ENOENT') {
      if (localParty === 'bob') throw new Error('Bob commit has not been submitted from this workspace. Run submit-bob-commit successfully before observe-bob-commit.')
      throw new Error('Bob commit reference is not available yet. Bob must run submit-bob-commit successfully before Alice can observe it.')
    }
    throw error
  }
}

async function publishReference(config: ConsoleRuntimeConfig, reference: BobReference): Promise<void> {
  await mkdir(config.exchangeDirectory, { recursive: true, mode: 0o700 })
  const path = join(resolve(config.exchangeDirectory), `bob-commit-${reference.tradeId.slice(2)}.json`)
  const contents = `${JSON.stringify({ schema: BOB_COMMIT_REFERENCE_SCHEMA, networkId: reference.networkId, tradeId: reference.tradeId, chainId: reference.chainId, wrapper: reference.wrapper, transactionHash: reference.transactionHash, sender: reference.sender, nonce: reference.nonce, submittedAtBlock: reference.submittedAtBlock }, null, 2)}\n`
  try {
    const handle = await open(path, 'wx', 0o600)
    try {
      await handle.writeFile(contents, 'utf8')
      await handle.sync()
    } finally {
      await handle.close()
    }
  } catch (error) {
    if (!(error instanceof Error && 'code' in error && error.code === 'EEXIST')) throw error
    if ((await readFile(path, 'utf8')) !== contents) throw new Error('Bob commit reference already exists with different contents')
  }
}

export function createLocalBobCommitBoundary(config: ConsoleRuntimeConfig): BobCommitBoundary {
  const route = config.chains[1]
  const chain = defineChain({
    id: 31338,
    name: 'anvil-31338',
    nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
    rpcUrls: { default: { http: [route.rpcUrl] } },
  })
  const account = privateKeyToAccount(ANVIL_BOB_KEY)
  if (account.address.toLowerCase() !== config.actors.bob.toLowerCase()) throw new Error('local Bob account does not match configuration')
  const publicClient = createPublicClient({
    chain,
    transport: http(route.rpcUrl),
  }) as PublicClient
  const walletClient = createWalletClient({
    chain,
    transport: http(route.rpcUrl),
    account,
  }) as WalletClient
  const addresses = route.addresses as unknown as Parameters<typeof createProtocolClient>[0]['addresses']
  const client = createProtocolClient({
    addresses,
    publicClient,
    walletClient,
  })
  return {
    state: (terms, lock) => client.getCrossChainState(terms, false, lock),
    predictHTLC: (terms, lock) => client.predictCrossChainHTLC(terms, false, lock),
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
    submit: async ({ terms, lock, actionNonce, expiry, payloadHash, bobCommitSecret }) => {
      const activeKey = pqKey(route.trustedVerifier, 'quip-swap-console-bob-active')
      const recoveryKey = pqKey(route.trustedVerifier, 'quip-swap-console-bob-recovery')
      const request: CommitAuthorizationRequest = {
        receiver: route.wrapper,
        terms,
        party: false,
        lock,
        actionNonce,
        bobCommitSecret,
        expiry,
        commitData: '0x',
      }
      const registration: InitialRegistration = {
        eoa: config.actors.bob,
        activePQKey: activeKey,
        recoveryPQKey: recoveryKey,
        commitTarget: route.verifier,
        commitPayloadHash: payloadHash,
        operationNonce: keccak256(concatHex([tradeId(terms), actionNonce])),
        expiry,
      }
      const digest = registrationDigest(31338n, addresses.directAuthorization, registration)
      const call = encodeFunctionData({
        abi: directAuthorizationAbi,
        functionName: 'authorizeCommit',
        args: [request, pqSignature(activeKey, payloadHash)],
      })
      const hash = await client.registerAndCommit(registration, '0x', pqSignature(activeKey, keyPossessionDigest(digest, KeyRole.Active, activeKey)), pqSignature(recoveryKey, keyPossessionDigest(digest, KeyRole.Recovery, recoveryKey)), sliceHex(call, 4))
      const [transaction, submittedAtBlock] = await Promise.all([publicClient.getTransaction({ hash }), publicClient.getBlockNumber()])
      return { hash, nonce: transaction.nonce, submittedAtBlock }
    },
  }
}

async function journal(workspace: string): Promise<BobReference | undefined> {
  try {
    return parseReference(await readFile(join(resolve(workspace), 'journal', 'bob-commit.json'), 'utf8'))
  } catch (error) {
    if (error instanceof Error && 'code' in error && error.code === 'ENOENT') return undefined
    throw error
  }
}

export async function submitBobCommit(args: { readonly workspace: string; readonly configPath: string; readonly input: string; readonly boundary?: BobCommitBoundary; readonly onPreview?: (preview: BobCommitPreview) => void }): Promise<{
  readonly tradeId: Hex32
  readonly transactionHash: Hash
  readonly lifecycle: 'pending' | 'success'
  readonly reused: boolean
  readonly preview: BobCommitPreview
}> {
  confirmation(args.input)
  const config = await loadConsoleRuntimeConfig(args.configPath, 'bob')
  return withWorkspaceMutation(args.workspace, async () => {
    const expected = {
      party: 'bob' as const,
      networkId: config.identity.networkId,
      configDigest: config.identity.digest,
    }
    const restored = await restoreWorkspaceWorkflowState(args.workspace, expected)
    if (restored.publicState.party !== 'bob' || (restored.publicState.stage !== 'bob-enabled' && restored.publicState.stage !== 'bob-commit-pending') || !restored.publicState.progression.observed || restored.secretState.bobCommitSecret === undefined) throw new Error(`Bob commit prerequisites are not met in ${resolve(args.workspace)}: party=${restored.publicState.party}, stage=${restored.publicState.stage}, progressionObserved=${restored.publicState.party === 'bob' ? restored.publicState.progression.observed : false}, onChainPreimageAvailable=${restored.secretState.bobCommitSecret !== undefined}. Run observe-alice-commit after Alice's commit reaches the configured finality threshold.`)
    const acceptance = object(JSON.parse(await readFile(join(resolve(args.workspace), 'journal', 'acceptance.json'), 'utf8')), 'trade acceptance')
    if (acceptance['schema'] !== TRADE_ACCEPTANCE_SCHEMA || acceptance['networkId'] !== config.identity.networkId || acceptance['tradeId'] !== restored.publicState.tradeId || typeof acceptance['bob'] !== 'string' || acceptance['bob'].toLowerCase() !== config.actors.bob.toLowerCase()) throw new Error("Bob's local acceptance does not match this trade")
    const offer = parseConsoleOffer(await readFile(join(resolve(args.workspace), 'public', 'offer.json'), 'utf8'))
    const boundary = args.boundary ?? createLocalBobCommitBoundary(config)
    const view = preview(config, restored.terms, offer.authorizationEvidence.counterpartyExpiry, await boundary.predictHTLC(restored.terms, restored.publicState.derived.settlementLock))
    args.onPreview?.(view)
    const existing = await journal(args.workspace)
    if (existing !== undefined) {
      const lifecycle = await boundary.transaction(existing.transactionHash)
      if (lifecycle === 'reverted' || lifecycle === 'missing') throw new Error(`recorded Bob commit is ${lifecycle}; observe or recover before resending`)
      await publishReference(config, existing)
      if (restored.publicState.stage === 'bob-enabled') {
        const next = applyPartyCommand(restored.publicState, restored.secretState, { command: 'mark-bob-commit-pending' })
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
      }
      return {
        tradeId: restored.publicState.tradeId,
        transactionHash: existing.transactionHash,
        lifecycle,
        reused: true,
        preview: view,
      }
    }
    if (restored.publicState.stage !== 'bob-enabled') throw new Error('Bob commit is pending without a transaction journal; refusing resend')
    if ((await boundary.state(restored.terms, restored.publicState.derived.settlementLock)) !== CrossChainLegState.Unused) throw new Error('Bob leg is already used on-chain without a tracked transaction; refusing resend')
    const expiry = BigInt(offer.authorizationEvidence.counterpartyExpiry)
    const payloadHash = commitPayloadHash({
      terms: restored.terms,
      party: false,
      authorizationVerifier: config.chains[1].verifier,
      swapAddress: config.chains[1].wrapper,
      lock: restored.publicState.derived.settlementLock,
      expectedSourceState: ExpectedSourceState.Unused,
      actionNonce: offer.authorizationEvidence.counterpartyActionNonce,
      expiry,
    })
    if (payloadHash !== restored.publicState.derived.counterpartyCommitPayloadHash) throw new Error('Bob commit authorization hash mismatch')
    const submitted = await boundary.submit({
      terms: restored.terms,
      lock: restored.publicState.derived.settlementLock,
      actionNonce: offer.authorizationEvidence.counterpartyActionNonce,
      expiry,
      payloadHash,
      bobCommitSecret: restored.secretState.bobCommitSecret,
    })
    const reference: BobReference = {
      networkId: config.identity.networkId,
      tradeId: restored.publicState.tradeId,
      chainId: 31338,
      wrapper: config.chains[1].wrapper,
      transactionHash: submitted.hash,
      sender: config.actors.bob,
      nonce: submitted.nonce,
      submittedAtBlock: submitted.submittedAtBlock.toString(),
    }
    await writeLockedWorkspaceJournal(args.workspace, 'bob-commit', `${JSON.stringify({ ...reference, schema: JOURNAL_SCHEMA, action: 'bob-commit' }, null, 2)}\n`)
    await publishReference(config, reference)
    const next = applyPartyCommand(restored.publicState, restored.secretState, {
      command: 'mark-bob-commit-pending',
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
      transactionHash: submitted.hash,
      lifecycle: 'pending',
      reused: false,
      preview: view,
    }
  })
}

async function replacement(
  publicClient: PublicClient,
  reference: BobReference,
  head: bigint,
): Promise<{
  readonly lifecycle: 'replaced' | 'dropped'
  readonly replacementHash?: Hash
}> {
  if (
    (await publicClient.getTransactionCount({
      address: reference.sender,
      blockTag: 'latest',
    })) <= reference.nonce
  )
    return { lifecycle: 'dropped' }
  const first = BigInt(reference.submittedAtBlock)
  const scanFrom = head - first > 512n ? head - 512n : first
  for (let number = scanFrom; number <= head; number += 1n) {
    const block = await publicClient.getBlock({
      blockNumber: number,
      includeTransactions: true,
    })
    const found = (block.transactions as Transaction[]).find((tx) => tx.from.toLowerCase() === reference.sender.toLowerCase() && tx.nonce === reference.nonce && tx.hash !== reference.transactionHash)
    if (found !== undefined) return { lifecycle: 'replaced', replacementHash: found.hash }
  }
  return { lifecycle: 'replaced' }
}
export function createLocalBobObservationBoundary(config: ConsoleRuntimeConfig): BobCommitObservationBoundary {
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
  const addresses = route.addresses as unknown as Parameters<typeof createProtocolClient>[0]['addresses']
  const client = createProtocolClient({ addresses, publicClient })
  return {
    inspect: async ({ reference, terms, lock, principal }) => {
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
          return { lifecycle: 'pending', observedHead: head.toString() }
        } catch {
          return {
            ...(await replacement(publicClient, reference, head)),
            observedHead: head.toString(),
          }
        }
      }
      if (receipt.status !== 'success') return { lifecycle: 'reverted', observedHead: head.toString() }
      if (receipt.blockHash === null) throw new Error('Bob commit receipt lacks block hash')
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
          inclusion,
        }
      const valid = receipt.logs
        .filter((log) => log.address.toLowerCase() === reference.wrapper.toLowerCase())
        .filter((log) => {
          try {
            const event = decodeEventLog({
              abi: crossChainWrapperAbi,
              data: log.data,
              topics: log.topics,
              strict: true,
            })
            const values = event.args as unknown as Record<string, unknown>
            return event.eventName === 'Committed' && values['tradeId'] === reference.tradeId && values['lock'] === lock && values['side'] === 1 && typeof values['principal'] === 'string' && values['principal'].toLowerCase() === principal.toLowerCase()
          } catch {
            return false
          }
        })
      if (valid.length !== 1) throw new Error('Bob transaction lacks one exact authenticated Committed event')
      if ((await client.getCrossChainState(terms, false, lock)) !== CrossChainLegState.Committed) throw new Error('Bob committed event disagrees with wrapper state')
      return {
        lifecycle: 'committed',
        observedHead: head.toString(),
        inclusion,
      }
    },
  }
}

export async function observeBobCommit(args: { readonly workspace: string; readonly configPath: string; readonly boundary?: BobCommitObservationBoundary }): Promise<BobCommitObservation> {
  const identity = await loadConsoleConfigIdentity(args.configPath)
  const config = await loadConsoleRuntimeConfig(args.configPath, identity.localParty)
  return withWorkspaceMutation(args.workspace, async () => {
    const expected = {
      party: identity.localParty,
      networkId: identity.networkId,
      configDigest: identity.digest,
    }
    const restored = await restoreWorkspaceWorkflowState(args.workspace, expected)
    const path = identity.localParty === 'bob' ? join(resolve(args.workspace), 'journal', 'bob-commit.json') : join(resolve(config.exchangeDirectory), `bob-commit-${restored.publicState.tradeId.slice(2)}.json`)
    const reference = await readObservationReference(path, identity.localParty)
    if (reference.networkId !== identity.networkId || reference.tradeId !== restored.publicState.tradeId || reference.wrapper.toLowerCase() !== config.chains[1].wrapper.toLowerCase() || reference.sender.toLowerCase() !== config.actors.bob.toLowerCase()) throw new Error('Bob commit reference binding mismatch')
    const observed = await (args.boundary ?? createLocalBobObservationBoundary(config)).inspect({
      reference,
      terms: restored.terms,
      lock: restored.publicState.derived.settlementLock,
      principal: config.actors.bob,
    })
    const committed = observed.lifecycle === 'committed'
    const result: BobCommitObservation = {
      schema: BOB_COMMIT_OBSERVATION_SCHEMA,
      networkId: identity.networkId,
      tradeId: restored.publicState.tradeId,
      chainId: 31338,
      wrapper: config.chains[1].wrapper,
      transactionHash: reference.transactionHash,
      ...observed,
      aliceClaimEnabled: committed,
      ...(!committed
        ? {
            warning: `Bob commit is ${observed.lifecycle}; Alice's revealing claim remains disabled.`,
          }
        : {}),
    }
    const next = applyPartyCommand(restored.publicState, restored.secretState, {
      command: committed ? 'mark-bob-committed' : 'mark-bob-commit-pending',
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
        'bob-commit-observation.json': `${JSON.stringify(result, null, 2)}\n`,
      },
    })
    return result
  })
}
