import type {Address, Hex} from 'viem'
import {CLIENT_STATE_SCHEMA, persistProtocolTerms} from './clientState.js'
import type {AliceClientState, BobClientState, ClientState, PersistedInclusion} from './clientState.js'
import {SECRET_STATE_SCHEMA, validatePartyWorkflowState} from './clientPersistence.js'
import type {AliceSecretState, BobSecretState, PartySecretState, SecretStateMode} from './clientPersistence.js'
import {deriveCommitLock, gateContextId, settlementLock} from './protocol.js'
import type {Hex32} from './types.js'
import {INITIAL_WORKFLOW_LIFECYCLE, prepareTrustedCrossChainWorkflow, transitionWorkflow} from './workflows/trustedCrossChain.js'
import type {Inclusion, WorkflowArgs, WorkflowEvent, WorkflowLifecycle} from './workflows/trustedCrossChain.js'

export interface PrepareTradeCommandArgs {
  readonly workflow: WorkflowArgs
  readonly finalClaimExecutors: readonly Address[]
  readonly secretMode?: SecretStateMode
}

export interface PreparedPartyStates {
  readonly alice: {
    readonly publicState: AliceClientState;
    readonly secretState: AliceSecretState
  }
  readonly bob: {
    readonly publicState: BobClientState;
    readonly secretState: BobSecretState
  }
  readonly authorizationEvidence: {
    readonly partyActionNonce: Hex32
    readonly counterpartyActionNonce: Hex32
    readonly partyExpiry: string
    readonly counterpartyExpiry: string
  }
}

export function prepareTradeCommand(
  args: PrepareTradeCommandArgs): PreparedPartyStates {
  const mode = args.secretMode ?? 'prototype-local'

  if (args.workflow.randomness !== undefined && mode !== 'unsafe-demo') {
    throw new Error('named deterministic randomness requires unsafe-demo mode')
  }

  const prepared = prepareTrustedCrossChainWorkflow(args.workflow)
  const flow = prepared.workflow
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
    selected: {
      bobSubmitter: args.workflow.selectedBobSubmitter,
      finalClaimExecutors: args.finalClaimExecutors
    },
    stage: 'prepared' as const,
    aliceCommit: {
      status: 'not-submitted' as const
    },
    recovery: {
      active: false
    },
  }
  const marker = mode === 'unsafe-demo'
  const alicePublic: AliceClientState = {
...common,
    party: 'alice',
    progression: {
      published: false
    }
  }
  const aliceSecret: AliceSecretState = {
    schema: SECRET_STATE_SCHEMA,
    party: 'alice',
    generation: 1,
    tradeId: flow.tradeId,
    mode,
    publicTestSecrets: marker,
    settlementSecret: prepared.settlementSecret,
    bobCommitSecret: prepared.bobCommitSecret
  }
  const bobPublic: BobClientState = {
...common,
    party: 'bob',
    progression: {
      observed: false
    }
  }
  const bobSecret: BobSecretState = {
    schema: SECRET_STATE_SCHEMA,
    party: 'bob',
    generation: 1,
    tradeId: flow.tradeId,
    mode,
    publicTestSecrets: marker
  }

  validatePartyWorkflowState(alicePublic, aliceSecret)
  validatePartyWorkflowState(bobPublic, bobSecret)

  return {
    alice: {
      publicState: alicePublic,
      secretState: aliceSecret
    },
    bob: {
      publicState: bobPublic,
      secretState: bobSecret
    },
    authorizationEvidence: {
      partyActionNonce: flow.partyAuthorization.payload.actionNonce,
      counterpartyActionNonce: flow.counterpartyAuthorization.payload.actionNonce,
      partyExpiry: flow.partyAuthorization.payload.expiry.toString(10),
      counterpartyExpiry: flow.counterpartyAuthorization.payload.expiry.toString(10),
    },
  }
}

type CommandInput =
  | {
    readonly command: 'status'
  }
  | {
    readonly command: 'mark-alice-pending'
  }
  | {
    readonly command: 'mark-alice-included-non-final';
    readonly inclusion: PersistedInclusion
  }
  | {
    readonly command: 'mark-alice-final';
    readonly inclusion: PersistedInclusion;
    readonly bobCommitSecret?: Hex32
  }
  | {
    readonly command: 'mark-bob-commit-pending'
  }
  | {
    readonly command: 'mark-bob-committed'
  }
  | {
    readonly command: 'record-observation'
  }
  | {
    readonly command: 'observe-reveal';
    readonly settlementSecret: Hex32;
    readonly inclusion: PersistedInclusion
  }
  | {
    readonly command: 'handoff-final-claim';
    readonly executor: Address;
    readonly transactionHash: Hex
  }
  | {
    readonly command: 'mark-complete'
  }
  | {
    readonly command: 'enter-recovery';
    readonly reason: string
  }

export interface AppliedPartyCommand {
  readonly publicState: ClientState
  readonly secretState: PartySecretState
}

const next = <P extends ClientState, S extends PartySecretState>(
  publicState: P,
  secretState: S) => ({
    publicState: {
...publicState,
      generation: publicState.generation + 1,
      sequence: publicState.sequence + 1
    },
    secretState: {
...secretState,
      generation: secretState.generation + 1
    },
  })

const runtimeInclusion = (
  inclusion: PersistedInclusion): Inclusion => ({
    transactionHash: inclusion.transactionHash,
    blockNumber: BigInt(inclusion.blockNumber),
    blockHash: inclusion.blockHash,
  })

const persistedInclusion = (
  inclusion: Inclusion): PersistedInclusion => ({
    transactionHash: inclusion.transactionHash,
    blockNumber: inclusion.blockNumber.toString(10),
    blockHash: inclusion.blockHash,
  })

function lifecycleFromClientState(
  state: ClientState): WorkflowLifecycle {
  const bobSubmissionEnabled = [
    'bob-commit-pending',
    'bob-committed',
    'reveal-final',
    'final-claim',
    'complete',
  ].includes(state.stage)

  return {
    ...INITIAL_WORKFLOW_LIFECYCLE,
    stage: state.stage,
    aliceCommit: state.aliceCommit.status,
    ...(state.aliceCommit.inclusion === undefined ? {} : {
      inclusion: runtimeInclusion(state.aliceCommit.inclusion)
    }),
    bobSubmissionEnabled,
  }
}

function applyLifecycle(
  state: ClientState,
  event: WorkflowEvent): ClientState {
  const lifecycle = transitionWorkflow(lifecycleFromClientState(state), event)

  return {
    ...state,
    stage: lifecycle.stage,
    aliceCommit: {
      status: lifecycle.aliceCommit,
      ...(lifecycle.inclusion === undefined ? {} : {
        inclusion: persistedInclusion(lifecycle.inclusion)
      }),
    },
  }
}

export function applyPartyCommand(
  publicState: ClientState,
  secretState: PartySecretState,
  input: CommandInput,
): AppliedPartyCommand {
  validatePartyWorkflowState(publicState, secretState)
  if (input.command === 'status')
    return {
      publicState,
      secretState
    }

  let pair = next(publicState, secretState)

  switch (input.command) {
    case 'record-observation':
      break
    case 'mark-alice-pending': { // Alice publishes the progression secret in this commit.
      const state = applyLifecycle(pair.publicState, {
        type: 'alice-pending'
      })

      pair.publicState = state.party === 'alice'
        ? {
...state,
          progression: {
            published: true
          }
        }
        : state

      break
    }
    case 'mark-alice-included-non-final':
      pair.publicState = applyLifecycle(pair.publicState, {
        type: 'alice-observed',
        inclusion: runtimeInclusion(input.inclusion),
        final: false,
      })
      break
    case 'mark-alice-final': {
      if (pair.publicState.party === 'bob') {
        if (input.bobCommitSecret === undefined) {
          throw new Error('final Alice observation lacks the on-chain Bob commit secret')
        }
        if (
          deriveCommitLock(pair.publicState.derived.gateContextId, input.bobCommitSecret)
          !== pair.publicState.terms.counterpartySide.commitLock
        )
          throw new Error('on-chain Bob commit secret does not match the signed commitLock')

        pair.secretState = {
...pair.secretState,
          bobCommitSecret: input.bobCommitSecret
        }
      }

      const state = applyLifecycle(pair.publicState, {
        type: 'alice-observed',
        inclusion: runtimeInclusion(input.inclusion),
        final: true,
      })

      pair.publicState = state.party === 'bob'
        ? {
          ...state,
          progression: {
            observed: true,
            observedFrom: state.terms.partySide.principal
          },
        }
        : {
...state,
          progression: {
            published: true
          }
        }

      break
    }
    case 'mark-bob-commit-pending':
      requireProgressionReady(pair.publicState, pair.secretState)
      pair.publicState = applyLifecycle(pair.publicState, {
        type: 'bob-commit-pending'
      })
      break
    case 'mark-bob-committed':
      requireProgressionReady(pair.publicState, pair.secretState)
      pair.publicState = applyLifecycle(pair.publicState, {
        type: 'bob-committed'
      })
      break
    case 'observe-reveal':
      requireBob(pair.publicState, pair.secretState)
      if (settlementLock(publicState.tradeId, input.settlementSecret) !== publicState.derived.settlementLock) {
        throw new Error('invalid settlement preimage')
      }
      pair.secretState = {
...pair.secretState,
        settlementSecret: input.settlementSecret
      }
      pair.publicState = applyLifecycle(pair.publicState, {
        type: 'reveal-final'
      })
      break
    case 'handoff-final-claim':
      requireBob(pair.publicState, pair.secretState)
      if (!publicState.selected.finalClaimExecutors.some(value => value.toLowerCase() === input.executor.toLowerCase())) {
        throw new Error('executor not selected')
      }
      pair.publicState = {
        ...applyLifecycle(pair.publicState, {
          type: 'final-claim'
        }),
        selected: {
...pair.publicState.selected,
          finalClaimExecutor: input.executor
        },
      }
      break
    case 'mark-complete':
      pair.publicState = applyLifecycle(pair.publicState, {
        type: 'complete'
      })
      break
    case 'enter-recovery':
      pair.publicState = {
        ...applyLifecycle(pair.publicState, {
          type: 'recovery'
        }),
        recovery: {
          active: true,
          reason: input.reason
        },
      }
      break
  }

  const result = pair

  validatePartyWorkflowState(result.publicState, result.secretState)

  return result
}

function requireBob(
  publicState: ClientState,
  secretState: PartySecretState): asserts publicState is BobClientState & typeof publicState {
  if (publicState.party !== 'bob' || secretState.party !== 'bob')
    throw new Error('command requires Bob client state')
}
function requireProgressionReady(
  publicState: ClientState,
  secretState: PartySecretState): void {
  if (publicState.party === 'alice') {
    if (!publicState.progression.published)
      throw new Error('Alice commit has not published progression')
  } else
    if (!publicState.progression.observed || secretState.bobCommitSecret === undefined)
      throw new Error('Bob has not observed progression on-chain')
}
/** Internal persisted-state reducer commands; these are not the public console command contract. */
export const cliWorkflowCommands = ['prepare-trade', 'status', 'mark-alice-pending', 'mark-alice-included-non-final', 'mark-alice-final', 'mark-bob-commit-pending', 'mark-bob-committed', 'observe-reveal', 'handoff-final-claim', 'mark-complete', 'enter-recovery'] as const
