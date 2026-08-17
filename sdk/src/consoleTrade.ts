import {readFile} from 'node:fs/promises'
import type {Address} from 'viem'
import {AssetType} from './types.js'
import type {Hex32} from './types.js'
import {prepareTradeCommand} from './cliCommands.js'
import type {PreparedAuthorization} from './workflows/trustedCrossChain.js'
import {AuthorizationMode, DelegationPolicy, ExpectedSourceState, WrapperMode, commitPayloadHash, gateContextId, timingPolicyId, tradeId, validateProtocolTerms} from './protocol.js'
import type {ProtocolTerms, SideTerms, TimingPolicy} from './protocol.js'
import {restoreProtocolTerms, validateClientState} from './clientState.js'
import type {BobClientState} from './clientState.js'
import {SECRET_STATE_SCHEMA} from './clientPersistence.js'
import type {BobSecretState} from './clientPersistence.js'
import {acceptWorkspaceTrade, loadConsoleConfigIdentity, restoreWorkspaceWorkflowState, saveWorkspaceWorkflowState} from './consoleWorkspace.js'

export const PREPARE_TRADE_INPUT_SCHEMA = 'quip-swap-prepare-trade.v1' as const
export const PUBLIC_OFFER_SCHEMA = 'quip-swap-public-offer.v1' as const
export const TRADE_ACCEPTANCE_SCHEMA = 'quip-swap-trade-acceptance.v1' as const
const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000' as Address
const HEX32 = /^0x[0-9a-fA-F]{64}$/

interface PrepareInput {
  readonly schema: typeof PREPARE_TRADE_INPUT_SCHEMA
  readonly partyCommitmentDeadline: string
  readonly counterpartyCommitmentDeadline: string
  readonly partyClaimDeadline: string
  readonly counterpartyClaimDeadline: string
  readonly partyReclaimRelease: string
  readonly counterpartyReclaimRelease: string
  readonly partyAuthorizationExpiry: string
  readonly counterpartyAuthorizationExpiry: string
}

export interface ConsoleRuntimeConfig {
  readonly identity: Awaited<ReturnType<typeof loadConsoleConfigIdentity>>
  readonly requiredConfirmations: bigint
  readonly policy: TimingPolicy
  readonly actors: {readonly alice: Address; readonly bob: Address; readonly executor: Address}
  readonly chains: readonly [{readonly chainId: 31337; readonly rpcUrl: string; readonly token: Address; readonly amount: bigint; readonly verifier: Address; readonly wrapper: Address; readonly trustedVerifier: Address; readonly addresses: Record<string, Address>}, {readonly chainId: 31338; readonly rpcUrl: string; readonly token: Address; readonly amount: bigint; readonly verifier: Address; readonly wrapper: Address; readonly trustedVerifier: Address; readonly addresses: Record<string, Address>}]
}

export interface PublicTradeOffer {
  readonly schema: typeof PUBLIC_OFFER_SCHEMA
  readonly networkId: string
  readonly tradeId: Hex32
  readonly bobState: BobClientState
  readonly authorizationEvidence: {
    readonly partyActionNonce: Hex32
    readonly counterpartyActionNonce: Hex32
    readonly partyExpiry: string
    readonly counterpartyExpiry: string
  }
}

function record(value: unknown, label: string): Record<string, unknown> {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) throw new Error(`${label} must be an object`)
  return value as Record<string, unknown>
}
function decimal(value: unknown, label: string): bigint {
  if (typeof value !== 'string' || !/^(0|[1-9][0-9]*)$/.test(value)) throw new Error(`${label} must be decimal`)
  return BigInt(value)
}
function address(value: unknown, label: string): Address {
  if (typeof value !== 'string' || !/^0x[0-9a-fA-F]{40}$/.test(value)) throw new Error(`${label} must be an address`)
  return value as Address
}

export async function loadConsoleRuntimeConfig(path: string, party: 'alice' | 'bob'): Promise<ConsoleRuntimeConfig> {
  const identity = await loadConsoleConfigIdentity(path)
  if (identity.localParty !== party) throw new Error('console configuration belongs to the other party')
  const value = record(JSON.parse(await readFile(path, 'utf8')), 'console config')
  const timing = record(value['timingPolicy'], 'timing policy')
  const policy: TimingPolicy = {policyVersion: decimal(timing['policyVersion'], 'policyVersion'), mode: WrapperMode.CrossChain, partyChainId: decimal(timing['partyChainId'], 'partyChainId'), counterpartyChainId: decimal(timing['counterpartyChainId'], 'counterpartyChainId'), partyToCounterpartyDelay: decimal(timing['partyToCounterpartyDelay'], 'partyToCounterpartyDelay'), counterpartyToPartyDelay: decimal(timing['counterpartyToPartyDelay'], 'counterpartyToPartyDelay')}
  if (timingPolicyId(policy) !== timing['timingPolicyId']) throw new Error('console timing-policy identifier mismatch')
  const actors = record(value['actors'], 'actors')
  const deployment = record(value['deployment'], 'deployment')
  const deployedChains = deployment['chains'] as unknown[]
  const configuredChains = value['chains'] as unknown[]
  const chain = (index: 0 | 1) => {
    const deployed = record(deployedChains[index], `deployment chain ${index}`)
    const addresses = record(deployed['addresses'], 'deployment addresses')
    const funding = record(deployed['funding'], 'deployment funding')
    const configured = record(configuredChains[index], `configured chain ${index}`)
    const protocolAddresses = Object.fromEntries(['assetSupportRegistry', 'timingPolicyRegistry', 'identityRegistry', 'authorizationGateway', 'crossChainWrapper', 'sameChainWrapper'].map(field => [field, address(addresses[field], field)])) as Record<string, Address>
    return {chainId: (index === 0 ? 31337 : 31338), rpcUrl: String(configured['rpcUrl']), token: address(funding['token'], 'funding token'), amount: decimal(funding['amount'], 'funding amount'), verifier: protocolAddresses['authorizationGateway']!, wrapper: protocolAddresses['crossChainWrapper']!, trustedVerifier: address(deployed['trustedVerifier'], 'trusted verifier'), addresses: protocolAddresses}
  }
  return {identity, requiredConfirmations: BigInt(value['requiredConfirmations'] as number), policy, actors: {alice: address(actors['alice'], 'Alice'), bob: address(actors['bob'], 'Bob'), executor: address(actors['permissionlessExecutor'], 'executor')}, chains: [chain(0) as ConsoleRuntimeConfig['chains'][0], chain(1) as ConsoleRuntimeConfig['chains'][1]]}
}

function parsePrepareInput(serialized: string): PrepareInput {
  if (/settlementSecret|bobCommitSecret|privateKey|signature/i.test(serialized)) throw new Error('prepare input contains forbidden secret or authorization material')
  const value = record(JSON.parse(serialized), 'prepare input')
  if (value['schema'] !== PREPARE_TRADE_INPUT_SCHEMA) throw new Error('unsupported prepare-trade input schema')
  for (const field of ['partyCommitmentDeadline', 'counterpartyCommitmentDeadline', 'partyClaimDeadline', 'counterpartyClaimDeadline', 'partyReclaimRelease', 'counterpartyReclaimRelease', 'partyAuthorizationExpiry', 'counterpartyAuthorizationExpiry']) decimal(value[field], field)
  return value as unknown as PrepareInput
}

function side(args: {chainId: bigint; token: Address; amount: bigint; principal: Address; recipient: Address; commitment: bigint; claim: bigint; reclaim: bigint}): Omit<SideTerms, 'commitLock' | 'sideNonce'> {
  return {chainId: args.chainId, assets: [{assetType: AssetType.ERC20, target: args.token, id: 0n, amount: args.amount}], principal: args.principal, authorizationMode: AuthorizationMode.RegisteredDirect, principalKeyVersion: 1n, reclaimRecipient: args.principal, recipient: args.recipient, commitmentDeadline: args.commitment, claimDeadline: args.claim, reclaimRelease: args.reclaim, delegationPolicy: DelegationPolicy.NotAllowed, delegate: ZERO_ADDRESS, delegateKeyVersion: 0n}
}

const expected = (config: ConsoleRuntimeConfig) => ({party: config.identity.localParty, networkId: config.identity.networkId, configDigest: config.identity.digest} as const)

export async function prepareConsoleTrade(args: {readonly workspace: string; readonly configPath: string; readonly input: string}): Promise<PublicTradeOffer> {
  const config = await loadConsoleRuntimeConfig(args.configPath, 'alice')
  const input = parsePrepareInput(args.input)
  const prepared = prepareTradeCommand({workflow: {policy: config.policy, partySide: side({chainId: 31337n, token: config.chains[0].token, amount: config.chains[0].amount, principal: config.actors.alice, recipient: config.actors.bob, commitment: decimal(input.partyCommitmentDeadline, 'partyCommitmentDeadline'), claim: decimal(input.partyClaimDeadline, 'partyClaimDeadline'), reclaim: decimal(input.partyReclaimRelease, 'partyReclaimRelease')}), counterpartySide: side({chainId: 31338n, token: config.chains[1].token, amount: config.chains[1].amount, principal: config.actors.bob, recipient: config.actors.alice, commitment: decimal(input.counterpartyCommitmentDeadline, 'counterpartyCommitmentDeadline'), claim: decimal(input.counterpartyClaimDeadline, 'counterpartyClaimDeadline'), reclaim: decimal(input.counterpartyReclaimRelease, 'counterpartyReclaimRelease')}), partyVerifier: config.chains[0].verifier, counterpartyVerifier: config.chains[1].verifier, partyWrapper: config.chains[0].wrapper, counterpartyWrapper: config.chains[1].wrapper, partyExpiry: decimal(input.partyAuthorizationExpiry, 'partyAuthorizationExpiry'), counterpartyExpiry: decimal(input.counterpartyAuthorizationExpiry, 'counterpartyAuthorizationExpiry'), requiredConfirmations: config.requiredConfirmations, selectedBobSubmitter: config.actors.bob}, finalClaimExecutors: [config.actors.executor]})
  const offer: PublicTradeOffer = {schema: PUBLIC_OFFER_SCHEMA, networkId: config.identity.networkId, tradeId: prepared.alice.publicState.tradeId, bobState: prepared.bob.publicState, authorizationEvidence: prepared.authorizationEvidence}
  const serialized = `${JSON.stringify(offer, null, 2)}\n`
  if (/settlementSecret|bobCommitSecret|privateKey|signature/i.test(serialized)) throw new Error('public offer contains sensitive material')
  await saveWorkspaceWorkflowState({root: args.workspace, expected: expected(config), publicState: prepared.alice.publicState, secretState: prepared.alice.secretState, publicArtifacts: {'offer.json': serialized}})
  return offer
}

function authorization(terms: ProtocolTerms, party: boolean, config: ConsoleRuntimeConfig, lock: Hex32, nonce: Hex32, expiry: bigint): PreparedAuthorization {
  const index = party ? 0 : 1
  const payload = {terms, party, authorizationVerifier: config.chains[index].verifier, swapAddress: config.chains[index].wrapper, lock, expectedSourceState: ExpectedSourceState.Unused, actionNonce: nonce, expiry}
  return {payload, payloadHash: commitPayloadHash(payload)}
}

export function parseConsoleOffer(serialized: string): PublicTradeOffer {
  if (/settlementSecret|bobCommitSecret|privateKey|signature/i.test(serialized)) throw new Error('offer contains forbidden sensitive material')
  const value = record(JSON.parse(serialized), 'public offer')
  if (value['schema'] !== PUBLIC_OFFER_SCHEMA || typeof value['networkId'] !== 'string' || typeof value['tradeId'] !== 'string' || !HEX32.test(value['tradeId'])) throw new Error('invalid public offer envelope')
  validateClientState(value['bobState'])
  const evidence = record(value['authorizationEvidence'], 'authorization evidence')
  for (const field of ['partyActionNonce', 'counterpartyActionNonce']) if (typeof evidence[field] !== 'string' || !HEX32.test(evidence[field])) throw new Error(`invalid ${field}`)
  decimal(evidence['partyExpiry'], 'partyExpiry'); decimal(evidence['counterpartyExpiry'], 'counterpartyExpiry')
  return value as unknown as PublicTradeOffer
}

export async function importConsoleOffer(args: {readonly workspace: string; readonly configPath: string; readonly input: string}): Promise<PublicTradeOffer> {
  const config = await loadConsoleRuntimeConfig(args.configPath, 'bob')
  const offer = parseConsoleOffer(args.input)
  if (offer.networkId !== config.identity.networkId || offer.bobState.party !== 'bob' || offer.tradeId !== offer.bobState.tradeId || offer.bobState.stage !== 'prepared' || offer.bobState.generation !== 1 || offer.bobState.sequence !== 1 || offer.bobState.progression.received) throw new Error('offer state envelope mismatch')
  const terms = restoreProtocolTerms(offer.bobState.terms)
  validateProtocolTerms(terms, config.policy)
  if (tradeId(terms) !== offer.tradeId || gateContextId(terms) !== offer.bobState.derived.gateContextId) throw new Error('offer protocol hash mismatch')
  const partyAuth = authorization(terms, true, config, offer.bobState.derived.settlementLock, offer.authorizationEvidence.partyActionNonce, decimal(offer.authorizationEvidence.partyExpiry, 'partyExpiry'))
  const counterAuth = authorization(terms, false, config, offer.bobState.derived.settlementLock, offer.authorizationEvidence.counterpartyActionNonce, decimal(offer.authorizationEvidence.counterpartyExpiry, 'counterpartyExpiry'))
  if (partyAuth.payloadHash !== offer.bobState.derived.partyCommitPayloadHash || counterAuth.payloadHash !== offer.bobState.derived.counterpartyCommitPayloadHash) throw new Error('offer commit authorization hash mismatch')
  const [party, counterparty] = [terms.partySide, terms.counterpartySide]
  if (party.principal.toLowerCase() !== config.actors.alice.toLowerCase() || counterparty.principal.toLowerCase() !== config.actors.bob.toLowerCase() || party.recipient.toLowerCase() !== config.actors.bob.toLowerCase() || counterparty.recipient.toLowerCase() !== config.actors.alice.toLowerCase()) throw new Error('offer actor binding mismatch')
  if (party.assets.length !== 1 || counterparty.assets.length !== 1 || party.assets[0]?.target.toLowerCase() !== config.chains[0].token.toLowerCase() || counterparty.assets[0]?.target.toLowerCase() !== config.chains[1].token.toLowerCase() || party.assets[0]?.amount !== config.chains[0].amount || counterparty.assets[0]?.amount !== config.chains[1].amount) throw new Error('offer asset binding mismatch')
  if (offer.bobState.selected.bobSubmitter.toLowerCase() !== config.actors.bob.toLowerCase() || offer.bobState.selected.finalClaimExecutors.length !== 1 || offer.bobState.selected.finalClaimExecutors[0]?.toLowerCase() !== config.actors.executor.toLowerCase()) throw new Error('offer executor binding mismatch')
  const secretState: BobSecretState = {schema: SECRET_STATE_SCHEMA, party: 'bob', generation: 1, tradeId: offer.tradeId, mode: 'prototype-local', publicTestSecrets: false}
  await saveWorkspaceWorkflowState({root: args.workspace, expected: expected(config), publicState: offer.bobState, secretState, publicArtifacts: {'offer.json': `${JSON.stringify(offer, null, 2)}\n`}})
  return offer
}

export async function acceptConsoleTrade(args: {readonly workspace: string; readonly configPath: string}): Promise<{readonly schema: typeof TRADE_ACCEPTANCE_SCHEMA; readonly networkId: string; readonly tradeId: Hex32; readonly bob: Address}> {
  const config = await loadConsoleRuntimeConfig(args.configPath, 'bob')
  const restored = await restoreWorkspaceWorkflowState(args.workspace, expected(config))
  if (restored.publicState.party !== 'bob') throw new Error('accept-trade requires Bob state')
  const acceptance = {schema: TRADE_ACCEPTANCE_SCHEMA, networkId: config.identity.networkId, tradeId: restored.publicState.tradeId, bob: config.actors.bob}
  await acceptWorkspaceTrade({root: args.workspace, expected: {...expected(config), tradeId: restored.publicState.tradeId, generation: restored.publicState.generation}, acceptance: `${JSON.stringify(acceptance, null, 2)}\n`})
  return acceptance
}
