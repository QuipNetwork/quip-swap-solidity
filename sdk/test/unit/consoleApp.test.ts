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

const invoke = async (args: readonly string[]) => {
  let stdout = ''
  let stderr = ''
  const exitCode = await runConsole(args, {stdout: value => { stdout += value }, stderr: value => { stderr += value }})
  return {exitCode, stdout, stderr}
}

describe('quip-swap executable contract', () => {
  it('parses the required party boundary without accepting arbitrary options', () => {
    expect(parseConsoleArgs(['status', '--party', 'alice', '--state-root', '/alice', '--config', '/public.json', '--json']))
      .toEqual({kind: 'command', options: {command: 'status', party: 'alice', stateRoot: '/alice', config: '/public.json', json: true}})
    expect(() => parseConsoleArgs(['status', '--party', 'alice', '--state-root', '/alice', '--config', '/public.json', '--settlement-secret', 'secret']))
      .toThrow('unknown option: --settlement-secret')
  })

  it('publishes the stable command schema and help', async () => {
    expect(consoleContract()).toEqual({schema: CLI_SCHEMA_VERSION, commands: cliCommandSpecs})
    const result = await invoke(['--help'])
    expect(result.exitCode).toBe(CLI_EXIT_SUCCESS)
    expect(result.stdout).toContain('Sensitive values are never accepted as command-line options.')
    expect(result.stderr).toBe('')
  })

  it('uses documented usage and workspace-failure exit codes', async () => {
    expect((await invoke(['unknown'])).exitCode).toBe(CLI_EXIT_USAGE)
    const pending = await invoke(['status', '--party', 'alice', '--state-root', '/alice', '--config', '/public.json', '--json'])
    expect(pending.exitCode).toBe(CLI_EXIT_FAILURE)
    expect(JSON.parse(pending.stdout)).toMatchObject({schema: CLI_SCHEMA_VERSION, command: 'status', party: 'alice', ok: false, error: {code: 'WORKSPACE_INVALID'}})
    expect(pending.stderr).toBe('')
  })

  it('returns a stable failure envelope for a command used by the wrong party', async () => {
    const result = await invoke(['submit-bob-commit', '--party', 'alice', '--state-root', '/alice', '--config', '/public.json', '--json'])
    expect(result.exitCode).toBe(CLI_EXIT_FAILURE)
    expect(JSON.parse(result.stdout)).toMatchObject({ok: false, error: {code: 'COMMAND_NOT_AVAILABLE_TO_PARTY'}})
  })
})
