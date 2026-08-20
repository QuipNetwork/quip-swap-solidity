
import type {Address, Hex} from 'viem'
import {DelegationPolicy, ExpectedSourceState, commitPayloadHash, deriveCommitLock, gateContextId, settlementLock, tradeId, validateProtocolTerms} from '../protocol.js'
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
export interface WorkflowLifecycle {
  readonly stage: WorkflowStage
  readonly aliceCommit: AliceCommitStatus
  readonly inclusion?: Inclusion | undefined
  readonly bobSubmissionEnabled: boolean
  readonly unsafeReorg: boolean
}
export type WorkflowEvent =
  | {readonly type: 'alice-pending'}
  | {readonly type: 'alice-observed'; readonly inclusion: Inclusion; readonly final: boolean}
  | {readonly type: 'alice-rollback'; readonly blockHash: Hex32}
  | {readonly type: 'bob-submission-enabled'}
  | {readonly type: 'bob-commit-pending'}
  | {readonly type: 'bob-committed'}
  | {readonly type: 'reveal-final'}
  | {readonly type: 'final-claim'}
  | {readonly type: 'complete'}
  | {readonly type: 'recovery'}

export const INITIAL_WORKFLOW_LIFECYCLE: WorkflowLifecycle = {
  stage: 'prepared',
  aliceCommit: 'not-submitted',
  bobSubmissionEnabled: false,
  unsafeReorg: false,
}

export function transitionWorkflow(state: WorkflowLifecycle, event: WorkflowEvent): WorkflowLifecycle {
  switch (event.type) {
    case 'alice-pending':
      if (state.bobSubmissionEnabled) throw new Error('Bob submission already enabled')
      return {...state, stage: 'alice-commit', aliceCommit: 'pending', inclusion: undefined}
    case 'alice-observed':
      if (state.bobSubmissionEnabled) throw new Error('Bob submission already enabled')
      return {
        ...state,
        stage: event.final ? 'bob-enabled' : 'alice-commit',
        aliceCommit: event.final ? 'final' : 'included-non-final',
        inclusion: event.inclusion,
      }
    case 'alice-rollback':
      if (state.inclusion?.blockHash !== event.blockHash) return state
      return state.bobSubmissionEnabled
        ? {...state, stage: 'recovery', aliceCommit: 'pending', inclusion: undefined, unsafeReorg: true}
        : {...state, stage: 'alice-commit', aliceCommit: 'pending', inclusion: undefined}
    case 'bob-submission-enabled':
      if (state.aliceCommit !== 'final') throw new Error('Alice commit is not final')
      if (state.bobSubmissionEnabled) throw new Error('Bob submission already enabled')
      return {...state, stage: 'bob-commit-pending', bobSubmissionEnabled: true}
    case 'bob-commit-pending':
      if (!['bob-enabled', 'bob-commit-pending', 'bob-committed'].includes(state.stage)) {
        throw new Error('Bob commit is not enabled')
      }
      if (state.aliceCommit !== 'final') throw new Error('Alice commit is not final')
      return {...state, stage: 'bob-commit-pending', bobSubmissionEnabled: true}
    case 'bob-committed':
      if (state.unsafeReorg) throw new Error('Alice commit was reorganized after Bob submission was enabled')
      if (!['bob-enabled', 'bob-commit-pending', 'bob-committed'].includes(state.stage)) {
        throw new Error('Bob commit is not pending')
      }
      return {...state, stage: 'bob-committed', bobSubmissionEnabled: true}
    case 'reveal-final':
      if (state.stage !== 'bob-committed') throw new Error('Bob is not committed')
      return {...state, stage: 'reveal-final'}
    case 'final-claim':
      if (state.stage !== 'reveal-final') throw new Error('revealing claim is not final')
      return {...state, stage: 'final-claim'}
    case 'complete':
      return {...state, stage: 'complete'}
    case 'recovery':
      return {...state, stage: 'recovery'}
  }
}
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
  private readonly selected: Address; private lifecycle: WorkflowLifecycle = INITIAL_WORKFLOW_LIFECYCLE
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
    const gate: ProtocolTerms = {partySide: {...args.partySide, commitLock: ZERO, sideNonce: partyNonce}, counterpartySide: {...args.counterpartySide, commitLock: ZERO, sideNonce: counterNonce}}
    this.terms = {...gate, counterpartySide: {...gate.counterpartySide, commitLock: deriveCommitLock(gateContextId(gate), bobSecret)}}
    validateProtocolTerms(this.terms, args.policy); this.assertSelected()
    this.tradeId = tradeId(this.terms); this.lock = settlementLock(this.tradeId, secret)
    const party: CommitPayloadArgs = {terms: this.terms, party: true, authorizationVerifier: args.partyVerifier, swapAddress: args.partyWrapper, lock: this.lock, expectedSourceState: ExpectedSourceState.Unused, actionNonce: partyActionNonce, expiry: args.partyExpiry}
    const counter: CommitPayloadArgs = {terms: this.terms, party: false, authorizationVerifier: args.counterpartyVerifier, swapAddress: args.counterpartyWrapper, lock: this.lock, expectedSourceState: ExpectedSourceState.Unused, actionNonce: counterActionNonce, expiry: args.counterpartyExpiry}
    this.partyAuthorization = {payload: party, payloadHash: commitPayloadHash(party)}
    this.counterpartyAuthorization = {payload: counter, payloadHash: commitPayloadHash(counter)}
  }
  status(now?: bigint): WorkflowStatus {
    const {stage, aliceCommit, bobSubmissionEnabled, unsafeReorg} = this.lifecycle
    const warning = unsafeReorg
      ? 'Alice commit reorganized after Bob submission was enabled; stop submission and recover if possible.'
      : stage === 'bob-commit-pending'
        ? 'Bob submission was enabled; awaiting Bob commit confirmation.'
        : aliceCommit === 'pending'
          ? 'Alice commit is pending; its published preimage is not enabled for Bob yet.'
          : aliceCommit === 'included-non-final'
            ? 'Alice commit is not final; its published preimage is not enabled for Bob yet and the commit may be reorganized.'
            : undefined
    return {
      stage,
      aliceCommit,
      ...(warning ? {warning} : {}),
      bobCommitEnabled: aliceCommit === 'final' && !bobSubmissionEnabled,
      reclaimRecommended: now !== undefined && now >= this.terms.partySide.reclaimRelease && stage !== 'complete',
    }
  }
  markAlicePending(): void {
    this.lifecycle = transitionWorkflow(this.lifecycle, {type: 'alice-pending'})
  }
  observeAlice(inclusion: Inclusion, head: bigint): void {
    if (head < inclusion.blockNumber) throw new Error('head precedes inclusion')
    const final = head - inclusion.blockNumber + 1n >= this.confirmations
    this.lifecycle = transitionWorkflow(this.lifecycle, {type: 'alice-observed', inclusion, final})
  }
  rollbackAlice(blockHash: Hex32): void {
    this.lifecycle = transitionWorkflow(this.lifecycle, {type: 'alice-rollback', blockHash})
  }
  enableBobCommit(submitter: Address): Hex32 {
    if (this.lifecycle.aliceCommit !== 'final') throw new Error('Alice commit is not final')
    if (submitter.toLowerCase() !== this.selected.toLowerCase()) throw new Error('submitter not selected')
    this.lifecycle = transitionWorkflow(this.lifecycle, {type: 'bob-submission-enabled'})
    return this.#bobSecret
  }
  markBobCommitted(): void {
    this.lifecycle = transitionWorkflow(this.lifecycle, {type: 'bob-committed'})
  }
  observeFinalReveal(): void {
    this.lifecycle = transitionWorkflow(this.lifecycle, {type: 'reveal-final'})
  }
  async handoffFinalClaim(executors: readonly FinalClaimExecutor[]): Promise<Hex> {
    if (this.lifecycle.stage !== 'reveal-final') throw new Error('revealing claim is not final')
    const funded = executors.filter(executor => executor.funded)
    if (funded.length === 0) throw new Error('no funded final-claim executor')
    const transactionHash = await Promise.any(funded.map(executor => executor.submit(this.#secret)))
    this.lifecycle = transitionWorkflow(this.lifecycle, {type: 'final-claim'})
    return transactionHash
  }
  markComplete(): void {
    this.lifecycle = transitionWorkflow(this.lifecycle, {type: 'complete'})
  }
  enterRecovery(): void {
    this.lifecycle = transitionWorkflow(this.lifecycle, {type: 'recovery'})
  }
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
