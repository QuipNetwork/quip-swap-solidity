import {
  CLI_EXIT_FAILURE,
  CLI_EXIT_SUCCESS,
  CLI_EXIT_USAGE,
  CLI_SCHEMA_VERSION,
  cliCommandSpec,
  cliCommandSpecs,
  cliFailure,
} from './cliSurface.js'
import type {CliCommand, CliExitCode, ClientParty} from './cliSurface.js'
import {initializePartyWorkspace, inspectPartyWorkspace, loadConsoleConfigIdentity} from './consoleWorkspace.js'

export const CLI_NAME = 'quip-swap' as const
export const CLI_VERSION = '0.1.0-beta.2' as const

export interface ConsoleOptions {
  readonly command: CliCommand
  readonly party: ClientParty
  readonly stateRoot: string
  readonly config: string
  readonly json: boolean
}

export interface ConsoleIo {
  readonly stdout: (text: string) => void
  readonly stderr: (text: string) => void
}

export type ConsoleParseResult =
  | {readonly kind: 'help'}
  | {readonly kind: 'version'}
  | {readonly kind: 'command'; readonly options: ConsoleOptions}

class UsageError extends Error {}

export function consoleUsage(): string {
  const commands = cliCommandSpecs
    .map(spec => `  ${spec.command.padEnd(33)} ${spec.description}`)
    .join('\n')
  return [
    `Usage: ${CLI_NAME} <command> --party <alice|bob> --state-root <path> --config <path> [--json]`,
    '',
    'Global options:',
    '  --party <alice|bob>   Select the isolated client boundary.',
    '  --state-root <path>   Select that party\'s persisted workspace.',
    '  --config <path>       Load public chain and protocol configuration.',
    '  --json                Emit the stable JSON envelope.',
    '  --help                Show this help.',
    '  --version             Show the console version.',
    '',
    'Commands:',
    commands,
    '',
    'Sensitive values are never accepted as command-line options.',
  ].join('\n')
}

export function parseConsoleArgs(args: readonly string[]): ConsoleParseResult {
  if (args.length === 0 || args.includes('--help') || args[0] === 'help') return {kind: 'help'}
  if (args.length === 1 && args[0] === '--version') return {kind: 'version'}
  const command = args[0]
  if (command === undefined || !cliCommandSpecs.some(spec => spec.command === command)) {
    throw new UsageError(`unknown command: ${command ?? '(missing)'}`)
  }
  let party: ClientParty | undefined
  let stateRoot: string | undefined
  let config: string | undefined
  let json = false
  for (let index = 1; index < args.length; index += 1) {
    const option = args[index]
    if (option === '--json') { json = true; continue }
    if (option !== '--party' && option !== '--state-root' && option !== '--config') {
      throw new UsageError(`unknown option: ${option}`)
    }
    const value = args[index + 1]
    if (value === undefined || value.startsWith('--')) throw new UsageError(`missing value for ${option}`)
    index += 1
    if (option === '--party') {
      if (value !== 'alice' && value !== 'bob') throw new UsageError('--party must be alice or bob')
      party = value
    } else if (option === '--state-root') stateRoot = value
    else config = value
  }
  if (party === undefined) throw new UsageError('missing required option: --party')
  if (stateRoot === undefined) throw new UsageError('missing required option: --state-root')
  if (config === undefined) throw new UsageError('missing required option: --config')
  return {kind: 'command', options: {command: command as CliCommand, party, stateRoot, config, json}}
}

export async function runConsole(args: readonly string[], io: ConsoleIo): Promise<CliExitCode> {
  let parsed: ConsoleParseResult
  try {
    parsed = parseConsoleArgs(args)
  } catch (error) {
    const message = error instanceof Error ? error.message : 'invalid command line'
    io.stderr(`${CLI_NAME}: ${message}\nRun '${CLI_NAME} --help' for usage.\n`)
    return CLI_EXIT_USAGE
  }
  if (parsed.kind === 'help') { io.stdout(`${consoleUsage()}\n`); return CLI_EXIT_SUCCESS }
  if (parsed.kind === 'version') { io.stdout(`${CLI_NAME} ${CLI_VERSION}\n`); return CLI_EXIT_SUCCESS }
  const {command, party, json} = parsed.options
  const spec = cliCommandSpec(command)
  const wrongParty = !spec.parties.includes(party)
  if (!wrongParty && command === 'init') {
    try {
      const config = await loadConsoleConfigIdentity(parsed.options.config)
      const manifest = await initializePartyWorkspace({root: parsed.options.stateRoot, party, config})
      const output = {
        schema: CLI_SCHEMA_VERSION,
        command,
        party,
        mutatesState: true,
        sequence: 0,
        ok: true as const,
        result: {workspace: parsed.options.stateRoot, networkId: manifest.networkId},
        warnings: [],
      }
      if (json) io.stdout(`${JSON.stringify(output)}\n`)
      else io.stdout(`Initialized ${party} workspace for ${manifest.networkId}: ${parsed.options.stateRoot}\n`)
      return CLI_EXIT_SUCCESS
    } catch (error) {
      const message = error instanceof Error ? error.message : 'workspace initialization failed'
      const output = cliFailure({command, party, sequence: 0, code: 'WORKSPACE_INIT_FAILED', message})
      if (json) io.stdout(`${JSON.stringify(output)}\n`)
      else io.stderr(`${CLI_NAME}: ${message}\n`)
      return CLI_EXIT_FAILURE
    }
  }
  if (!wrongParty) {
    try {
      const config = await loadConsoleConfigIdentity(parsed.options.config)
      await inspectPartyWorkspace(parsed.options.stateRoot, {party, networkId: config.networkId, configDigest: config.digest})
    } catch (error) {
      const message = error instanceof Error ? error.message : 'workspace validation failed'
      const output = cliFailure({command, party, sequence: 0, code: 'WORKSPACE_INVALID', message})
      if (json) io.stdout(`${JSON.stringify(output)}\n`)
      else io.stderr(`${CLI_NAME}: ${message}\n`)
      return CLI_EXIT_FAILURE
    }
  }
  const output = cliFailure({
    command,
    party,
    sequence: 0,
    code: wrongParty ? 'COMMAND_NOT_AVAILABLE_TO_PARTY' : 'COMMAND_NOT_IMPLEMENTED',
    message: wrongParty
      ? `${command} is not available to ${party}`
      : `${command} will be implemented by its Step 15 task`,
  })
  if (json) io.stdout(`${JSON.stringify(output)}\n`)
  else io.stderr(`${CLI_NAME}: ${output.error.message}\n`)
  return CLI_EXIT_FAILURE
}

export function consoleContract(): {readonly schema: typeof CLI_SCHEMA_VERSION; readonly commands: typeof cliCommandSpecs} {
  return {schema: CLI_SCHEMA_VERSION, commands: cliCommandSpecs}
}
