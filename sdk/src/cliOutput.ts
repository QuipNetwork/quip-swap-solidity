import type {Address} from 'viem'
import type {ClientState} from './clientState.js'
import {cliSuccess} from './cliSurface.js'
import type {CliCommand, CliJson, CliSuccessOutput} from './cliSurface.js'

export interface TrustedClientStatusResult {
  readonly workflowStage: ClientState['stage']
  readonly aliceCommitStatus: ClientState['aliceCommit']['status']
  readonly bobCommitEnabled: boolean
  readonly warning: string | null
  readonly selectedBobSubmitter: Address
  readonly finalClaimExecutorCandidates: readonly Address[]
  readonly selectedFinalClaimExecutor: Address | null
  readonly recoveryActive: boolean
}

export function trustedClientStatus(state: ClientState): TrustedClientStatusResult {
  const releasedOrReceived = state.party === 'alice' ? state.progression.released : state.progression.received
  const bobCommitEnabled = state.aliceCommit.status === 'final' && !releasedOrReceived && state.stage !== 'recovery'
  return {
    workflowStage: state.stage,
    aliceCommitStatus: state.aliceCommit.status,
    bobCommitEnabled,
    warning: warningFor(state),
    selectedBobSubmitter: state.selected.bobSubmitter,
    finalClaimExecutorCandidates: state.selected.finalClaimExecutors,
    selectedFinalClaimExecutor: state.selected.finalClaimExecutor ?? null,
    recoveryActive: state.recovery.active,
  }
}

export function trustedClientCliOutput(
  state: ClientState,
  command: CliCommand = 'status',
): CliSuccessOutput {
  const result = trustedClientStatus(state)
  const output = cliSuccess({
    command,
    party: state.party,
    sequence: state.sequence,
    tradeId: state.tradeId,
    result: result as unknown as CliJson,
    ...(result.warning === null ? {} : {warnings: [result.warning]}),
  })
  assertRedactedOutput(output)
  return output
}

export function formatTrustedClientStatus(state: ClientState): string {
  const status = trustedClientStatus(state)
  const lines = [
    `Party: ${state.party}`,
    `Workflow stage: ${status.workflowStage}`,
    `Alice commit: ${status.aliceCommitStatus}`,
    `Bob commit: ${status.bobCommitEnabled ? 'enabled' : 'disabled'}`,
    `Bob submitter: ${status.selectedBobSubmitter}`,
    `Final-claim executor: ${status.selectedFinalClaimExecutor ?? 'not selected'}`,
  ]
  if (status.warning !== null) lines.push(`Warning: ${status.warning}`)
  const formatted = `${lines.join('\n')}\n`
  assertRedactedText(formatted)
  return formatted
}

function warningFor(state: ClientState): string | null {
  if (state.recovery.active) return state.recovery.reason ?? 'Workflow is in recovery.'
  if (state.aliceCommit.status === 'pending') return 'Alice commit is pending; Bob commit is disabled.'
  if (state.aliceCommit.status === 'included-non-final') {
    return 'Alice commit is included but not final; Bob commit is disabled and may be reorganized.'
  }
  if (state.stage === 'bob-commit-pending') return 'Progression was released; awaiting Bob commit confirmation.'
  return null
}

const SENSITIVE_FIELD = /bobCommitSecret|settlementSecret|progressionTransfer|preimage/i
export function assertRedactedOutput(output: CliSuccessOutput): void {
  assertRedactedText(JSON.stringify(output))
}
function assertRedactedText(text: string): void {
  if (SENSITIVE_FIELD.test(text)) throw new Error('operator output contains a sensitive field')
}
