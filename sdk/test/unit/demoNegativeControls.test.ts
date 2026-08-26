import type {Address} from 'viem'
import {describe, expect, it} from 'vitest'
import {
  NEGATIVE_CONTROL_SCHEMA,
  NegativeControlRecorder,
  negativeControlErrors,
  serializeNegativeControls,
} from '../../scripts/demo/shared/negative-controls.js'
import {CrossChainLegState} from '../../src/index.js'
import type {CrossChainSettlementSnapshot} from '../../scripts/demo/shared/settlement-trace.js'

const WRAPPER = `0x${'11'.repeat(20)}` as Address
const TOKEN = `0x${'22'.repeat(20)}` as Address
const PRINCIPAL = `0x${'33'.repeat(20)}` as Address
const snapshot = (stateCode = CrossChainLegState.Committed, balance = '10'): CrossChainSettlementSnapshot => ({
  chainId: 31337,
  wrapper: WRAPPER,
  htlc: `0x${'44'.repeat(20)}` as Address,
  htlcDeployed: true,
  htlcFunded: true,
  htlcReleased: stateCode !== CrossChainLegState.Committed,
  state: stateCode === CrossChainLegState.Committed ? 'Committed' : 'Claimed',
  stateCode,
  holdings: [{assetType: 'erc20', token: TOKEN, account: PRINCIPAL, balance}],
})
const failure = (name: string) => Object.assign(new Error(name), {contractErrorName: name})
const nameOf = (error: unknown) => error instanceof Error && 'contractErrorName' in error ? String(error.contractErrorName) : undefined

describe('demo negative-control execution', () => {
  it('executes and records all invalid-action scenarios with unchanged state', async () => {
    const recorder = new NegativeControlRecorder()
    for (const [scenario, errorName] of Object.entries(negativeControlErrors)) {
      await recorder.execute({
        scenario: scenario as keyof typeof negativeControlErrors,
        snapshot: async () => snapshot(),
        attempt: async () => { throw failure(errorName) },
        errorName: nameOf,
      })
    }
    const artifact = recorder.artifact({requireAll: true})
    expect(artifact.schema).toBe(NEGATIVE_CONTROL_SCHEMA)
    expect(artifact.records).toHaveLength(4)
    expect(artifact.records.every(record => record.reverted && record.stateUnchanged && record.before !== record.after)).toBe(true)
    expect(serializeNegativeControls(artifact)).toContain('final-claim-wrong-secret')
  })

  it('rejects success, the wrong revert reason, and state mutation', async () => {
    const recorder = new NegativeControlRecorder()
    await expect(recorder.execute({scenario: 'bob-commit-missing-secret', snapshot: async () => snapshot(), attempt: async () => undefined, errorName: nameOf})).rejects.toThrow('unexpectedly succeeded')
    await expect(recorder.execute({scenario: 'bob-commit-missing-secret', snapshot: async () => snapshot(), attempt: async () => { throw failure('InvalidBobCommitSecret') }, errorName: nameOf})).rejects.toThrow('expected MissingBobCommitSecret')
    let reads = 0
    await expect(recorder.execute({scenario: 'final-claim-wrong-secret', snapshot: async () => ++reads === 1 ? snapshot() : snapshot(CrossChainLegState.Claimed, '0'), attempt: async () => { throw failure('InvalidSettlementSecret') }, errorName: nameOf})).rejects.toThrow('changed state')
  })

  it('requires complete scenario coverage when requested', () => {
    expect(() => new NegativeControlRecorder().artifact({requireAll: true})).toThrow('missing negative control')
  })
})
