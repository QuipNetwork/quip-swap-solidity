
import type {Address, Hex} from 'viem'
import {DelegationPolicy, ExpectedSourceState, commitPayloadHash, deriveCommitLock, gateContextId, settlementLock, timingPolicyId, tradeId, validateProtocolTerms} from '../protocol.js'
import type {CommitPayloadArgs, ProtocolTerms, SideTerms, TimingPolicy} from '../protocol.js'
import type {Hex32} from '../types.js'
const ZERO = `0x${'00'.repeat(32)}` as Hex32
export type AliceCommitStatus = 'not-submitted' | 'pending' | 'included-non-final' | 'final'
export type WorkflowStage = 'prepared' | 'alice-commit' | 'bob-enabled' | 'bob-commit-pending' | 'bob-committed' | 'reveal-final' | 'final-claim' | 'complete' | 'recovery'
export type SideTermsTemplate = Omit<SideTerms, 'commitLock' | 'sideNonce'>
export interface ProtocolRandomness {
  readonly settlementSecret: Hex32
  readonly bobCommitSecret: Hex32
  readonly partySideNonce: Hex32
  readonly counterpartySideNonce: Hex32
  readonly partyActionNonce: Hex32
  readonly counterpartyActionNonce: Hex32
}
export interface WorkflowArgs {
  policy: TimingPolicy; partySide: SideTermsTemplate; counterpartySide: SideTermsTemplate
  partyVerifier: Address; counterpartyVerifier: Address; partyWrapper: Address; counterpartyWrapper: Address
  partyExpiry: bigint; counterpartyExpiry: bigint; requiredConfirmations: bigint
  selectedBobSubmitter: Address
  /** Explicit named injection for the unsafe deterministic local demo. */
  randomness?: ProtocolRandomness
  /** Low-level test hook retained for existing SDK tests; prefer `randomness`. */
  randomHex32?: () => Hex32
}
export interface PreparedAuthorization {payload: CommitPayloadArgs; payloadHash: Hex32}
export interface Inclusion {transactionHash: Hex; blockNumber: bigint; blockHash: Hex32}
export interface FinalClaimExecutor {funded: boolean; submit: (secret: Hex32) => Promise<Hex>}
export interface WorkflowStatus {stage: WorkflowStage; aliceCommit: AliceCommitStatus; warning?: string; bobCommitEnabled: boolean; reclaimRecommended: boolean}
export interface PreparedTrustedWorkflow {
  readonly workflow: TrustedCrossChainWorkflow
  readonly settlementSecret: Hex32
  readonly bobCommitSecret: Hex32
}
export function randomProtocolValue(): Hex32 {
  let value: Hex32
  do { const bytes = new Uint8Array(32); globalThis.crypto.getRandomValues(bytes); value = ('0x' + Array.from(bytes, byte => byte.toString(16).padStart(2, '0')).join('')) as Hex32 } while (value === ZERO)
  return value
}
/** Creates a workflow while returning its initial secret material to its owning client boundary. */
export function prepareTrustedCrossChainWorkflow(args: WorkflowArgs): PreparedTrustedWorkflow {
  if (args.randomness !== undefined) {
    const workflow = new TrustedCrossChainWorkflow(args)
    return {workflow, settlementSecret: args.randomness.settlementSecret, bobCommitSecret: args.randomness.bobCommitSecret}
  }
  const random = args.randomHex32 ?? randomProtocolValue
  const randomness: ProtocolRandomness = {
    settlementSecret: random(), bobCommitSecret: random(), partySideNonce: random(),
    counterpartySideNonce: random(), partyActionNonce: random(), counterpartyActionNonce: random(),
  }
  const {randomHex32: _randomHex32, ...baseArgs} = args
  const workflow = new TrustedCrossChainWorkflow({...baseArgs, randomness})
  return {workflow, settlementSecret: randomness.settlementSecret, bobCommitSecret: randomness.bobCommitSecret}
}
/** Finality-aware coordinator. Neither secret is present in status or logging surfaces. */
export class TrustedCrossChainWorkflow {
  readonly terms: ProtocolTerms; readonly tradeId: Hex32; readonly lock: Hex32
  readonly partyAuthorization: PreparedAuthorization; readonly counterpartyAuthorization: PreparedAuthorization
  readonly #secret: Hex32; readonly #bobSecret: Hex32; private readonly confirmations: bigint
  private readonly selected: Address; private alice: AliceCommitStatus = 'not-submitted'
  private stage: WorkflowStage = 'prepared'; private inclusion: Inclusion | undefined; private released = false; private unsafeReorg = false
  constructor(args: WorkflowArgs) {
    if (args.requiredConfirmations < 1n) throw new Error('requiredConfirmations must be positive')
    if (args.randomness !== undefined && args.randomHex32 !== undefined) throw new Error('choose named randomness or randomHex32, not both')
    const random = args.randomHex32 ?? randomProtocolValue
    const values = args.randomness === undefined
      ? [random(), random(), random(), random(), random(), random()] as const
      : [args.randomness.settlementSecret, args.randomness.bobCommitSecret, args.randomness.partySideNonce,
          args.randomness.counterpartySideNonce, args.randomness.partyActionNonce,
          args.randomness.counterpartyActionNonce] as const
    if (values.some(value => value === ZERO)) throw new Error('protocol randomness must be nonzero')
    if (new Set(values).size !== values.length) throw new Error('protocol randomness must be independent')
    const [secret, bobSecret, partyNonce, counterNonce, partyActionNonce, counterActionNonce] = values
    this.#secret = secret; this.#bobSecret = bobSecret; this.confirmations = args.requiredConfirmations; this.selected = args.selectedBobSubmitter
    const gate: ProtocolTerms = {timingPolicyId: timingPolicyId(args.policy), partySide: {...args.partySide, commitLock: ZERO, sideNonce: partyNonce}, counterpartySide: {...args.counterpartySide, commitLock: ZERO, sideNonce: counterNonce}}
    this.terms = {...gate, counterpartySide: {...gate.counterpartySide, commitLock: deriveCommitLock(gateContextId(gate), bobSecret)}}
    validateProtocolTerms(this.terms, args.policy); this.assertSelected()
    this.tradeId = tradeId(this.terms); this.lock = settlementLock(this.tradeId, secret)
    const party: CommitPayloadArgs = {terms: this.terms, party: true, authorizationVerifier: args.partyVerifier, swapAddress: args.partyWrapper, lock: this.lock, expectedSourceState: ExpectedSourceState.Unused, actionNonce: partyActionNonce, expiry: args.partyExpiry}
    const counter: CommitPayloadArgs = {terms: this.terms, party: false, authorizationVerifier: args.counterpartyVerifier, swapAddress: args.counterpartyWrapper, lock: this.lock, expectedSourceState: ExpectedSourceState.Unused, actionNonce: counterActionNonce, expiry: args.counterpartyExpiry}
    this.partyAuthorization = {payload: party, payloadHash: commitPayloadHash(party)}
    this.counterpartyAuthorization = {payload: counter, payloadHash: commitPayloadHash(counter)}
  }
  status(now?: bigint): WorkflowStatus {
    const warning = this.unsafeReorg ? 'Alice commit reorganized after progression disclosure; stop submission and recover if possible.' : this.stage === 'bob-commit-pending' ? 'Progression was released; awaiting Bob commit confirmation.' : this.alice === 'pending' ? 'Alice commit is pending; Bob commit is disabled.' : this.alice === 'included-non-final' ? 'Alice commit is not final; Bob commit is disabled and may be reorganized.' : undefined
    return {stage: this.stage, aliceCommit: this.alice, ...(warning ? {warning} : {}), bobCommitEnabled: this.alice === 'final' && !this.released, reclaimRecommended: now !== undefined && now >= this.terms.partySide.reclaimRelease && this.stage !== 'complete'}
  }
  markAlicePending(): void { this.beforeRelease(); this.alice = 'pending'; this.inclusion = undefined; this.stage = 'alice-commit' }
  observeAlice(inclusion: Inclusion, head: bigint): void {
    this.beforeRelease(); if (head < inclusion.blockNumber) throw new Error('head precedes inclusion')
    this.inclusion = inclusion; this.alice = head - inclusion.blockNumber + 1n >= this.confirmations ? 'final' : 'included-non-final'; this.stage = this.alice === 'final' ? 'bob-enabled' : 'alice-commit'
  }
  rollbackAlice(blockHash: Hex32): void {
    if (this.inclusion?.blockHash !== blockHash) return
    this.inclusion = undefined; this.alice = 'pending'
    if (this.released) { this.unsafeReorg = true; this.stage = 'recovery' } else this.stage = 'alice-commit'
  }
  releaseBobCommitSecret(submitter: Address): Hex32 {
    if (this.alice !== 'final') throw new Error('Alice commit is not final')
    if (submitter.toLowerCase() !== this.selected.toLowerCase()) throw new Error('submitter not selected')
    this.beforeRelease(); this.released = true; this.stage = 'bob-commit-pending'; return this.#bobSecret
  }
  markBobCommitted(): void { if (!this.released) throw new Error('progression was not released'); if (this.unsafeReorg) throw new Error('Alice commit was reorganized after progression disclosure'); this.stage = 'bob-committed' }
  observeFinalReveal(): void { if (this.stage !== 'bob-committed') throw new Error('Bob is not committed'); this.stage = 'reveal-final' }
  async handoffFinalClaim(executors: readonly FinalClaimExecutor[]): Promise<Hex> {
    if (this.stage !== 'reveal-final') throw new Error('revealing claim is not final')
    const funded = executors.filter(executor => executor.funded)
    if (funded.length === 0) throw new Error('no funded final-claim executor')
    const transactionHash = await Promise.any(funded.map(executor => executor.submit(this.#secret)))
    this.stage = 'final-claim'; return transactionHash
  }
  markComplete(): void { this.stage = 'complete' }
  enterRecovery(): void { this.stage = 'recovery' }
  private beforeRelease(): void { if (this.released) throw new Error('progression already released') }
  private assertSelected(): void {
    const side = this.terms.counterpartySide; const selected = this.selected.toLowerCase()
    if (side.delegationPolicy === DelegationPolicy.NotAllowed && selected !== side.principal.toLowerCase()) throw new Error('selected submitter must be Bob')
    if (side.delegationPolicy === DelegationPolicy.SpecificDelegate &&
        selected !== side.principal.toLowerCase() && selected !== side.delegate.toLowerCase()) {
      throw new Error('selected submitter must be Bob or the delegate')
    }
  }
}
export interface RetryPolicy {attempts: number; feeBump: (attempt: number) => bigint}
export async function submitWithFeeBumps<T>(submit: (feeBump: bigint, attempt: number) => Promise<T>, policy: RetryPolicy): Promise<T> {
  if (!Number.isInteger(policy.attempts) || policy.attempts < 1) throw new Error('attempts must be positive')
  let last: unknown
  for (let attempt = 0; attempt < policy.attempts; attempt++) { try { return await submit(policy.feeBump(attempt), attempt) } catch (error) { last = error } }
  throw last
}
