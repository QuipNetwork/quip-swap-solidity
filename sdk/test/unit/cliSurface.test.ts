import {describe, expect, it} from 'vitest'
import {
  CLI_SCHEMA_VERSION,
  cliCommandSpec,
  cliCommandSpecs,
  cliFailure,
  cliSuccess,
} from '../../src/index.js'

describe('prototype CLI surface', () => {
  it('defines unique commands with explicit party and mutation boundaries', () => {
    expect(new Set(cliCommandSpecs.map(spec => spec.command)).size).toBe(cliCommandSpecs.length)
    expect(cliCommandSpec('status').mutatesState).toBe(false)
    expect(cliCommandSpecs.filter(spec => !spec.mutatesState).map(spec => spec.command)).toEqual(['status'])
    expect(cliCommandSpec('release-bob-secret').parties).toEqual(['alice'])
    expect(cliCommandSpec('submit-bob-commit').parties).toEqual(['bob'])
    expect(cliCommandSpec('observe-reveal').parties).toEqual(['bob'])
    expect(() => cliCommandSpec('mark-alice-final' as never)).toThrow('unknown CLI command')
  })

  it('never defines a secret as a command-line argument', () => {
    expect(cliCommandSpecs.every(spec => spec.input === 'none' || spec.input === 'stdin-json')).toBe(true)
    expect(cliCommandSpecs.every(spec => !Object.hasOwn(spec, 'secret') && !Object.hasOwn(spec, 'arguments'))).toBe(true)
  })

  it('uses one versioned envelope for success and failure', () => {
    const success = cliSuccess({
      command: 'status',
      party: 'alice',
      sequence: 4,
      tradeId: `0x${'11'.repeat(32)}`,
      result: {stage: 'alice-final'},
    })
    const failure = cliFailure({
      command: 'submit-bob-commit',
      party: 'bob',
      sequence: 2,
      code: 'BOB_COMMIT_DISABLED',
      message: 'Alice commit is not final',
    })
    expect(success).toMatchObject({schema: CLI_SCHEMA_VERSION, ok: true, mutatesState: false, warnings: []})
    expect(failure).toMatchObject({schema: CLI_SCHEMA_VERSION, ok: false, mutatesState: true})
    expect(JSON.parse(JSON.stringify(success))).toEqual(success)
    expect(JSON.parse(JSON.stringify(failure))).toEqual(failure)
    expect(() =>
      cliSuccess({command: 'submit-bob-commit', party: 'alice', sequence: 1, result: {}}),
    ).toThrow('submit-bob-commit is not available to alice')
  })
})
