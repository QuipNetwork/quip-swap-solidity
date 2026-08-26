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
import {acceptConsoleTrade, importConsoleOffer, prepareConsoleTrade} from './consoleTrade.js'
import {submitAliceCommit} from './consoleCommit.js'
import {observeAliceCommit} from './consoleObservation.js'
import {observeBobCommit, submitBobCommit} from './consoleBobCommit.js'
import {submitRevealingClaim} from './consoleReveal.js'
import {observeReveal, submitFinalClaim} from './consoleFinalClaim.js'
import {getConsoleStatus} from './consoleStatus.js'
import {enterConsoleRecovery, submitReclaim} from './consoleReclaim.js'
import {summarizeConsoleOutput} from './consoleSummary.js'

export const CLI_NAME = 'quip-swap' as const
export const CLI_VERSION = '0.1.0-beta.2' as const
export const CONSOLE_CONFIRMATION_SCHEMA = 'quip-swap-confirmation.v1' as const
const GREEN = '\u001b[32m'; const YELLOW = '\u001b[33m'; const RED = '\u001b[31m'; const RESET = '\u001b[0m'

export interface ConsoleOptions {
  readonly command: CliCommand
  readonly party: ClientParty
  readonly stateRoot: string
  readonly config: string
  readonly json: boolean
  readonly summaryJson: boolean
  readonly yes: boolean
}

export interface ConsoleIo {
  readonly stdout: (text: string) => void
  readonly stderr: (text: string) => void
  readonly stdin?: () => Promise<string>
}

export interface ConsoleDependencies {
  readonly bootstrapLocal?: (args: {readonly profile: string; readonly outputDirectory: string}) => Promise<{readonly networkId: string; readonly aliceConfig: string; readonly bobConfig: string; readonly startedPids: readonly number[]}>
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
    `Usage: ${CLI_NAME} <command> --party <alice|bob> --state-root <path> --config <path> [--json|--summary-json] [--yes]`,
    '',
    'Global options:',
    '  --party <alice|bob>   Select the isolated client boundary.',
    '  --state-root <path>   Select that party\'s persisted workspace.',
    '  --config <path>       Load public chain and protocol configuration.',
    '  --json                Emit the stable JSON envelope.',
    '  --summary-json        Emit concise operator JSON; show preimages only after publication.',
    '  --yes                 Confirm sensitive actions in the local deterministic prototype only.',
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
  let summaryJson = false
  let yes = false
  for (let index = 1; index < args.length; index += 1) {
    const option = args[index]
    if (option === '--json') { json = true; continue }
    if (option === '--summary-json') { summaryJson = true; continue }
    if (option === '--yes') { yes = true; continue }
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
  if (json && summaryJson) throw new UsageError('--json and --summary-json are mutually exclusive')
  return {kind: 'command', options: {command: command as CliCommand, party, stateRoot, config, json, summaryJson, yes}}
}

function confirmJson(serialized: string, action: string): void {
  const value: unknown = JSON.parse(serialized)
  if (typeof value !== 'object' || value === null || Array.isArray(value)) throw new Error(`${action} requires explicit confirmation`)
  const record = value as Record<string, unknown>
  if (record['schema'] !== CONSOLE_CONFIRMATION_SCHEMA || record['action'] !== action || record['confirmed'] !== true) throw new Error(`${action} requires explicit confirmation`)
  if (/settlementSecret|bobCommitSecret|privateKey|signature|preimage/i.test(serialized)) throw new Error('confirmation contains sensitive material')
}

async function requireConfirmation(action: string, yes: boolean, stdin: ConsoleIo['stdin']): Promise<void> {
  if (yes) return
  if (stdin === undefined) throw new Error(`${action} requires confirmation JSON on standard input or --yes`)
  confirmJson(await stdin(), action)
}

function forceConfirmed(serialized: string): string {
  const value: unknown = JSON.parse(serialized)
  if (typeof value !== 'object' || value === null || Array.isArray(value)) throw new Error('action input must be a JSON object')
  return JSON.stringify({...value, confirmed: true})
}

function safeError(error: unknown, fallback: string): string {
  if (!(error instanceof Error)) return fallback
  const message = error.message.replace(/[\r\n]+/g, ' ').trim()
  if ('code' in error && error.code === 'ENOENT') {
    const configPath = message.match(/['"]([^'"]+\.config\.json)['"]/)?.[1]
    if (configPath !== undefined) return `Configuration file not found: ${configPath}. Run bootstrap-local successfully, then set ALICE_CONFIG and BOB_CONFIG before continuing.`
  }
  if (message === '' || /settlementSecret|bobCommitSecret|preimage|private.?key|signature|authorization material|calldata/i.test(message)) return `${fallback}; sensitive details redacted`
  return message
}

export async function runConsole(args: readonly string[], io: ConsoleIo, dependencies: ConsoleDependencies = {}): Promise<CliExitCode> {
  let parsed: ConsoleParseResult
  try {
    parsed = parseConsoleArgs(args)
  } catch (error) {
    const message = safeError(error, 'invalid command line')
    io.stderr(`${CLI_NAME}: ${message}\nRun '${CLI_NAME} --help' for usage.\n`)
    return CLI_EXIT_USAGE
  }
  if (parsed.kind === 'help') { io.stdout(`${consoleUsage()}\n`); return CLI_EXIT_SUCCESS }
  if (parsed.kind === 'version') { io.stdout(`${CLI_NAME} ${CLI_VERSION}\n`); return CLI_EXIT_SUCCESS }
  const {command, party, json, summaryJson, yes} = parsed.options
  const machine = json || summaryJson
  const emitMachine = async (output: unknown): Promise<boolean> => {
    if (!machine) return false
    const value = summaryJson
      ? await summarizeConsoleOutput({output, workspace: parsed.options.stateRoot, configPath: parsed.options.config})
      : output
    io.stdout(`${JSON.stringify(value, null, 2)}\n`)
    return true
  }
  if (!machine) {
    const raw = io
    io = {
      ...raw,
      stdout: text => raw.stdout(`${GREEN}${text}${RESET}`),
      stderr: text => raw.stderr(`${text.startsWith('WARNING:') ? YELLOW : RED}${text}${RESET}`),
    }
  }
  const spec = cliCommandSpec(command)
  const wrongParty = !spec.parties.includes(party)
  if (!wrongParty && command === 'bootstrap-local') {
    try {
      if (dependencies.bootstrapLocal === undefined) throw new Error('local bootstrap is unavailable in this SDK context')
      const result = await dependencies.bootstrapLocal({profile: parsed.options.config, outputDirectory: parsed.options.stateRoot})
      const output = {schema: CLI_SCHEMA_VERSION, command, party, mutatesState: true, sequence: 0, ok: true as const, result, warnings: ['LOCAL PROTOTYPE ONLY: mock PQ verifier and publicly known Anvil accounts are active.']}
      if (await emitMachine(output)) {}
      else {
        io.stdout(`Local prototype ready: ${result.networkId}\nAlice config: ${result.aliceConfig}\nBob config: ${result.bobConfig}\n`)
        io.stderr('WARNING: LOCAL PROTOTYPE ONLY; mock PQ verifier and public Anvil accounts are active.\n')
      }
      return CLI_EXIT_SUCCESS
    } catch (error) {
      const message = safeError(error, 'local bootstrap failed')
      const output = cliFailure({command, party, sequence: 0, code: 'BOOTSTRAP_FAILED', message})
      if (await emitMachine(output)) {}
      else io.stderr(`${CLI_NAME}: ${message}\n`)
      return CLI_EXIT_FAILURE
    }
  }
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
      if (await emitMachine(output)) {}
      else io.stdout(`Initialized ${party} workspace for ${manifest.networkId}: ${parsed.options.stateRoot}\n`)
      return CLI_EXIT_SUCCESS
    } catch (error) {
      const message = safeError(error, 'workspace initialization failed')
      const output = cliFailure({command, party, sequence: 0, code: 'WORKSPACE_INIT_FAILED', message})
      if (await emitMachine(output)) {}
      else io.stderr(`${CLI_NAME}: ${message}\n`)
      return CLI_EXIT_FAILURE
    }
  }
  if (!wrongParty && (command === 'prepare-trade' || command === 'import-offer' || command === 'accept-trade')) {
    try {
      let result: unknown
      if (command === 'prepare-trade') {
        if (io.stdin === undefined) throw new Error('prepare-trade requires JSON on standard input')
        result = await prepareConsoleTrade({workspace: parsed.options.stateRoot, configPath: parsed.options.config, input: await io.stdin()})
      } else if (command === 'import-offer') {
        if (io.stdin === undefined) throw new Error('import-offer requires the public offer on standard input')
        result = await importConsoleOffer({workspace: parsed.options.stateRoot, configPath: parsed.options.config, input: await io.stdin()})
      } else result = await acceptConsoleTrade({workspace: parsed.options.stateRoot, configPath: parsed.options.config})
      const tradeId = (result as {tradeId: string}).tradeId
      const output = {schema: CLI_SCHEMA_VERSION, command, party, mutatesState: true, sequence: 1, tradeId, ok: true as const, result, warnings: []}
      if (await emitMachine(output)) {}
      else if (command === 'prepare-trade') io.stdout(`Prepared trade ${tradeId}. Public offer: ${parsed.options.stateRoot}/public/offer.json\n`)
      else if (command === 'import-offer') io.stdout(`Imported and verified trade ${tradeId}. Run accept-trade after reviewing its terms.\n`)
      else io.stdout(`Accepted trade ${tradeId}. Local acceptance recorded in Bob's workspace\n`)
      return CLI_EXIT_SUCCESS
    } catch (error) {
      const message = safeError(error, `${command} failed`)
      const output = cliFailure({command, party, sequence: 0, code: command === 'prepare-trade' ? 'PREPARE_FAILED' : command === 'import-offer' ? 'OFFER_IMPORT_FAILED' : 'ACCEPTANCE_FAILED', message})
      if (await emitMachine(output)) {}
      else io.stderr(`${CLI_NAME}: ${message}\n`)
      return CLI_EXIT_FAILURE
    }
  }
  if (!wrongParty && command === 'submit-alice-commit') {
    try {
      if (io.stdin === undefined) throw new Error('submit-alice-commit requires confirmation JSON on standard input')
      const actionInput = await io.stdin()
      const result = await submitAliceCommit({workspace: parsed.options.stateRoot, configPath: parsed.options.config, input: yes ? forceConfirmed(actionInput) : actionInput, ...(!machine ? {onPreview: view => io.stdout([
        `Alice funding preview for chain ${view.chainId}`,
        `Wrapper: ${view.wrapper}`,
        `Principal: ${view.principal}`,
        `Recipient: ${view.recipient}`,
        `HTLC: ${view.htlc}`,
        `Assets: ${view.assets.map(asset => `${asset.amount} ${asset.token} (${asset.principalChange} principal, ${asset.htlcChange} HTLC)`).join(', ')}`,
        `Deadlines: commit ${view.commitmentDeadline}; claim ${view.claimDeadline}; reclaim ${view.reclaimRelease}`,
        `Authorization: ${view.authorizationMode}; expires ${view.authorizationExpiry}`,
        '',
      ].join('\n'))} : {})})
      const output = {schema: CLI_SCHEMA_VERSION, command, party, mutatesState: true, sequence: 2, tradeId: result.tradeId, ok: true as const, result, warnings: ['LOCAL PROTOTYPE ONLY: mock PQ authorization and publicly known Anvil Alice key are active.']}
      if (await emitMachine(output)) {}
      else io.stdout(`${result.reused ? 'Reconciled' : 'Submitted'} Alice commit ${result.transactionHash} (${result.lifecycle}).\n`)
      return CLI_EXIT_SUCCESS
    } catch (error) {
      const message = safeError(error, 'Alice commit failed')
      const output = cliFailure({command, party, sequence: 0, code: 'ALICE_COMMIT_FAILED', message})
      if (await emitMachine(output)) {}
      else io.stderr(`${CLI_NAME}: ${message}\n`)
      return CLI_EXIT_FAILURE
    }
  }
  if (!wrongParty && command === 'observe-alice-commit') {
    try {
      const result = await observeAliceCommit({workspace: parsed.options.stateRoot, configPath: parsed.options.config})
      const output = {schema: CLI_SCHEMA_VERSION, command, party, mutatesState: true, sequence: 0, tradeId: result.tradeId, ok: true as const, result, warnings: result.warning === undefined ? [] : [result.warning]}
      if (await emitMachine(output)) {}
      else {
        io.stdout(`Alice commit ${result.transactionHash}: ${result.lifecycle} (${result.confirmations}/${result.requiredConfirmations} confirmations).\n`)
        if (result.warning !== undefined) io.stderr(`WARNING: ${result.warning}\n`)
      }
      return CLI_EXIT_SUCCESS
    } catch (error) {
      const message = safeError(error, 'Alice commit observation failed')
      const output = cliFailure({command, party, sequence: 0, code: 'ALICE_COMMIT_OBSERVATION_FAILED', message})
      if (await emitMachine(output)) {}
      else io.stderr(`${CLI_NAME}: ${message}\n`)
      return CLI_EXIT_FAILURE
    }
  }
  if (!wrongParty && command === 'submit-bob-commit') {
    try {
      if (io.stdin === undefined && !yes) throw new Error('submit-bob-commit requires confirmation JSON on standard input')
      const receivedInput = yes ? '' : io.stdin === undefined ? '' : await io.stdin()
      const actionInput = receivedInput.trim() === '' && yes ? JSON.stringify({schema: 'quip-swap-bob-commit.v1', confirmed: true}) : receivedInput
      const result = await submitBobCommit({workspace: parsed.options.stateRoot, configPath: parsed.options.config, input: yes ? forceConfirmed(actionInput) : actionInput, ...(!machine ? {onPreview: view => io.stdout([`Bob funding preview for chain ${view.chainId}`, `Wrapper: ${view.wrapper}`, `HTLC: ${view.htlc}`, `Principal: ${view.principal}`, `Recipient: ${view.recipient}`, `Assets: ${view.assets.map(asset => `${asset.amount} ${asset.token} (${asset.principalChange} principal, ${asset.htlcChange} HTLC)`).join(', ')}`, `Deadlines: commit ${view.commitmentDeadline}; claim ${view.claimDeadline}; reclaim ${view.reclaimRelease}`, `Authorization: ${view.authorizationMode}; progression gate: ${view.progressionGate}; expires ${view.authorizationExpiry}`, ''].join('\n'))} : {})})
      const output = {schema: CLI_SCHEMA_VERSION, command, party, mutatesState: true, sequence: 0, tradeId: result.tradeId, ok: true as const, result, warnings: ['LOCAL PROTOTYPE ONLY: mock PQ authorization and publicly known Anvil Bob key are active.']}
      if (await emitMachine(output)) {}
      else io.stdout(`${result.reused ? 'Reconciled' : 'Submitted'} Bob commit ${result.transactionHash} (${result.lifecycle}).\n`)
      return CLI_EXIT_SUCCESS
    } catch (error) {
      const message = safeError(error, 'Bob commit failed')
      const output = cliFailure({command, party, sequence: 0, code: 'BOB_COMMIT_FAILED', message})
      if (await emitMachine(output)) {}
      else io.stderr(`${CLI_NAME}: ${message}\n`)
      return CLI_EXIT_FAILURE
    }
  }
  if (!wrongParty && command === 'observe-bob-commit') {
    try {
      const result = await observeBobCommit({workspace: parsed.options.stateRoot, configPath: parsed.options.config})
      const output = {schema: CLI_SCHEMA_VERSION, command, party, mutatesState: true, sequence: 0, tradeId: result.tradeId, ok: true as const, result, warnings: result.warning === undefined ? [] : [result.warning]}
      if (await emitMachine(output)) {}
      else {io.stdout(`Bob commit ${result.transactionHash}: ${result.lifecycle}.\n`); if (result.warning !== undefined) io.stderr(`WARNING: ${result.warning}\n`)}
      return CLI_EXIT_SUCCESS
    } catch (error) {
      const message = safeError(error, 'Bob commit observation failed')
      const output = cliFailure({command, party, sequence: 0, code: 'BOB_COMMIT_OBSERVATION_FAILED', message})
      if (await emitMachine(output)) {}
      else io.stderr(`${CLI_NAME}: ${message}\n`)
      return CLI_EXIT_FAILURE
    }
  }
  if (!wrongParty && command === 'submit-revealing-claim') {
    try {
      if (io.stdin === undefined && !yes) throw new Error('submit-revealing-claim requires confirmation JSON on standard input')
      const receivedInput = yes ? '' : io.stdin === undefined ? '' : await io.stdin()
      const actionInput = receivedInput.trim() === '' && yes ? JSON.stringify({schema: 'quip-swap-revealing-claim.v1', confirmed: true}) : receivedInput
      const result = await submitRevealingClaim({workspace: parsed.options.stateRoot, configPath: parsed.options.config, input: yes ? forceConfirmed(actionInput) : actionInput, ...(!machine ? {onPreview: view => io.stdout([`Revealing claim preview for chain ${view.chainId}`, `Wrapper: ${view.wrapper}`, `HTLC: ${view.htlc}`, `Fixed recipient: ${view.recipient}`, `Payouts: ${view.payouts.map(asset => `${asset.amount} ${asset.token} (${asset.htlcChange} HTLC, ${asset.recipientChange} recipient)`).join(', ')}`, `Claim deadline: ${view.claimDeadline}`, `DISCLOSURE: ${view.disclosure}`, ''].join('\n'))} : {})})
      const warnings = ['The settlement preimage becomes public when this transaction is submitted. Disclosure is irreversible.']
      const output = {schema: CLI_SCHEMA_VERSION, command, party, mutatesState: true, sequence: 0, tradeId: result.tradeId, ok: true as const, result, warnings}
      if (await emitMachine(output)) {}
      else {io.stdout(`${result.reused ? 'Reconciled' : 'Submitted'} revealing claim ${result.transactionHash} (${result.lifecycle}).\n`); io.stderr(`WARNING: ${warnings[0]}\n`)}
      return CLI_EXIT_SUCCESS
    } catch (error) {
      const message = safeError(error, 'revealing claim failed')
      const output = cliFailure({command, party, sequence: 0, code: 'REVEALING_CLAIM_FAILED', message})
      if (await emitMachine(output)) {}
      else io.stderr(`${CLI_NAME}: ${message}\n`)
      return CLI_EXIT_FAILURE
    }
  }
  if (!wrongParty && command === 'observe-reveal') {
    try {
      const result = await observeReveal({workspace: parsed.options.stateRoot, configPath: parsed.options.config})
      const output = {schema: CLI_SCHEMA_VERSION, command, party, mutatesState: true, sequence: 0, tradeId: result.tradeId, ok: true as const, result, warnings: result.warning === undefined ? [] : [result.warning]}
      if (await emitMachine(output)) {}
      else {io.stdout(`Revealing claim ${result.transactionHash}: ${result.lifecycle} (${result.confirmations}/${result.requiredConfirmations} confirmations).\n`); if (result.warning !== undefined) io.stderr(`WARNING: ${result.warning}\n`)}
      return CLI_EXIT_SUCCESS
    } catch (error) {
      const message = safeError(error, 'reveal observation failed')
      const output = cliFailure({command, party, sequence: 0, code: 'REVEAL_OBSERVATION_FAILED', message})
      if (await emitMachine(output)) {}
      else io.stderr(`${CLI_NAME}: ${message}\n`)
      return CLI_EXIT_FAILURE
    }
  }
  if (!wrongParty && command === 'submit-final-claim') {
    try {
      await requireConfirmation('submit-final-claim', yes, io.stdin)
      const result = await submitFinalClaim({workspace: parsed.options.stateRoot, configPath: parsed.options.config, ...(!machine ? {onPreview: view => io.stdout([`Final claim preview for chain ${view.chainId}`, `Wrapper: ${view.wrapper}`, `HTLC: ${view.htlc}`, `Permissionless submitter: ${view.submitter}`, `Fixed recipient: ${view.recipient}`, `Payouts: ${view.payouts.map(asset => `${asset.amount} ${asset.token} (${asset.htlcChange} HTLC, ${asset.recipientChange} recipient)`).join(', ')}`, `Success-path delay: ${view.successPathDelay}`, ''].join('\n'))} : {})})
      const output = {schema: CLI_SCHEMA_VERSION, command, party, mutatesState: true, sequence: 0, tradeId: result.tradeId, ok: true as const, result, warnings: []}
      if (await emitMachine(output)) {}
      else io.stdout(`${result.reused ? 'Reconciled' : 'Submitted'} permissionless final claim ${result.transactionHash} (${result.lifecycle}).\n`)
      return CLI_EXIT_SUCCESS
    } catch (error) {
      const message = safeError(error, 'final claim failed')
      const output = cliFailure({command, party, sequence: 0, code: 'FINAL_CLAIM_FAILED', message})
      if (await emitMachine(output)) {}
      else io.stderr(`${CLI_NAME}: ${message}\n`)
      return CLI_EXIT_FAILURE
    }
  }
  if (!wrongParty && command === 'status') {
    try {
      const config = await loadConsoleConfigIdentity(parsed.options.config)
      await inspectPartyWorkspace(parsed.options.stateRoot, {party, networkId: config.networkId, configDigest: config.digest})
    } catch (error) {
      const message = safeError(error, 'workspace validation failed')
      const output = cliFailure({command, party, sequence: 0, code: 'WORKSPACE_INVALID', message})
      if (await emitMachine(output)) {}
      else io.stderr(`${CLI_NAME}: ${message}\n`)
      return CLI_EXIT_FAILURE
    }
    try {
      const result = await getConsoleStatus({workspace: parsed.options.stateRoot, configPath: parsed.options.config})
      const output = {schema: CLI_SCHEMA_VERSION, command, party, mutatesState: false, sequence: 0, tradeId: result.tradeId, ok: true as const, result, warnings: result.warnings}
      if (await emitMachine(output)) {}
      else {
        io.stdout([
          `Trade: ${result.tradeId}`,
          `Outcome: ${result.outcome}${result.complete ? ' (complete)' : ''}`,
          `Persisted stage: ${result.persistedStage}`,
          `Completed: ${result.completedActions.join(', ') || 'none'}`,
          ...result.legs.map(leg => `Chain ${leg.chainId}: ${leg.state}; HTLC ${leg.htlc}; custody ${leg.custody}; deadline ${leg.deadlineRisk}; balances ${leg.balances.map(balance => `${balance.role}=${balance.amount}`).join(', ')}`),
          `Enabled actions: ${result.enabledActions.join(', ') || 'none'}`,
          `Responsible party: ${result.responsibleParty}`,
          `Next command: ${result.nextCommand ?? 'none'}`,
          '',
        ].join('\n'))
        for (const warning of result.warnings) io.stderr(`WARNING: ${warning}\n`)
      }
      return CLI_EXIT_SUCCESS
    } catch (error) {
      const message = safeError(error, 'status failed')
      const output = cliFailure({command, party, sequence: 0, code: 'STATUS_FAILED', message})
      if (await emitMachine(output)) {}
      else io.stderr(`${CLI_NAME}: ${message}\n`)
      return CLI_EXIT_FAILURE
    }
  }
  if (!wrongParty && command === 'reclaim') {
    try {
      await requireConfirmation('reclaim', yes, io.stdin)
      const result = await submitReclaim({workspace: parsed.options.stateRoot, configPath: parsed.options.config, ...(!machine ? {onPreview: view => io.stdout([`Reclaim preview for chain ${view.chainId}`, `Wrapper: ${view.wrapper}`, `HTLC: ${view.htlc}`, `Permissionless submitter: ${view.submitter}`, `Fixed reclaim recipient: ${view.reclaimRecipient}`, `Reclaim release: ${view.reclaimRelease}`, `Payouts: ${view.payouts.map(asset => `${asset.amount} ${asset.token}`).join(', ')}`, ''].join('\n'))} : {})})
      const warnings = result.lifecycle === 'dropped' || result.lifecycle === 'replaced' || result.lifecycle === 'reverted' ? [`Recorded reclaim is ${result.lifecycle}; it was not resubmitted. Inspect the chain and recover explicitly.`] : []
      const output = {schema: CLI_SCHEMA_VERSION, command, party, mutatesState: true, sequence: 0, tradeId: result.tradeId, ok: true as const, result, warnings}
      if (await emitMachine(output)) {}
      else {io.stdout(`${result.reused ? 'Reconciled' : 'Submitted'} permissionless reclaim ${result.transactionHash} (${result.lifecycle}).\n`); for (const warning of warnings) io.stderr(`WARNING: ${warning}\n`)}
      return CLI_EXIT_SUCCESS
    } catch (error) {
      const message = safeError(error, 'reclaim failed')
      const output = cliFailure({command, party, sequence: 0, code: 'RECLAIM_FAILED', message})
      if (await emitMachine(output)) {}
      else io.stderr(`${CLI_NAME}: ${message}\n`)
      return CLI_EXIT_FAILURE
    }
  }
  if (!wrongParty && command === 'enter-recovery') {
    try {
      if (io.stdin === undefined) throw new Error('enter-recovery requires recovery JSON on standard input')
      const result = await enterConsoleRecovery({workspace: parsed.options.stateRoot, configPath: parsed.options.config, input: await io.stdin()})
      const output = {schema: CLI_SCHEMA_VERSION, command, party, mutatesState: true, sequence: 0, tradeId: result.tradeId, ok: true as const, result, warnings: ['Recovery mode stops normal progression; inspect both chains and reclaim eligible legs.']}
      if (await emitMachine(output)) {}
      else {io.stdout(`Entered recovery for ${result.tradeId}: ${result.reason}\n`); io.stderr(`WARNING: ${output.warnings[0]}\n`)}
      return CLI_EXIT_SUCCESS
    } catch (error) {
      const message = safeError(error, 'enter recovery failed')
      const output = cliFailure({command, party, sequence: 0, code: 'RECOVERY_FAILED', message})
      if (await emitMachine(output)) {}
      else io.stderr(`${CLI_NAME}: ${message}\n`)
      return CLI_EXIT_FAILURE
    }
  }
  if (!wrongParty) {
    try {
      const config = await loadConsoleConfigIdentity(parsed.options.config)
      await inspectPartyWorkspace(parsed.options.stateRoot, {party, networkId: config.networkId, configDigest: config.digest})
    } catch (error) {
      const message = safeError(error, 'workspace validation failed')
      const output = cliFailure({command, party, sequence: 0, code: 'WORKSPACE_INVALID', message})
      if (await emitMachine(output)) {}
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
  if (await emitMachine(output)) {}
  else io.stderr(`${CLI_NAME}: ${output.error.message}\n`)
  return CLI_EXIT_FAILURE
}

export function consoleContract(): {readonly schema: typeof CLI_SCHEMA_VERSION; readonly commands: typeof cliCommandSpecs} {
  return {schema: CLI_SCHEMA_VERSION, commands: cliCommandSpecs}
}
