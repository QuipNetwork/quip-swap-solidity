import {mkdir, open, readFile, rename} from 'node:fs/promises'
import {join} from 'node:path'
import {
  parseClientState,
  restoreProtocolTerms,
  serializeClientState,
  validateClientState,
} from './clientState.js'
import type {ClientState} from './clientState.js'
import {deriveCommitLock, gateContextId, settlementLock, tradeId} from './protocol.js'
import type {ProtocolTerms} from './protocol.js'
import type {Hex32} from './types.js'

export const SECRET_STATE_SCHEMA = 'quip-swap-secret-state.v1' as const
export type SecretStateMode = 'prototype-local' | 'unsafe-demo'

interface SecretStateBase {
  readonly schema: typeof SECRET_STATE_SCHEMA
  readonly party: 'alice' | 'bob'
  readonly generation: number
  readonly tradeId: Hex32
  readonly mode: SecretStateMode
  readonly publicTestSecrets: boolean
}

export interface AliceSecretState extends SecretStateBase {
  readonly party: 'alice'
  readonly settlementSecret: Hex32
  readonly bobCommitSecret: Hex32
}

export interface BobSecretState extends SecretStateBase {
  readonly party: 'bob'
  readonly bobCommitSecret?: Hex32
  readonly settlementSecret?: Hex32
}

export type PartySecretState = AliceSecretState | BobSecretState

export interface RestoredPartyWorkflowState {
  readonly publicState: ClientState
  readonly secretState: PartySecretState
  readonly terms: ProtocolTerms
}

const HEX32 = /^0x[0-9a-fA-F]{64}$/
const generationName = (generation: number): string => generation.toString(10).padStart(12, '0')

export function validateSecretState(value: unknown): asserts value is PartySecretState {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) throw new Error('secret state must be an object')
  const state = value as Record<string, unknown>
  if (state['schema'] !== SECRET_STATE_SCHEMA) throw new Error('unsupported secret state schema')
  if (state['party'] !== 'alice' && state['party'] !== 'bob') throw new Error('invalid secret-state party')
  if (!Number.isSafeInteger(state['generation']) || (state['generation'] as number) < 0) {
    throw new Error('invalid secret-state generation')
  }
  if (typeof state['tradeId'] !== 'string' || !HEX32.test(state['tradeId'])) throw new Error('invalid secret-state TradeID')
  if (state['mode'] !== 'prototype-local' && state['mode'] !== 'unsafe-demo') throw new Error('invalid secret-state mode')
  if (state['publicTestSecrets'] !== (state['mode'] === 'unsafe-demo')) throw new Error('invalid public-test-secret marker')
  for (const field of ['settlementSecret', 'bobCommitSecret']) {
    if (state[field] !== undefined && (typeof state[field] !== 'string' || !HEX32.test(state[field] as string))) {
      throw new Error(`invalid ${field}`)
    }
  }
  if (state['party'] === 'alice' && (state['settlementSecret'] === undefined || state['bobCommitSecret'] === undefined)) {
    throw new Error('Alice secret state requires both preimages')
  }
}

function validateDemoMode(publicState: ClientState, secretState: PartySecretState): void {
  if (secretState.mode !== 'unsafe-demo') return
  const ids = [publicState.terms.partySide.chainId, publicState.terms.counterpartySide.chainId]
  if (!(ids.includes('31337') && ids.includes('31338'))) {
    throw new Error('unsafe demo secrets are restricted to local chain IDs 31337 and 31338')
  }
}

export function validatePartyWorkflowState(
  publicState: ClientState,
  secretState: PartySecretState,
): RestoredPartyWorkflowState {
  validateClientState(publicState)
  validateSecretState(secretState)
  if (publicState.party !== secretState.party) throw new Error('party state boundary mismatch')
  if (publicState.generation !== secretState.generation) throw new Error('state generation mismatch')
  if (publicState.tradeId !== secretState.tradeId) throw new Error('secret-state TradeID mismatch')
  const terms = restoreProtocolTerms(publicState.terms)
  const derivedTradeId = tradeId(terms)
  if (derivedTradeId !== publicState.tradeId) throw new Error('terms-derived TradeID mismatch')
  if (gateContextId(terms) !== publicState.derived.gateContextId) throw new Error('GateContextID mismatch')
  if (secretState.settlementSecret !== undefined) {
    if (settlementLock(derivedTradeId, secretState.settlementSecret) !== publicState.derived.settlementLock) {
      throw new Error('settlement preimage does not derive persisted Lock')
    }
  }
  if (secretState.bobCommitSecret !== undefined) {
    if (deriveCommitLock(publicState.derived.gateContextId, secretState.bobCommitSecret) !== terms.counterpartySide.commitLock) {
      throw new Error('BobCommitSecret does not derive signed commitLock')
    }
  }
  if (publicState.party === 'bob') {
    if (publicState.progression.observed !== (secretState.bobCommitSecret !== undefined)) {
      throw new Error('Bob on-chain progression observation does not match secret state')
    }
    const revealReached = ['reveal-final', 'final-claim', 'complete'].includes(publicState.stage)
    if (revealReached !== (secretState.settlementSecret !== undefined)) {
      throw new Error('Bob reveal observation does not match secret state')
    }
  }
  validateDemoMode(publicState, secretState)
  return {publicState, secretState, terms}
}

export function serializeSecretState(state: PartySecretState): string {
  validateSecretState(state)
  return `${JSON.stringify(state, null, 2)}\n`
}

async function writePrivate(path: string, contents: string): Promise<void> {
  const handle = await open(path, 'wx', 0o600)
  try {
    await handle.writeFile(contents, {encoding: 'utf8'})
    await handle.sync()
  } finally {
    await handle.close()
  }
}

/** Publishes a matched public/secret generation by atomically replacing only the pointer. */
export async function savePartyWorkflowState(
  directory: string,
  publicState: ClientState,
  secretState: PartySecretState,
): Promise<void> {
  validatePartyWorkflowState(publicState, secretState)
  await mkdir(directory, {recursive: true, mode: 0o700})
  const generations = join(directory, 'generations')
  await mkdir(generations, {recursive: true, mode: 0o700})
  const name = generationName(publicState.generation)
  const publicPath = join(generations, `${name}.public.json`)
  const secretPath = join(generations, `${name}.secrets.json`)
  await writePrivate(publicPath, serializeClientState(publicState))
  try {
    await writePrivate(secretPath, serializeSecretState(secretState))
  } catch (error) {
    throw new Error('failed to persist complete party state generation', {cause: error})
  }
  const pointerTemp = join(directory, `.current-${process.pid}-${Date.now()}`)
  await writePrivate(pointerTemp, `${name}\n`)
  await rename(pointerTemp, join(directory, 'current'))
}

export async function restorePartyWorkflowState(directory: string): Promise<RestoredPartyWorkflowState> {
  const name = (await readFile(join(directory, 'current'), 'utf8')).trim()
  if (!/^[0-9]{12}$/.test(name)) throw new Error('invalid current state pointer')
  const generations = join(directory, 'generations')
  let publicState: ClientState
  let secretState: PartySecretState
  try {
    publicState = parseClientState(await readFile(join(generations, `${name}.public.json`), 'utf8'))
    const rawSecret: unknown = JSON.parse(await readFile(join(generations, `${name}.secrets.json`), 'utf8'))
    validateSecretState(rawSecret)
    secretState = rawSecret
  } catch (error) {
    throw new Error('party state generation is incomplete or corrupt', {cause: error})
  }
  return validatePartyWorkflowState(publicState, secretState)
}
