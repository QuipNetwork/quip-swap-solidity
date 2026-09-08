import {describe, expect, it} from 'vitest'
import {
  CLI_EXIT_FAILURE,
  CLI_EXIT_SUCCESS,
  CLI_EXIT_USAGE,
  CLI_SCHEMA_VERSION,
  cliCommandSpecs,
  consoleContract,
  parseConsoleArgs,
  runConsole,
} from '../../src/index.js'

const invoke = async (
  args: readonly string[]) => {
  let stdout = ''
  let stderr = ''
  const exitCode = await runConsole(args, {
    stdout: value => {
      stdout += value
    },
    stderr: value => {
      stderr += value
    }
  })

  return {
    exitCode,
    stdout,
    stderr
  }
}

describe('quip-swap executable contract', () => {
  it('parses the required party boundary without accepting arbitrary options', () => {
    expect(parseConsoleArgs(['status', '--party', 'alice', '--state-root', '/alice', '--config', '/public.json', '--json']))
      .toEqual({
        kind: 'command',
        options: {
          command: 'status',
          party: 'alice',
          stateRoot: '/alice',
          config: '/public.json',
          json: true,
          summaryJson: false,
          yes: false
        }
      })
    expect(parseConsoleArgs(['status', '--party', 'alice', '--state-root', '/alice', '--config', '/public.json', '--summary-json']))
      .toMatchObject({
        kind: 'command',
        options: {
          json: false,
          summaryJson: true
        }
      })
    expect(parseConsoleArgs(['reclaim', '--party', 'bob', '--state-root', '/bob', '--config', '/public.json', '--yes']))
      .toMatchObject({
        kind: 'command',
        options: {
          command: 'reclaim',
          yes: true
        }
      })
    expect(() => parseConsoleArgs(['status', '--party', 'alice', '--state-root', '/alice', '--config', '/public.json', '--settlement-secret', 'secret']))
      .toThrow('unknown option: --settlement-secret')
    expect(() => parseConsoleArgs(['status', '--party', 'alice', '--state-root', '/alice', '--config', '/public.json', '--json', '--summary-json']))
      .toThrow('mutually exclusive')
  })

  it('publishes the stable command schema and help', async () => {
    expect(consoleContract()).toEqual({
      schema: CLI_SCHEMA_VERSION,
      commands: cliCommandSpecs
    })

    const result = await invoke(['--help'])

    expect(result.exitCode).toBe(CLI_EXIT_SUCCESS)
    expect(result.stdout).toContain('Sensitive values are never accepted as command-line options.')
    expect(result.stderr).toBe('')
  })

  it('uses documented usage and workspace-failure exit codes', async () => {
    expect((await invoke(['unknown'])).exitCode).toBe(CLI_EXIT_USAGE)

    const pending = await invoke(['status', '--party', 'alice', '--state-root', '/alice', '--config', '/public.json', '--json'])

    expect(pending.exitCode).toBe(CLI_EXIT_FAILURE)
    expect(pending.stdout).toMatch(/^\{\n  "schema":/)
    expect(JSON.parse(pending.stdout)).toMatchObject({
      schema: CLI_SCHEMA_VERSION,
      command: 'status',
      party: 'alice',
      ok: false,
      error: {
        code: 'WORKSPACE_INVALID'
      }
    })
    expect(pending.stderr).toBe('')
    expect(pending.stdout).not.toContain('\u001b[')

    const summary = await invoke(['status', '--party', 'alice', '--state-root', '/alice', '--config', '/public.json', '--summary-json'])

    expect(summary.exitCode).toBe(CLI_EXIT_FAILURE)
    expect(JSON.parse(summary.stdout)).toMatchObject({
      schema: 'quip-swap-summary.v1',
      action: 'status',
      party: 'alice',
      ok: false,
      error: {
        code: 'WORKSPACE_INVALID'
      }
    })
    expect(summary.stdout).not.toContain('\u001b[')

    const human = await invoke(['status', '--party', 'alice', '--state-root', '/alice', '--config', '/public.json'])

    expect(human.stderr).toMatch(/^\u001b\[31m/)
    expect(human.stderr).toContain('\u001b[0m')
  })

  it('explains how to recover when a generated runtime config is missing', async () => {
    const result = await invoke(['init', '--party', 'alice', '--state-root', '/tmp/quip-missing-alice', '--config', '/tmp/quip-missing/alice.config.json', '--json'])

    expect(result.exitCode).toBe(CLI_EXIT_FAILURE)
    expect(JSON.parse(result.stdout)).toMatchObject({
      error: {
        code: 'WORKSPACE_INIT_FAILED',
        message: 'Configuration file not found: /tmp/quip-missing/alice.config.json. Run bootstrap-local successfully, then set ALICE_CONFIG and BOB_CONFIG before continuing.',
      },
    })
  })

  it('does not read interactive stdin for confirmation-only --yes commands', async () => {
    for (const [command, party] of [['submit-bob-commit', 'bob'], ['submit-revealing-claim', 'alice']] as const) {
      let stdinReads = 0
      let stdout = ''
      const exitCode = await runConsole(
        [command, '--party', party, '--state-root', '/tmp/quip-missing-state', '--config', '/tmp/quip-missing/alice.config.json', '--json', '--yes'],
        {
          stdout: value => {
            stdout += value
          },
          stderr: () => {},
          stdin: async () => {
            stdinReads += 1;

            throw new Error('stdin must not be read with --yes')
          },
        },
      )

      expect(exitCode).toBe(CLI_EXIT_FAILURE)
      expect(stdinReads).toBe(0)
      expect(JSON.parse(stdout)).toMatchObject({
        command,
        ok: false
      })
    }
  })

  it('returns a stable failure envelope for a command used by the wrong party', async () => {
    const result = await invoke(['submit-bob-commit', '--party', 'alice', '--state-root', '/alice', '--config', '/public.json', '--json'])

    expect(result.exitCode).toBe(CLI_EXIT_FAILURE)
    expect(JSON.parse(result.stdout)).toMatchObject({
      ok: false,
      error: {
        code: 'COMMAND_NOT_AVAILABLE_TO_PARTY'
      }
    })
  })
})
