import {spawnSync} from 'node:child_process'
import {mkdtempSync, rmSync} from 'node:fs'
import {tmpdir} from 'node:os'
import {join, resolve} from 'node:path'
import {afterAll, describe, expect, it} from 'vitest'
import {CLI_SCHEMA_VERSION, cliCommandSpecs} from '../../src/index.js'

const root = mkdtempSync(join(tmpdir(), 'quip-console-process-'))
const executable = resolve('src/bin/quip-swap.ts')
const missingConfig = join(root, 'missing-config.json')

afterAll(() => rmSync(root, {recursive: true, force: true}))

function invoke(command: string, party: 'alice' | 'bob') {
  const stateRoot = join(root, `${command}-${party}`)
  return spawnSync(process.execPath, [executable, command, '--party', party, '--state-root', stateRoot, '--config', missingConfig, '--json'], {
    cwd: resolve('.'),
    encoding: 'utf8',
    input: '',
    env: {...process.env, NO_COLOR: '1'},
  })
}

describe('console fresh-process command boundary', () => {
  it('starts every public command in an isolated process and emits one stable envelope', () => {
    for (const spec of cliCommandSpecs) {
      const party = spec.parties[0]!
      const result = invoke(spec.command, party)
      expect(result.signal, spec.command).toBeNull()
      expect(result.status, spec.command).toBe(1)
      expect(result.stderr, spec.command).toBe('')
      expect(result.stdout, spec.command).not.toContain('\u001b[')
      const envelope = JSON.parse(result.stdout)
      expect(envelope, spec.command).toMatchObject({schema: CLI_SCHEMA_VERSION, command: spec.command, party, ok: false})
    }
  }, 60_000)

  it('enforces role restrictions before reading workspace, configuration, or stdin', () => {
    for (const spec of cliCommandSpecs.filter(candidate => candidate.parties.length === 1)) {
      const wrongParty = spec.parties[0] === 'alice' ? 'bob' : 'alice'
      const result = invoke(spec.command, wrongParty)
      expect(result.status, spec.command).toBe(1)
      expect(JSON.parse(result.stdout), spec.command).toMatchObject({ok: false, error: {code: 'COMMAND_NOT_AVAILABLE_TO_PARTY'}})
    }
  }, 30_000)
})
