export type SpawnedCliEnvelope = {
  readonly ok: boolean
  readonly command: string
  readonly tradeId?: string
  readonly result?: any
  readonly error?: {readonly message?: string}
}

export function parseSpawnedCliEnvelope(stdout: string, command: string, stderr: string): SpawnedCliEnvelope {
  const objectLine = /^\s*\{/m.exec(stdout)
  if (objectLine === null) throw new Error(`${command} produced no JSON: ${stderr}`)
  const objectStart = stdout.indexOf('{', objectLine.index)
  return JSON.parse(stdout.slice(objectStart)) as SpawnedCliEnvelope
}
