import type {Address, Hex} from 'viem'
import {CLIENT_STATE_SCHEMA, persistProtocolTerms} from './clientState.js'
import type {AliceClientState, BobClientState, ClientState, PersistedInclusion} from './clientState.js'
import {SECRET_STATE_SCHEMA, validatePartyWorkflowState} from './clientPersistence.js'
import type {AliceSecretState, BobSecretState, PartySecretState, SecretStateMode} from './clientPersistence.js'
import type {CliCommand} from './cliSurface.js'
import {deriveCommitLock, gateContextId, settlementLock} from './protocol.js'
import type {Hex32} from './types.js'
import {prepareTrustedCrossChainWorkflow} from './workflows/trustedCrossChain.js'
import type {WorkflowArgs} from './workflows/trustedCrossChain.js'

export interface BobProgressionTransfer {
  readonly schema: 'quip-swap-bob-progression.v1'
  readonly tradeId: Hex32
  readonly from: Address
  readonly to: Address
  readonly bobCommitSecret: Hex32
  readonly aliceCommit: {readonly status: 'final'; readonly inclusion?: PersistedInclusion}
}

export interface PrepareTradeCommandArgs {
  readonly workflow: WorkflowArgs
  readonly finalClaimExecutors: readonly Address[]
  readonly secretMode?: SecretStateMode
}

export interface PreparedPartyStates {
  readonly alice: {readonly publicState: AliceClientState; readonly secretState: AliceSecretState}
  readonly bob: {readonly publicState: BobClientState; readonly secretState: BobSecretState}
}

export function prepareTradeCommand(args: PrepareTradeCommandArgs): PreparedPartyStates {
  const prepared = prepareTrustedCrossChainWorkflow(args.workflow)
  const flow = prepared.workflow
  const mode = args.secretMode ?? 'prototype-local'
  const common = {
    schema: CLIENT_STATE_SCHEMA,
    generation: 1,
    sequence: 1,
    tradeId: flow.tradeId,
    terms: persistProtocolTerms(flow.terms),
    derived: {
      gateContextId: gateContextId(flow.terms),
      settlementLock: flow.lock,
      partyCommitPayloadHash: flow.partyAuthorization.payloadHash,
      counterpartyCommitPayloadHash: flow.counterpartyAuthorization.payloadHash,
    },
    selected: {bobSubmitter: args.workflow.selectedBobSubmitter, finalClaimExecutors: args.finalClaimExecutors},
    stage: 'prepared' as const,
    aliceCommit: {status: 'not-submitted' as const},
    recovery: {active: false},
  }
  const marker = mode === 'unsafe-demo'
  const alicePublic: AliceClientState = {...common, party: 'alice', progression: {released: false}}
  const aliceSecret: AliceSecretState = {schema: SECRET_STATE_SCHEMA, party: 'alice', generation: 1, tradeId: flow.tradeId, mode, publicTestSecrets: marker, settlementSecret: prepared.settlementSecret, bobCommitSecret: prepared.bobCommitSecret}
  const bobPublic: BobClientState = {...common, party: 'bob', progression: {received: false}}
  const bobSecret: BobSecretState = {schema: SECRET_STATE_SCHEMA, party: 'bob', generation: 1, tradeId: flow.tradeId, mode, publicTestSecrets: marker}
  validatePartyWorkflowState(alicePublic, aliceSecret)
  validatePartyWorkflowState(bobPublic, bobSecret)
  return {alice: {publicState: alicePublic, secretState: aliceSecret}, bob: {publicState: bobPublic, secretState: bobSecret}}
}

type CommandInput =
  | {readonly command: 'status'}
  | {readonly command: 'mark-alice-pending'}
  | {readonly command: 'mark-alice-included-non-final'; readonly inclusion: PersistedInclusion}
  | {readonly command: 'mark-alice-final'; readonly inclusion: PersistedInclusion}
  | {readonly command: 'release-bob-secret'; readonly aliceAddress: Address}
  | {readonly command: 'submit-bob-commit'; readonly transfer: BobProgressionTransfer; readonly transactionHash: Hex}
  | {readonly command: 'observe-reveal'; readonly settlementSecret: Hex32; readonly inclusion: PersistedInclusion}
  | {readonly command: 'handoff-final-claim'; readonly executor: Address; readonly transactionHash: Hex}
  | {readonly command: 'mark-complete'}
  | {readonly command: 'enter-recovery'; readonly reason: string}

export interface AppliedPartyCommand {
  readonly publicState: ClientState
  readonly secretState: PartySecretState
  readonly transfer?: BobProgressionTransfer
}

const next = <P extends ClientState, S extends PartySecretState>(publicState: P, secretState: S) => ({
  publicState: {...publicState, generation: publicState.generation + 1, sequence: publicState.sequence + 1},
  secretState: {...secretState, generation: secretState.generation + 1},
})

export function applyPartyCommand(
  publicState: ClientState,
  secretState: PartySecretState,
  input: CommandInput,
): AppliedPartyCommand {
  validatePartyWorkflowState(publicState, secretState)
  if (input.command === 'status') return {publicState, secretState}
  let pair = next(publicState, secretState)
  let transfer: BobProgressionTransfer | undefined
  switch (input.command) {
    case 'mark-alice-pending':
      requireAlice(pair.publicState, pair.secretState)
      if ((pair.publicState as AliceClientState).progression.released) throw new Error('progression already released')
      pair.publicState = {...pair.publicState, stage: 'alice-commit', aliceCommit: {status: 'pending'}}
      break
    case 'mark-alice-included-non-final':
      requireAlice(pair.publicState, pair.secretState)
      if ((pair.publicState as AliceClientState).progression.released) throw new Error('progression already released')
      pair.publicState = {...pair.publicState, stage: 'alice-commit', aliceCommit: {status: 'included-non-final', inclusion: input.inclusion}}
      break
    case 'mark-alice-final':
      requireAlice(pair.publicState, pair.secretState)
      if ((pair.publicState as AliceClientState).progression.released) throw new Error('progression already released')
      pair.publicState = {...pair.publicState, stage: 'bob-enabled', aliceCommit: {status: 'final', inclusion: input.inclusion}}
      break
    case 'release-bob-secret':
      requireAlice(pair.publicState, pair.secretState)
      if (publicState.aliceCommit.status !== 'final') throw new Error('Alice commit is not final')
      if ((pair.publicState as AliceClientState).progression.released) throw new Error('progression already released')
      transfer = {schema: 'quip-swap-bob-progression.v1', tradeId: publicState.tradeId, from: input.aliceAddress, to: publicState.selected.bobSubmitter, bobCommitSecret: (pair.secretState as AliceSecretState).bobCommitSecret, aliceCommit: (pair.publicState as AliceClientState).aliceCommit as {status: 'final'; inclusion?: PersistedInclusion}}
      pair.publicState = {...pair.publicState, stage: 'bob-commit-pending', progression: {released: true, releasedTo: transfer.to}}
      break
    case 'submit-bob-commit':
      requireBob(pair.publicState, pair.secretState)
      validateTransfer(pair.publicState as BobClientState, input.transfer)
      pair.secretState = {...pair.secretState, bobCommitSecret: input.transfer.bobCommitSecret}
      pair.publicState = {...pair.publicState, stage: 'bob-committed', aliceCommit: input.transfer.aliceCommit, progression: {received: true, receivedFrom: input.transfer.from}}
      break
    case 'observe-reveal':
      requireBob(pair.publicState, pair.secretState)
      if (publicState.stage !== 'bob-committed') throw new Error('Bob is not committed')
      if (settlementLock(publicState.tradeId, input.settlementSecret) !== publicState.derived.settlementLock) throw new Error('invalid settlement preimage')
      pair.secretState = {...pair.secretState, settlementSecret: input.settlementSecret}
      pair.publicState = {...pair.publicState, stage: 'reveal-final'}
      break
    case 'handoff-final-claim':
      requireBob(pair.publicState, pair.secretState)
      if (publicState.stage !== 'reveal-final') throw new Error('revealing claim is not final')
      if (!publicState.selected.finalClaimExecutors.some(value => value.toLowerCase() === input.executor.toLowerCase())) throw new Error('executor not selected')
      pair.publicState = {...pair.publicState, stage: 'final-claim', selected: {...pair.publicState.selected, finalClaimExecutor: input.executor}}
      break
    case 'mark-complete':
      pair.publicState = {...pair.publicState, stage: 'complete'}
      break
    case 'enter-recovery':
      pair.publicState = {...pair.publicState, stage: 'recovery', recovery: {active: true, reason: input.reason}}
      break
  }
  const result = {...pair, ...(transfer === undefined ? {} : {transfer})}
  validatePartyWorkflowState(result.publicState, result.secretState)
  return result
}

function requireAlice(publicState: ClientState, secretState: PartySecretState): asserts publicState is AliceClientState & typeof publicState {
  if (publicState.party !== 'alice' || secretState.party !== 'alice') throw new Error('command requires Alice client state')
}
function requireBob(publicState: ClientState, secretState: PartySecretState): asserts publicState is BobClientState & typeof publicState {
  if (publicState.party !== 'bob' || secretState.party !== 'bob') throw new Error('command requires Bob client state')
}
function validateTransfer(state: BobClientState, transfer: BobProgressionTransfer): void {
  if (transfer.schema !== 'quip-swap-bob-progression.v1' || transfer.tradeId !== state.tradeId) throw new Error('invalid progression transfer')
  if (transfer.aliceCommit.status !== 'final') throw new Error('progression transfer lacks final Alice commit')
  if (transfer.to.toLowerCase() !== state.selected.bobSubmitter.toLowerCase()) throw new Error('progression transfer has wrong recipient')
  if (deriveCommitLock(state.derived.gateContextId, transfer.bobCommitSecret) !== state.terms.counterpartySide.commitLock) throw new Error('progression transfer has wrong preimage')
}

export const cliWorkflowCommands: readonly CliCommand[] = ['prepare-trade', 'status', 'mark-alice-pending', 'mark-alice-included-non-final', 'mark-alice-final', 'release-bob-secret', 'submit-bob-commit', 'observe-reveal', 'handoff-final-claim', 'mark-complete', 'enter-recovery']
