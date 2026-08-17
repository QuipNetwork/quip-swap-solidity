import {join, resolve} from 'node:path'
import type {Address} from 'viem'
import {applyPartyCommand} from './cliCommands.js'
import type {BobProgressionTransfer} from './cliCommands.js'
import {observeAliceCommit} from './consoleObservation.js'
import type {AliceCommitObservationBoundary} from './consoleObservation.js'
import {loadConsoleRuntimeConfig} from './consoleTrade.js'
import {deriveCommitLock} from './protocol.js'
import {loadConsoleConfigIdentity, publishLockedWorkspaceWorkflowState, restoreWorkspaceWorkflowState, withWorkspaceMutation} from './consoleWorkspace.js'
import type {Hex32} from './types.js'

export const RELEASE_BOB_SECRET_INPUT_SCHEMA = 'quip-swap-release-bob-secret.v1' as const

const object = (value: unknown, label: string): Record<string, unknown> => {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) throw new Error(`${label} must be an object`)
  return value as Record<string, unknown>
}
const hex32 = (value: unknown): value is Hex32 => typeof value === 'string' && /^0x[0-9a-fA-F]{64}$/.test(value)
const address = (value: unknown): value is Address => typeof value === 'string' && /^0x[0-9a-fA-F]{40}$/.test(value)

function confirmRelease(serialized: string): void {
  if (/settlementSecret|bobCommitSecret|privateKey|signature/i.test(serialized)) throw new Error('release confirmation must not contain sensitive material')
  const value = object(JSON.parse(serialized), 'release confirmation')
  if (value['schema'] !== RELEASE_BOB_SECRET_INPUT_SCHEMA || value['confirmed'] !== true) throw new Error('secret release requires explicit confirmed=true input')
}

function parseTransfer(serialized: string): BobProgressionTransfer {
  const value = object(JSON.parse(serialized), 'progression handoff')
  const commit = object(value['aliceCommit'], 'Alice commit evidence')
  const inclusion = object(commit['inclusion'], 'Alice commit inclusion')
  if (value['schema'] !== 'quip-swap-bob-progression.v1' || !hex32(value['tradeId']) || !address(value['from']) || !address(value['to']) || !hex32(value['bobCommitSecret']) || !Number.isSafeInteger(value['aliceGeneration']) || commit['status'] !== 'final' || !hex32(inclusion['transactionHash']) || typeof inclusion['blockNumber'] !== 'string' || !/^[0-9]+$/.test(inclusion['blockNumber']) || !hex32(inclusion['blockHash'])) throw new Error('invalid progression handoff')
  return value as unknown as BobProgressionTransfer
}

export async function releaseBobCommitSecret(args: {readonly workspace: string; readonly configPath: string; readonly input: string; readonly observationBoundary?: AliceCommitObservationBoundary}): Promise<{readonly tradeId: Hex32; readonly to: Address; readonly handoffPath: string; readonly aliceGeneration: number; readonly irreversible: true}> {
  confirmRelease(args.input)
  const observation = await observeAliceCommit({workspace: args.workspace, configPath: args.configPath, ...(args.observationBoundary === undefined ? {} : {boundary: args.observationBoundary})})
  if (observation.lifecycle !== 'final' || !observation.bobCommitEnabled) throw new Error('Alice commit is not currently final; secret release is disabled')
  const identity = await loadConsoleConfigIdentity(args.configPath)
  if (identity.localParty !== 'alice') throw new Error('secret release requires Alice configuration')
  const config = await loadConsoleRuntimeConfig(args.configPath, 'alice')
  return withWorkspaceMutation(args.workspace, async () => {
    const expected = {party: 'alice' as const, networkId: identity.networkId, configDigest: identity.digest}
    const restored = await restoreWorkspaceWorkflowState(args.workspace, expected)
    if (restored.publicState.party !== 'alice' || restored.publicState.aliceCommit.status !== 'final') throw new Error('Alice finality state changed before release')
    const applied = applyPartyCommand(restored.publicState, restored.secretState, {command: 'release-bob-secret', aliceAddress: config.actors.alice})
    if (applied.transfer === undefined) throw new Error('progression handoff was not created')
    const filename = `bob-progression-${restored.publicState.tradeId.slice(2)}.json`
    await publishLockedWorkspaceWorkflowState({root: args.workspace, expected: {...expected, tradeId: restored.publicState.tradeId, generation: restored.publicState.generation}, publicState: applied.publicState, secretState: applied.secretState, privateArtifacts: {[filename]: `${JSON.stringify(applied.transfer, null, 2)}\n`}})
    return {tradeId: restored.publicState.tradeId, to: applied.transfer.to, handoffPath: join(resolve(args.workspace), 'private', filename), aliceGeneration: applied.transfer.aliceGeneration, irreversible: true}
  })
}

export async function importBobCommitSecret(args: {readonly workspace: string; readonly configPath: string; readonly input: string; readonly observationBoundary?: AliceCommitObservationBoundary}): Promise<{readonly tradeId: Hex32; readonly from: Address; readonly aliceGeneration: number; readonly imported: true}> {
  const transfer = parseTransfer(args.input)
  const identity = await loadConsoleConfigIdentity(args.configPath)
  if (identity.localParty !== 'bob') throw new Error('progression import requires Bob configuration')
  const observation = await observeAliceCommit({workspace: args.workspace, configPath: args.configPath, ...(args.observationBoundary === undefined ? {} : {boundary: args.observationBoundary})})
  if (observation.lifecycle !== 'final' || !observation.bobCommitEnabled) throw new Error('Alice commit is not currently final; progression import is disabled')
  return withWorkspaceMutation(args.workspace, async () => {
    const expected = {party: 'bob' as const, networkId: identity.networkId, configDigest: identity.digest}
    const restored = await restoreWorkspaceWorkflowState(args.workspace, expected)
    if (transfer.tradeId !== restored.publicState.tradeId || restored.publicState.party !== 'bob') throw new Error('progression handoff belongs to another trade')
    if (deriveCommitLock(restored.publicState.derived.gateContextId, transfer.bobCommitSecret) !== restored.terms.counterpartySide.commitLock) throw new Error('progression handoff contains the wrong preimage')
    const applied = applyPartyCommand(restored.publicState, restored.secretState, {command: 'import-bob-secret', transfer})
    await publishLockedWorkspaceWorkflowState({root: args.workspace, expected: {...expected, tradeId: restored.publicState.tradeId, generation: restored.publicState.generation}, publicState: applied.publicState, secretState: applied.secretState})
    return {tradeId: restored.publicState.tradeId, from: transfer.from, aliceGeneration: transfer.aliceGeneration, imported: true}
  })
}
