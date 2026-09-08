import {describe, expect, it} from 'vitest'
import {parseSpawnedCliEnvelope} from '../../scripts/demo/console/io.js'

describe('console demo child-process output', () => {
  it('parses a pretty JSON CLI envelope after build output', () => {
    const envelope = parseSpawnedCliEnvelope(
      'Nothing to compile\n{\n  "schema": "quip-swap-cli.v1",\n  "command": "bootstrap-local",\n  "ok": true\n}\n',
      'bootstrap-local',
      '',
    )

    expect(envelope).toMatchObject({
      command: 'bootstrap-local',
      ok: true
    })
  })

  it('reports a command-specific error when no JSON envelope exists', () => {
    expect(() => parseSpawnedCliEnvelope('Nothing to compile\n', 'bootstrap-local', 'failed'))
      .toThrow('bootstrap-local produced no JSON: failed')
  })
})
