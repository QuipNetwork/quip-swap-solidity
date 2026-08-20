import {extractContractErrorName} from '../../../src/errors.js'
import type {CrossChainSettlementSnapshot} from './settlement-trace.js'

export const NEGATIVE_CONTROL_SCHEMA = 'quip-swap-negative-controls.v1' as const

export const negativeControlErrors = {
  'bob-commit-missing-secret': 'MissingBobCommitSecret',
  'bob-commit-wrong-secret': 'InvalidBobCommitSecret',
  'final-claim-wrong-secret': 'InvalidSettlementSecret',
  'commit-disallowed-submitter': 'InvalidTransportSubmitter',
} as const

export type NegativeControlScenario = keyof typeof negativeControlErrors

export interface NegativeControlRecord {
  readonly sequence: number
  readonly scenario: NegativeControlScenario
  readonly errorName: (typeof negativeControlErrors)[NegativeControlScenario]
  readonly reverted: true
  readonly stateUnchanged: true
  readonly before: CrossChainSettlementSnapshot
  readonly after: CrossChainSettlementSnapshot
}

export interface NegativeControlArtifact {
  readonly schema: typeof NEGATIVE_CONTROL_SCHEMA
  readonly records: readonly NegativeControlRecord[]
}

export class NegativeControlRecorder {
  readonly #records: NegativeControlRecord[] = []

  async execute(input: {
    readonly scenario: NegativeControlScenario
    readonly snapshot: () => Promise<CrossChainSettlementSnapshot>
    readonly attempt: () => Promise<unknown>
    readonly errorName?: (error: unknown) => string | undefined
  }): Promise<NegativeControlRecord> {
    const before = await input.snapshot()
    let failure: unknown
    try {
      await input.attempt()
    } catch (error) {
      failure = error
    }
    if (failure === undefined) throw new Error(`negative control unexpectedly succeeded: ${input.scenario}`)
    const errorName = (input.errorName ?? extractContractErrorName)(failure)
    const expected = negativeControlErrors[input.scenario]
    if (errorName !== expected) throw new Error(`negative control reverted with ${errorName ?? 'an unknown error'}; expected ${expected}`)
    const after = await input.snapshot()
    if (stableSnapshot(before) !== stableSnapshot(after)) throw new Error(`negative control changed state: ${input.scenario}`)
    const record: NegativeControlRecord = {
      sequence: this.#records.length + 1,
      scenario: input.scenario,
      errorName: expected,
      reverted: true,
      stateUnchanged: true,
      before,
      after,
    }
    this.#records.push(record)
    return record
  }

  artifact(options: {readonly requireAll?: boolean} = {}): NegativeControlArtifact {
    if (options.requireAll === true) {
      const recorded = new Set(this.#records.map(record => record.scenario))
      for (const scenario of Object.keys(negativeControlErrors) as NegativeControlScenario[]) {
        if (!recorded.has(scenario)) throw new Error(`missing negative control: ${scenario}`)
      }
    }
    return {schema: NEGATIVE_CONTROL_SCHEMA, records: this.#records.map(record => ({...record}))}
  }
}

function stableSnapshot(snapshot: CrossChainSettlementSnapshot): string {
  return JSON.stringify(snapshot)
}

export function serializeNegativeControls(artifact: NegativeControlArtifact): string {
  return `${JSON.stringify(artifact, null, 2)}\n`
}
