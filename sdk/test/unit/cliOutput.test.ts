import {describe, expect, it} from 'vitest'
import {
  applyPartyCommand,
  assertRedactedOutput,
  formatTrustedClientStatus,
  trustedClientCliOutput,
  trustedClientStatus,
} from '../../src/index.js'
import {fixturesForClientOutput} from './helpers/clientOutputFixture.js'

describe('trusted-client CLI output', () => {
  it('shows explicit pending/finality state and warnings without secrets', () => {
    const initial = fixturesForClientOutput()
    const pending = applyPartyCommand(initial.alice.publicState, initial.alice.secretState, {command: 'mark-alice-pending'})
    const output = trustedClientCliOutput(pending.publicState)
    expect(output.result).toMatchObject({workflowStage: 'alice-commit', aliceCommitStatus: 'pending', bobCommitEnabled: false})
    expect(output.warnings[0]).toContain('pending')
    const rendered = formatTrustedClientStatus(pending.publicState)
    expect(rendered).toContain('Bob commit: disabled')
    expect(rendered).not.toContain(initial.alice.secretState.settlementSecret)
    expect(rendered).not.toContain(initial.alice.secretState.bobCommitSecret)
  })

  it('shows enablement, selected submitter, and the final-claim executor', () => {
    const initial = fixturesForClientOutput()
    const final = {...initial.alice.publicState, stage: 'bob-enabled' as const, aliceCommit: {status: 'final' as const}}
    expect(trustedClientStatus(final)).toMatchObject({bobCommitEnabled: true, selectedBobSubmitter: initial.alice.publicState.selected.bobSubmitter})
    const selected = {...initial.bob.publicState, selected: {...initial.bob.publicState.selected, finalClaimExecutor: initial.bob.publicState.selected.finalClaimExecutors[0]!}}
    expect(trustedClientStatus(selected).selectedFinalClaimExecutor).toBe(initial.bob.publicState.selected.finalClaimExecutors[0])
  })

  it('rejects any sensitive field added to an operator envelope', () => {
    const initial = fixturesForClientOutput()
    const output = trustedClientCliOutput(initial.alice.publicState)
    expect(() => assertRedactedOutput({...output, result: {settlementSecret: 'redacted'}})).toThrow('sensitive field')
  })
})
