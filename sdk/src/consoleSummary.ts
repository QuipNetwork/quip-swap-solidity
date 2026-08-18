import {readFile} from 'node:fs/promises'
import {join, resolve} from 'node:path'
import type {Address} from 'viem'
import type {CliCommand, ClientParty} from './cliSurface.js'
import type {PartySecretState} from './clientPersistence.js'
import {loadConsoleRuntimeConfig} from './consoleTrade.js'
import {restoreWorkspaceWorkflowState} from './consoleWorkspace.js'

export const CONSOLE_SUMMARY_SCHEMA = 'quip-swap-summary.v1' as const

type JsonRecord = Record<string, unknown>

const record = (value: unknown): JsonRecord | undefined =>
  typeof value === 'object' && value !== null && !Array.isArray(value) ? value as JsonRecord : undefined

const string = (value: unknown): string | undefined => typeof value === 'string' ? value : undefined

function transactionFields(result: JsonRecord | undefined): JsonRecord {
  if (result === undefined) return {}
  const fields: JsonRecord = {}
  for (const key of ['transactionHash', 'chainId', 'wrapper', 'lifecycle', 'state', 'confirmations', 'requiredConfirmations', 'bobCommitEnabled', 'aliceClaimEnabled', 'finalClaimEnabled', 'outcome', 'complete']) {
    if (result[key] !== undefined) fields[key] = result[key]
  }
  const preview = record(result["preview"])
  if (preview !== undefined) {
    if (fields["chainId"] === undefined && preview["chainId"] !== undefined) fields["chainId"] = preview["chainId"]
    if (fields["wrapper"] === undefined && preview["wrapper"] !== undefined) fields["wrapper"] = preview["wrapper"]
  }
  return fields
}

function amountProjection(result: JsonRecord | undefined, partyAddress?: Address): readonly JsonRecord[] | undefined {
  const preview = record(result?.['preview'])
  if (preview !== undefined) {
    const wrapper = string(preview['wrapper'])
    const recipient = string(preview['recipient']) ?? string(preview['reclaimRecipient'])
    const sender = string(preview['principal']) ?? string(preview['submitter']) ?? partyAddress
    const assets = Array.isArray(preview['assets']) ? preview['assets'] : Array.isArray(preview['payouts']) ? preview['payouts'] : undefined
    if (assets !== undefined && wrapper !== undefined) return assets.map(value => {
      const asset = record(value) ?? {}
      const amount = string(asset['amount']) ?? '0'
      return {
        token: asset['token'],
        tradeAmount: amount,
        sender: {address: sender, change: string(asset['principalChange']) ?? '0'},
        htlc: {address: wrapper, change: string(asset['wrapperChange']) ?? '0'},
        recipient: {address: recipient, change: string(asset['recipientChange']) ?? '0'},
      }
    })
  }
  const legs = Array.isArray(result?.['legs']) ? result['legs'] : undefined
  if (legs === undefined) return undefined
  return legs.flatMap(legValue => {
    const leg = record(legValue)
    if (leg === undefined || !Array.isArray(leg['balances'])) return []
    return leg['balances'].map(balanceValue => {
      const balance = record(balanceValue) ?? {}
      return {chainId: leg['chainId'], state: leg['state'], token: balance['token'], role: balance['role'], address: balance['account'], amount: balance['amount']}
    })
  })
}

async function revealingClaimWasSubmitted(workspace: string): Promise<boolean> {
  try { await readFile(join(resolve(workspace), 'journal', 'revealing-claim.json'), 'utf8'); return true } catch (error) {
    if (error instanceof Error && 'code' in error && error.code === 'ENOENT') return false
    throw error
  }
}

function publishedSecrets(secretState: PartySecretState, bobPublished: boolean, settlementPublished: boolean): JsonRecord | undefined {
  const secrets: JsonRecord = {}
  if (bobPublished && secretState.bobCommitSecret !== undefined) secrets['bobCommitSecret'] = secretState.bobCommitSecret
  if (settlementPublished && secretState.settlementSecret !== undefined) secrets['settlementSecret'] = secretState.settlementSecret
  return Object.keys(secrets).length === 0 ? undefined : secrets
}

export async function summarizeConsoleOutput(args: {
  readonly output: unknown
  readonly workspace: string
  readonly configPath: string
}): Promise<JsonRecord> {
  const output = record(args.output)
  if (output === undefined) throw new Error('cannot summarize a non-object console output')
  const command = output['command'] as CliCommand
  const party = output['party'] as ClientParty
  const ok = output['ok'] === true
  const base: JsonRecord = {schema: CONSOLE_SUMMARY_SCHEMA, ok, action: command, party}
  if (!ok) return {...base, error: output['error']}
  if (output['tradeId'] !== undefined) base['tradeId'] = output['tradeId']
  const result = record(output['result'])
  Object.assign(base, transactionFields(result))
  if (output['warnings'] instanceof Array && output['warnings'].length > 0) base['warnings'] = output['warnings']

  let restored: Awaited<ReturnType<typeof restoreWorkspaceWorkflowState>> | undefined
  if (output['tradeId'] !== undefined) try {
    const config = await loadConsoleRuntimeConfig(args.configPath, party)
    restored = await restoreWorkspaceWorkflowState(args.workspace, {party, networkId: config.identity.networkId, configDigest: config.identity.digest})
    base['locks'] = {
      settlementLock: restored.publicState.derived.settlementLock,
      bobCommitLock: restored.terms.counterpartySide.commitLock,
    }
    const amounts = amountProjection(result, party === 'alice' ? config.actors.alice : config.actors.bob)
    if (amounts !== undefined) base['amounts'] = amounts
  } catch (error) {
    if (!(error instanceof Error && ('code' in error && error.code === 'ENOENT' || /workspace has no trade state/.test(error.message)))) throw error
  }

  if (restored !== undefined) {
    const bobPublished = restored.publicState.party === 'alice'
      ? restored.publicState.progression.published
      : restored.publicState.progression.observed
    const settlementPublished = restored.secretState.party === 'bob'
      ? restored.secretState.settlementSecret !== undefined
      : await revealingClaimWasSubmitted(args.workspace)
    const secrets = publishedSecrets(restored.secretState, bobPublished, settlementPublished)
    if (secrets !== undefined) base['publishedSecrets'] = secrets
  }
  return base
}
