/** Stable command and output contract for the prototype trusted-client CLI. */

export const CLI_SCHEMA_VERSION = 'quip-swap-cli.v1' as const

export type ClientParty = 'alice' | 'bob'
export type CliCommand =
  | 'prepare-trade'
  | 'status'
  | 'mark-alice-pending'
  | 'mark-alice-included-non-final'
  | 'mark-alice-final'
  | 'release-bob-secret'
  | 'submit-bob-commit'
  | 'observe-reveal'
  | 'handoff-final-claim'
  | 'mark-complete'
  | 'enter-recovery'

export interface CliCommandSpec {
  readonly command: CliCommand
  readonly parties: readonly ClientParty[]
  readonly mutatesState: boolean
  readonly input: 'none' | 'json'
  readonly description: string
}

export const cliCommandSpecs: readonly CliCommandSpec[] = [
  {
    command: 'prepare-trade',
    parties: ['alice'],
    mutatesState: true,
    input: 'json',
    description: 'Create Alice state and the Bob trade invitation from public trade configuration.',
  },
  {
    command: 'status',
    parties: ['alice', 'bob'],
    mutatesState: false,
    input: 'none',
    description: 'Read the selected party client state without changing it.',
  },
  {
    command: 'mark-alice-pending',
    parties: ['alice'],
    mutatesState: true,
    input: 'json',
    description: 'Record Alice commit submission as pending.',
  },
  {
    command: 'mark-alice-included-non-final',
    parties: ['alice'],
    mutatesState: true,
    input: 'json',
    description: 'Record Alice commit inclusion while keeping Bob commit disabled.',
  },
  {
    command: 'mark-alice-final',
    parties: ['alice'],
    mutatesState: true,
    input: 'json',
    description: 'Record Alice commit finality under the configured confirmation policy.',
  },
  {
    command: 'release-bob-secret',
    parties: ['alice'],
    mutatesState: true,
    input: 'json',
    description: 'Transfer the progression preimage from Alice state into the selected Bob client boundary.',
  },
  {
    command: 'submit-bob-commit',
    parties: ['bob'],
    mutatesState: true,
    input: 'json',
    description: 'Submit and record Bob commit using the released progression preimage.',
  },
  {
    command: 'observe-reveal',
    parties: ['bob'],
    mutatesState: true,
    input: 'json',
    description: 'Record the finalized revealing claim and its on-chain settlement preimage.',
  },
  {
    command: 'handoff-final-claim',
    parties: ['bob'],
    mutatesState: true,
    input: 'json',
    description: 'Record delivery of the final claim to the selected funded executor.',
  },
  {
    command: 'mark-complete',
    parties: ['alice', 'bob'],
    mutatesState: true,
    input: 'json',
    description: 'Record terminal completion independently in one party client boundary.',
  },
  {
    command: 'enter-recovery',
    parties: ['alice', 'bob'],
    mutatesState: true,
    input: 'json',
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
  requireParty(spec, args.party)
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
