/** Stable command and output contract for the prototype trusted-client CLI. */

export const CLI_SCHEMA_VERSION = 'quip-swap-cli.v1' as const

export const CLI_EXIT_SUCCESS = 0 as const
export const CLI_EXIT_FAILURE = 1 as const
export const CLI_EXIT_USAGE = 2 as const

export type CliExitCode =
  | typeof CLI_EXIT_SUCCESS
  | typeof CLI_EXIT_FAILURE
  | typeof CLI_EXIT_USAGE
export type ClientParty = 'alice' | 'bob'
export type CliCommand =
  | 'init'
  | 'bootstrap-local'
  | 'prepare-trade'
  | 'import-offer'
  | 'accept-trade'
  | 'status'
  | 'submit-alice-commit'
  | 'observe-alice-commit'
  | 'submit-bob-commit'
  | 'observe-bob-commit'
  | 'submit-revealing-claim'
  | 'observe-reveal'
  | 'submit-final-claim'
  | 'reclaim'
  | 'enter-recovery'

export interface CliCommandSpec {
  readonly command: CliCommand
  readonly parties: readonly ClientParty[]
  readonly mutatesState: boolean
  readonly input: 'none' | 'stdin-json'
  readonly description: string
}

export const cliCommandSpecs: readonly CliCommandSpec[] = [
  {
    command: 'init',
    parties: ['alice', 'bob'],
    mutatesState: true,
    input: 'none',
    description: 'Create one isolated party workspace.',
  },
  {
    command: 'bootstrap-local',
    parties: ['alice', 'bob'],
    mutatesState: true,
    input: 'none',
    description: 'Create or connect the local two-chain prototype environment.',
  },
  {
    command: 'prepare-trade',
    parties: ['alice'],
    mutatesState: true,
    input: 'stdin-json',
    description: 'Create Alice state and the Bob trade invitation from public trade configuration.',
  },
  {
    command: 'import-offer',
    parties: ['bob'],
    mutatesState: true,
    input: 'stdin-json',
    description: 'Validate and import Alice\'s public trade offer.',
  },
  {
    command: 'accept-trade',
    parties: ['bob'],
    mutatesState: true,
    input: 'none',
    description: 'Explicitly accept the locally validated public offer.',
  },
  {
    command: 'status',
    parties: ['alice', 'bob'],
    mutatesState: false,
    input: 'none',
    description: 'Read the selected party client state without changing it.',
  },
  {
    command: 'submit-alice-commit',
    parties: ['alice'],
    mutatesState: true,
    input: 'stdin-json',
    description: 'Authorize and submit Alice\'s funding commit.',
  },
  {
    command: 'observe-alice-commit',
    parties: ['alice', 'bob'],
    mutatesState: true,
    input: 'none',
    description: 'Verify Alice\'s exact commit lifecycle and canonical finality.',
  },
  {
    command: 'submit-bob-commit',
    parties: ['bob'],
    mutatesState: true,
    input: 'stdin-json',
    description: 'Submit Bob commit using the preimage recovered from Alice\'s finalized on-chain commit.',
  },
  {
    command: 'observe-bob-commit',
    parties: ['alice', 'bob'],
    mutatesState: true,
    input: 'none',
    description: 'Verify Bob\'s exact committed leg on its canonical chain.',
  },
  {
    command: 'submit-revealing-claim',
    parties: ['alice'],
    mutatesState: true,
    input: 'stdin-json',
    description: 'Claim Bob\'s leg and reveal the settlement secret on-chain.',
  },
  {
    command: 'observe-reveal',
    parties: ['bob'],
    mutatesState: true,
    input: 'none',
    description: 'Verify the revealing claim and extract its settlement preimage.',
  },
  {
    command: 'submit-final-claim',
    parties: ['bob'],
    mutatesState: true,
    input: 'none',
    description: 'Submit the permissionless claim of Alice\'s committed leg.',
  },
  {
    command: 'reclaim',
    parties: ['alice', 'bob'],
    mutatesState: true,
    input: 'none',
    description: 'Reclaim an eligible committed leg to its fixed reclaim recipient.',
  },
  {
    command: 'enter-recovery',
    parties: ['alice', 'bob'],
    mutatesState: true,
    input: 'stdin-json',
    description: 'Record recovery mode and its public reason in one party client boundary.',
  },
] as const

export type CliJson = null | boolean | string | number | readonly CliJson[] | {[key: string]: CliJson}

interface CliOutputBase {
  readonly schema: typeof CLI_SCHEMA_VERSION
  readonly command: CliCommand
  readonly party: ClientParty
  readonly mutatesState: boolean
  readonly sequence: number
  readonly tradeId?: string
}

export interface CliSuccessOutput extends CliOutputBase {
  readonly ok: true
  readonly result: CliJson
  readonly warnings: readonly string[]
}

export interface CliFailureOutput extends CliOutputBase {
  readonly ok: false
  readonly error: {
    readonly code: string
    readonly message: string
    readonly details?: CliJson
  }
}

export type CliOutput = CliSuccessOutput | CliFailureOutput

export function cliCommandSpec(command: CliCommand): CliCommandSpec {
  const spec = cliCommandSpecs.find(candidate => candidate.command === command)
  if (spec === undefined) throw new Error(`unknown CLI command: ${command}`)
  return spec
}

function requireParty(spec: CliCommandSpec, party: ClientParty): void {
  if (!spec.parties.includes(party)) throw new Error(`${spec.command} is not available to ${party}`)
}

export function cliSuccess(args: {
  readonly command: CliCommand
  readonly party: ClientParty
  readonly sequence: number
  readonly tradeId?: string
  readonly result: CliJson
  readonly warnings?: readonly string[]
}): CliSuccessOutput {
  const spec = cliCommandSpec(args.command)
  requireParty(spec, args.party)
  return {
    schema: CLI_SCHEMA_VERSION,
    command: args.command,
    party: args.party,
    mutatesState: spec.mutatesState,
    sequence: args.sequence,
    ...(args.tradeId === undefined ? {} : {tradeId: args.tradeId}),
    result: args.result,
    warnings: args.warnings ?? [],
    ok: true,
  }
}

export function cliFailure(args: {
  readonly command: CliCommand
  readonly party: ClientParty
  readonly sequence: number
  readonly tradeId?: string
  readonly code: string
  readonly message: string
  readonly details?: CliJson
}): CliFailureOutput {
  const spec = cliCommandSpec(args.command)
  return {
    schema: CLI_SCHEMA_VERSION,
    command: args.command,
    party: args.party,
    mutatesState: spec.mutatesState,
    sequence: args.sequence,
    ...(args.tradeId === undefined ? {} : {tradeId: args.tradeId}),
    ok: false,
    error: {
      code: args.code,
      message: args.message,
      ...(args.details === undefined ? {} : {details: args.details}),
    },
  }
}
