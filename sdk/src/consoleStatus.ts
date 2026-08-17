import {createPublicClient, defineChain, http} from 'viem'
import type {Address, PublicClient} from 'viem'
import {erc20Abi} from 'viem'
import {restoreProtocolTerms} from './clientState.js'
import type {ClientState} from './clientState.js'
import {loadConsoleRuntimeConfig} from './consoleTrade.js'
import type {ConsoleRuntimeConfig} from './consoleTrade.js'
import {loadConsoleConfigIdentity, restoreWorkspaceWorkflowState} from './consoleWorkspace.js'
import {createProtocolClient} from './protocolClient.js'
import {CrossChainLegState} from './protocol.js'
import type {ProtocolTerms, SideTerms} from './protocol.js'
import {AssetType} from './types.js'
import type {Hex32} from './types.js'

export const CONSOLE_STATUS_SCHEMA = 'quip-swap-console-status.v1' as const

const stateName = ['Unused', 'Committed', 'Claimed', 'Reclaimed'] as const
export type ConsoleLegState = (typeof stateName)[number]

export interface ConsoleBalance {
  readonly token: Address
  readonly account: Address
  readonly role: 'principal' | 'wrapper' | 'recipient' | 'reclaim-recipient'
  readonly amount: string
}

export interface ConsoleLegStatus {
  readonly chainId: number
  readonly wrapper: Address
  readonly state: ConsoleLegState
  readonly custody: 'principal' | 'wrapper' | 'recipient' | 'reclaim-recipient'
  readonly payoutVerified: boolean
  readonly timestamp: string
  readonly claimDeadline: string
  readonly reclaimRelease: string
  readonly deadlineRisk: 'none' | 'claim-window-open' | 'claim-deadline-passed' | 'reclaim-window-open'
  readonly balances: readonly ConsoleBalance[]
}

export interface ConsoleStatusReport {
  readonly schema: typeof CONSOLE_STATUS_SCHEMA
  readonly tradeId: ClientState['tradeId']
  readonly party: ClientState['party']
  readonly persistedStage: ClientState['stage']
  readonly outcome: 'in-progress' | 'success' | 'reclaimed' | 'mixed-terminal'
  readonly complete: boolean
  readonly completedActions: readonly string[]
  readonly warnings: readonly string[]
  readonly enabledActions: readonly string[]
  readonly responsibleParty: 'alice' | 'bob' | 'permissionless-executor' | 'none'
  readonly nextCommand: string | null
  readonly legs: readonly [ConsoleLegStatus, ConsoleLegStatus]
}

export interface ConsoleStatusBoundary {
  readonly inspect: (args: {readonly terms: ProtocolTerms; readonly lock: Hex32}) => Promise<readonly [ConsoleLegStatus, ConsoleLegStatus]>
}

function risk(side: SideTerms, state: CrossChainLegState, now: bigint): ConsoleLegStatus['deadlineRisk'] {
  if (state !== CrossChainLegState.Committed) return 'none'
  if (now >= side.reclaimRelease) return 'reclaim-window-open'
  if (now > side.claimDeadline) return 'claim-deadline-passed'
  return 'claim-window-open'
}

function custody(state: CrossChainLegState): ConsoleLegStatus['custody'] {
  if (state === CrossChainLegState.Committed) return 'wrapper'
  if (state === CrossChainLegState.Claimed) return 'recipient'
  if (state === CrossChainLegState.Reclaimed) return 'reclaim-recipient'
  return 'principal'
}

export function createLocalConsoleStatusBoundary(config: ConsoleRuntimeConfig): ConsoleStatusBoundary {
  const clients = config.chains.map(route => {
    const chain = defineChain({id: route.chainId, name: `anvil-${route.chainId}`, nativeCurrency: {name: 'Ether', symbol: 'ETH', decimals: 18}, rpcUrls: {default: {http: [route.rpcUrl]}}})
    const publicClient = createPublicClient({chain, transport: http(route.rpcUrl)}) as PublicClient
    const protocol = createProtocolClient({addresses: route.addresses as never, publicClient})
    return {route, publicClient, protocol}
  })
  return {inspect: async ({terms, lock}) => {
    const inspect = async (index: 0 | 1, party: boolean) => {
      const {route, publicClient, protocol} = clients[index]!
      const side = party ? terms.partySide : terms.counterpartySide
      const [state, block] = await Promise.all([protocol.getCrossChainState(terms, party, lock as never), publicClient.getBlock()])
      const accounts = [['principal', side.principal], ['wrapper', route.wrapper], ['recipient', side.recipient], ['reclaim-recipient', side.reclaimRecipient]] as const
      const balances: ConsoleBalance[] = []
      for (const asset of side.assets) {
        if (asset.assetType !== AssetType.ERC20) throw new Error('prototype status currently supports ERC-20 trade assets only')
        for (const [role, account] of accounts) balances.push({token: asset.target, account, role, amount: (await publicClient.readContract({address: asset.target, abi: erc20Abi, functionName: 'balanceOf', args: [account]})).toString()})
      }
      return {chainId: route.chainId, wrapper: route.wrapper, state: stateName[state], custody: custody(state), payoutVerified: state === CrossChainLegState.Claimed || state === CrossChainLegState.Reclaimed, timestamp: block.timestamp.toString(), claimDeadline: side.claimDeadline.toString(), reclaimRelease: side.reclaimRelease.toString(), deadlineRisk: risk(side, state, block.timestamp), balances} satisfies ConsoleLegStatus
    }
    return [await inspect(0, true), await inspect(1, false)]
  }}
}

function guidance(state: ClientState, legs: readonly [ConsoleLegStatus, ConsoleLegStatus]): Pick<ConsoleStatusReport, 'enabledActions' | 'responsibleParty' | 'nextCommand'> {
  const command = (name: string, party: 'alice' | 'bob') => `quip-swap ${name} --party ${party} --state-root <${party}-workspace> --config <${party}-config>`
  if (legs.every(leg => (leg.state === 'Claimed' || leg.state === 'Reclaimed') && leg.payoutVerified)) return {enabledActions: [], responsibleParty: 'none', nextCommand: null}
  if (legs.some(leg => leg.deadlineRisk === 'reclaim-window-open' && (leg.state === 'Unused' || leg.state === 'Committed'))) return {enabledActions: ['reclaim'], responsibleParty: 'permissionless-executor', nextCommand: command('reclaim', state.party)}
  if (state.recovery.active) return {enabledActions: [], responsibleParty: 'none', nextCommand: null}
  if (state.party === 'alice') {
    if (state.aliceCommit.status !== 'final') return {enabledActions: ['observe-alice-commit'], responsibleParty: 'alice', nextCommand: command('observe-alice-commit', 'alice')}
    if (!state.progression.published) return {enabledActions: ['observe-alice-commit'], responsibleParty: 'alice', nextCommand: command('observe-alice-commit', 'alice')}
    if (legs[1].state === 'Committed') return {enabledActions: ['submit-revealing-claim'], responsibleParty: 'alice', nextCommand: command('submit-revealing-claim', 'alice')}
    if (legs[1].state === 'Unused') return {enabledActions: ['observe-bob-commit'], responsibleParty: 'alice', nextCommand: command('observe-bob-commit', 'alice')}
  } else {
    if (state.aliceCommit.status !== 'final') return {enabledActions: ['observe-alice-commit'], responsibleParty: 'bob', nextCommand: command('observe-alice-commit', 'bob')}
    if (!state.progression.observed) return {enabledActions: ['observe-alice-commit'], responsibleParty: 'bob', nextCommand: command('observe-alice-commit', 'bob')}
    if (legs[1].state === 'Unused') return {enabledActions: ['submit-bob-commit'], responsibleParty: 'bob', nextCommand: command('submit-bob-commit', 'bob')}
    if (legs[1].state === 'Committed') return {enabledActions: ['observe-reveal'], responsibleParty: 'bob', nextCommand: command('observe-reveal', 'bob')}
    if (legs[1].state === 'Claimed' && legs[0].state === 'Committed') return {enabledActions: ['submit-final-claim'], responsibleParty: 'bob', nextCommand: command('submit-final-claim', 'bob')}
  }
  return {enabledActions: [], responsibleParty: 'none', nextCommand: null}
}

export async function getConsoleStatus(args: {readonly workspace: string; readonly configPath: string; readonly boundary?: ConsoleStatusBoundary}): Promise<ConsoleStatusReport> {
  const identity = await loadConsoleConfigIdentity(args.configPath)
  const config = await loadConsoleRuntimeConfig(args.configPath, identity.localParty)
  const restored = await restoreWorkspaceWorkflowState(args.workspace, {party: config.identity.localParty, networkId: config.identity.networkId, configDigest: config.identity.digest})
  const terms = restoreProtocolTerms(restored.publicState.terms)
  const legs = await (args.boundary ?? createLocalConsoleStatusBoundary(config)).inspect({terms, lock: restored.publicState.derived.settlementLock})
  const terminal = legs.every(leg => leg.state === 'Claimed' || leg.state === 'Reclaimed') && legs.every(leg => leg.payoutVerified)
  const outcome = !terminal ? 'in-progress' : legs.every(leg => leg.state === 'Claimed') ? 'success' : legs.every(leg => leg.state === 'Reclaimed') ? 'reclaimed' : 'mixed-terminal'
  const warnings = [...(legs[0].state !== legs[1].state ? [`Asymmetric on-chain states: ${legs[0].state}/${legs[1].state}.`] : []), ...legs.filter(leg => leg.deadlineRisk !== 'none').map(leg => `Chain ${leg.chainId}: ${leg.deadlineRisk}.`), ...(restored.publicState.recovery.active ? [restored.publicState.recovery.reason ?? 'Recovery mode is active.'] : [])]
  const completedActions = [restored.publicState.aliceCommit.status === 'final' ? 'alice-commit-final' : null, legs[1].state !== 'Unused' ? 'bob-commit' : null, legs[1].state === 'Claimed' ? 'revealing-claim' : null, legs[0].state === 'Claimed' ? 'final-claim' : null].filter((value): value is string => value !== null)
  return {schema: CONSOLE_STATUS_SCHEMA, tradeId: restored.publicState.tradeId, party: restored.publicState.party, persistedStage: restored.publicState.stage, outcome, complete: terminal, completedActions, warnings, ...guidance(restored.publicState, legs), legs}
}
