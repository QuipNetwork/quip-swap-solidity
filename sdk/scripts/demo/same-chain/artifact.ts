import {tradeId} from '../../../src/index.js'
import type {Hex32, ProtocolTerms} from '../../../src/index.js'
import type {SameChainDemoFoundation, SameChainParticipantSetup} from './demo.js'
import type {SameChainAssetPosition} from './success.js'

export const SAME_CHAIN_ARTIFACT_SCHEMA = 'quip-swap-same-chain-demo.v3' as const

const actionOrder = [
  'alice-commit',
  'bob-commit',
  'claim-selection',
  'party-release',
  'counterparty-release-failed',
  'counterparty-release-retry',
] as const
const stateBeforeOrder = [
  'Unused',
  'PartyCommitted',
  'BothCommitted',
  'ClaimPending',
  'ClaimPending',
  'ClaimPending',
] as const
const stateAfterOrder = [
  'PartyCommitted',
  'BothCommitted',
  'ClaimPending',
  'ClaimPending',
  'ClaimPending',
  'Claimed',
] as const
const receiptStatusOrder = ['success', 'success', 'success', 'success', 'reverted', 'success'] as const
const completedSidesOrder = [0, 0, 0, 1, 1, 3] as const
const negativeOrder = [
  'counterparty-first',
  'commit-at-deadline',
  'repeated-party-commit',
  'mismatched-terms',
  'nonzero-progression',
  'wrong-authorization-caller',
  'wrong-signature',
  'replayed-action-nonce',
  'claim-from-party-committed',
  'reclaim-before-both-releases',
  'wrong-settlement-secret',
  'claim-at-deadline',
  'claim-after-terminal',
  'reclaim-after-terminal',
] as const

export interface RedactedSameChainArtifact {
  readonly schema: typeof SAME_CHAIN_ARTIFACT_SCHEMA
  readonly mockVerifier: true
  readonly deployment: {
    readonly chainId: number
    readonly createX: string
    readonly trustedVerifier: string
    readonly protocolOwner: string
    readonly addresses: Readonly<Record<string, string>>
  }
  readonly terms: unknown
  readonly tradeId: Hex32
  readonly lock: Hex32
  readonly initialCustody: readonly SameChainAssetPosition[]
  readonly feeFlow: SameChainDemoFoundation['feeFlow']
  readonly authorizationDecisions: readonly {
    readonly role: 'alice' | 'bob'
    readonly mode: 'registered-direct'
    readonly status: 'accepted'
    readonly principal: string
    readonly keyVersion: '1'
    readonly authorizationNonceKey: Hex32
    readonly authorizationNonceConsumed: true
    readonly transactionHash: string
  }[]
  readonly transitions: readonly {
    readonly sequence: number
    readonly action: string
    readonly caller: string
    readonly receipt: {
      readonly transactionHash: string
      readonly blockNumber: string
      readonly status: 'success' | 'reverted'
      readonly events: readonly string[]
    }
    readonly stateBefore: string
    readonly stateAfter: string
    readonly progression: 'zero' | 'not-applicable'
    readonly expectedSides: number
    readonly completedSides: number
    readonly failureReason: 'insufficient-gas' | null
    readonly custodyAfter: readonly SameChainAssetPosition[]
    readonly balanceDeltas: readonly Record<string, string>[]
  }[]
  readonly negativeControls: SameChainDemoFoundation['adversarial']['negativeControls']
  readonly recoveries: SameChainDemoFoundation['adversarial']['recoveries']
  readonly resumableFailure: SameChainDemoFoundation['adversarial']['resumableFailure']
  readonly permanentAssetFailure: SameChainDemoFoundation['adversarial']['permanentAssetFailure']
  readonly terminalOutcome: {
    readonly state: 'Claimed'
    readonly expectedSides: 3
    readonly completedSides: 3
    readonly custody: readonly SameChainAssetPosition[]
    readonly payoutsFixedByTerms: true
  }
}

export function buildSameChainDemoArtifact(execution: SameChainDemoFoundation): RedactedSameChainArtifact {
  let previous = initialCustody(execution.setup)
  const transitions = execution.success.actions.map((action, index) => {
    const balanceDeltas = action.custodyAfter.map((asset, assetIndex) =>
      assetDelta(previous[assetIndex]!, asset)
    )
    previous = action.custodyAfter
    return {
      sequence: index + 1,
      action: action.action,
      caller: action.caller,
      receipt: {
        transactionHash: action.transactionHash,
        blockNumber: action.blockNumber,
        status: action.receiptStatus,
        events: action.events,
      },
      stateBefore: action.stateBefore,
      stateAfter: action.stateAfter,
      progression: index < 2 ? 'zero' as const : 'not-applicable' as const,
      expectedSides: action.expectedSides,
      completedSides: action.completedSides,
      failureReason: action.failureReason,
      custodyAfter: action.custodyAfter,
      balanceDeltas,
    }
  })
  const artifact: RedactedSameChainArtifact = {
    schema: SAME_CHAIN_ARTIFACT_SCHEMA,
    mockVerifier: true,
    deployment: {
      chainId: execution.deployment.chainId,
      createX: execution.deployment.createX,
      trustedVerifier: execution.deployment.trustedVerifier,
      protocolOwner: execution.protocolOwner,
      addresses: execution.deployment.addresses,
    },
    terms: jsonValue(execution.terms),
    tradeId: execution.tradeId,
    lock: execution.lock,
    initialCustody: initialCustody(execution.setup),
    feeFlow: execution.feeFlow,
    authorizationDecisions: [
      authorizationDecision(execution, 'alice', 0),
      authorizationDecision(execution, 'bob', 1),
    ],
    transitions,
    negativeControls: execution.adversarial.negativeControls,
    recoveries: execution.adversarial.recoveries,
    resumableFailure: execution.adversarial.resumableFailure,
    permanentAssetFailure: execution.adversarial.permanentAssetFailure,
    terminalOutcome: {
      state: 'Claimed',
      expectedSides: 3,
      completedSides: 3,
      custody: execution.success.finalSnapshot.assets,
      payoutsFixedByTerms: execution.success.payoutsFixedByTerms,
    },
  }
  const serialized = serializeSameChainDemoArtifact(artifact)
  if (serialized.includes(execution.success.settlementSecret)) {
    throw new Error('redacted same-chain artifact contains the settlement preimage')
  }
  validateSameChainDemoArtifact(JSON.parse(serialized))
  return artifact
}

function authorizationDecision(
  execution: SameChainDemoFoundation,
  role: 'alice' | 'bob',
  actionIndex: 0 | 1,
): RedactedSameChainArtifact['authorizationDecisions'][number] {
  const participant = execution.setup[role]
  const action = execution.success.actions[actionIndex]
  if (action.authorizationNonceKey === null || action.authorizationNonceConsumed !== true) {
    throw new Error(`${role} accepted authorization lacks nonce-consumption evidence`)
  }
  return {
    role,
    mode: participant.authorization.mode,
    status: 'accepted',
    principal: participant.principal,
    keyVersion: participant.authorization.expectedActiveKeyVersion,
    authorizationNonceKey: action.authorizationNonceKey,
    authorizationNonceConsumed: true,
    transactionHash: action.transactionHash,
  }
}

function initialCustody(setup: SameChainDemoFoundation['setup']): readonly [SameChainAssetPosition, SameChainAssetPosition] {
  return [initialPosition(setup.alice, 'alice-asset'), initialPosition(setup.bob, 'bob-asset')]
}

function initialPosition(
  participant: SameChainParticipantSetup,
  role: SameChainAssetPosition['role'],
): SameChainAssetPosition {
  return {
    role,
    principal: participant.principal,
    recipient: participant.recipient,
    token: participant.asset,
    htlc: participant.htlc,
    htlcDeployed: false,
    htlcFunded: false,
    htlcReleased: false,
    nextAssetIndex: '0',
    payoutRecipient: '0x0000000000000000000000000000000000000000',
    principalBalance: participant.balance,
    recipientBalance: '0',
    htlcBalance: '0',
    allowance: participant.allowance,
  }
}

function assetDelta(before: SameChainAssetPosition, after: SameChainAssetPosition): Record<string, string> {
  if (before.role !== after.role || before.token !== after.token || before.htlc !== after.htlc) throw new Error('custody order changed')
  return {
    role: after.role,
    principalBalance: delta(before.principalBalance, after.principalBalance),
    recipientBalance: delta(before.recipientBalance, after.recipientBalance),
    htlcBalance: delta(before.htlcBalance, after.htlcBalance),
    allowance: delta(before.allowance, after.allowance),
  }
}

function delta(before: string, after: string): string {
  return (BigInt(after) - BigInt(before)).toString()
}

function jsonValue(value: unknown): unknown {
  return JSON.parse(JSON.stringify(value, (_, item: unknown) => typeof item === 'bigint' ? item.toString() : item))
}

export function serializeSameChainDemoArtifact(artifact: RedactedSameChainArtifact): string {
  return `${JSON.stringify(artifact, null, 2)}\n`
}

export function validateSameChainDemoArtifact(value: unknown): asserts value is RedactedSameChainArtifact {
  const root = record(value, 'artifact')
  equal(root.schema, SAME_CHAIN_ARTIFACT_SCHEMA, 'schema')
  equal(root.mockVerifier, true, 'mockVerifier')
  const deployment = record(root.deployment, 'deployment')
  if (!Number.isInteger(deployment.chainId) || deployment.chainId !== 31_337) fail('deployment.chainId')
  const addresses = record(deployment.addresses, 'deployment.addresses')
  address(addresses.sameChainWrapper, 'deployment.addresses.sameChainWrapper')
  address(addresses.directAuthorization, 'deployment.addresses.directAuthorization')
  address(deployment.trustedVerifier, 'deployment.trustedVerifier')
  address(deployment.protocolOwner, 'deployment.protocolOwner')
  bytes32(root.tradeId, 'tradeId')
  bytes32(root.lock, 'lock')
  if (root.lock === `0x${'00'.repeat(32)}`) fail('lock')

  const terms = hydrateTerms(root.terms)
  equal(tradeId(terms), root.tradeId, 'tradeId')
  if (terms.partySide.chainId !== 31_337n || terms.counterpartySide.chainId !== 31_337n) fail('terms.chainId')

  const initial = array(root.initialCustody, 'initialCustody')
  if (initial.length !== 2) fail('initialCustody.length')
  validateCustody(initial, 'initialCustody')
  validateLifecycle(initial, [[false, false, false], [false, false, false]], 'initialCustody')
  const feeFlow = record(root.feeFlow, 'feeFlow')
  const feeQuotes = array(feeFlow.quotes, 'feeFlow.quotes')
  if (feeQuotes.length !== 2) fail('feeFlow.quotes.length')
  feeQuotes.forEach((item, index) => {
    const quote = record(item, `feeFlow.quotes[${index}]`)
    equal(quote.side, index === 0 ? 'alice' : 'bob', `feeFlow.quotes[${index}].side`)
    equal(quote.nativeEscrow, '0', `feeFlow.quotes[${index}].nativeEscrow`)
    equal(quote.commitmentFee, '5000000000000', `feeFlow.quotes[${index}].commitmentFee`)
    equal(quote.totalValue, '5000000000000', `feeFlow.quotes[${index}].totalValue`)
  })
  equal(feeFlow.accruedAfterCommits, '10000000000000', 'feeFlow.accruedAfterCommits')
  equal(feeFlow.accruedAfterSettlement, feeFlow.accruedAfterCommits, 'feeFlow.accruedAfterSettlement')
  const withdrawal = record(feeFlow.withdrawal, 'feeFlow.withdrawal')
  equal(withdrawal.recipient, deployment.protocolOwner, 'feeFlow.withdrawal.recipient')
  equal(withdrawal.amount, feeFlow.accruedAfterSettlement, 'feeFlow.withdrawal.amount')
  hash(withdrawal.transactionHash, 'feeFlow.withdrawal.transactionHash')
  equal(feeFlow.accruedAfterWithdrawal, '0', 'feeFlow.accruedAfterWithdrawal')
  equal(feeFlow.gasIncludedInProtocolRevenue, false, 'feeFlow.gasIncludedInProtocolRevenue')
  const decisions = array(root.authorizationDecisions, 'authorizationDecisions')
  if (decisions.length !== 2) fail('authorizationDecisions.length')
  decisions.forEach((item, index) => {
    const decision = record(item, `authorizationDecisions[${index}]`)
    equal(decision.role, index === 0 ? 'alice' : 'bob', `authorizationDecisions[${index}].role`)
    equal(decision.status, 'accepted', `authorizationDecisions[${index}].status`)
    equal(decision.authorizationNonceConsumed, true, `authorizationDecisions[${index}].authorizationNonceConsumed`)
    bytes32(decision.authorizationNonceKey, `authorizationDecisions[${index}].authorizationNonceKey`)
    equal(decision.principal, index === 0 ? terms.partySide.principal : terms.counterpartySide.principal, 'authorization principal ' + index)
    equal(decision.keyVersion, '1', 'authorization key version ' + index)
  })

  const transitions = array(root.transitions, 'transitions')
  if (transitions.length !== actionOrder.length) fail('transitions.length')
  let previousCustody = initial
  transitions.forEach((item, index) => {
    const transition = record(item, `transitions[${index}]`)
    equal(transition.sequence, index + 1, `transitions[${index}].sequence`)
    equal(transition.action, actionOrder[index], `transitions[${index}].action`)
    equal(transition.stateBefore, stateBeforeOrder[index], `transitions[${index}].stateBefore`)
    equal(transition.stateAfter, stateAfterOrder[index], `transitions[${index}].stateAfter`)
    equal(transition.progression, index < 2 ? 'zero' : 'not-applicable', `transitions[${index}].progression`)
    equal(transition.expectedSides, index < 2 ? 0 : 3, `transitions[${index}].expectedSides`)
    equal(transition.completedSides, completedSidesOrder[index], `transitions[${index}].completedSides`)
    equal(
      transition.failureReason,
      index === 4 ? 'insufficient-gas' : null,
      `transitions[${index}].failureReason`,
    )
    const receipt = record(transition.receipt, `transitions[${index}].receipt`)
    hash(receipt.transactionHash, `transitions[${index}].receipt.transactionHash`)
    equal(receipt.status, receiptStatusOrder[index], `transitions[${index}].receipt.status`)
    if (!/^[0-9]+$/.test(String(receipt.blockNumber))) fail(`transitions[${index}].receipt.blockNumber`)
    const events = array(receipt.events, 'transition events ' + index)
    const requiredEvent = index < 2
      ? 'sameChainWrapper.Committed'
      : index === 2
        ? 'sameChainWrapper.ClaimSelected'
        : index === 3 || index === 5
          ? 'sameChainWrapper.SettlementBatchExecuted'
          : undefined
    if (requiredEvent !== undefined && !events.includes(requiredEvent)) fail('transition event ' + index)
    if (index < 2 && (!events.includes('sameChainWrapper.HTLCCreated') || !events.includes('swapHTLC.Funded'))) {
      fail('HTLC funding events ' + index)
    }
    if ((index === 3 || index === 5) && !events.includes('swapHTLC.Released')) {
      fail('HTLC release event ' + index)
    }
    if (index === 5 && !events.includes('sameChainWrapper.Claimed')) fail('terminal claim event')
    if (index === 4 && events.length !== 0) {
      fail('reverted execution events')
    }
    const custody = array(transition.custodyAfter, `transitions[${index}].custodyAfter`)
    const deltas = array(transition.balanceDeltas, `transitions[${index}].balanceDeltas`)
    if (custody.length !== 2 || deltas.length !== 2) fail(`transitions[${index}].custody`)
    validateCustodyDeltas(previousCustody, custody, deltas, 'transitions[' + index + ']')
    validateLifecycle(
      custody,
      index === 0
        ? [[true, true, false], [false, false, false]]
        : index === 1 || index === 2
          ? [[true, true, false], [true, true, false]]
          : index === 3 || index === 4
            ? [[true, true, true], [true, true, false]]
            : [[true, true, true], [true, true, true]],
      `transitions[${index}].custodyAfter`,
    )
    validateSettlementCustody(custody, terms, index, `transitions[${index}].custodyAfter`)
    previousCustody = custody
  })
  equal(record(decisions[0], 'alice decision').transactionHash, record(record(transitions[0], 'transition 0').receipt, 'receipt 0').transactionHash, 'alice transaction')
  equal(record(decisions[1], 'bob decision').transactionHash, record(record(transitions[1], 'transition 1').receipt, 'receipt 1').transactionHash, 'bob transaction')

  const negatives = array(root.negativeControls, 'negativeControls')
  if (negatives.length !== negativeOrder.length) fail('negativeControls.length')
  negatives.forEach((item, index) => {
    const control = record(item, `negativeControls[${index}]`)
    equal(control.scenario, negativeOrder[index], `negativeControls[${index}].scenario`)
    equal(control.reverted, true, `negativeControls[${index}].reverted`)
    equal(control.stateAndCustodyUnchanged, true, `negativeControls[${index}].stateAndCustodyUnchanged`)
    equal(control.authorizationNoncePreserved, true, `negativeControls[${index}].authorizationNoncePreserved`)
  })

  const recoveries = array(root.recoveries, 'recoveries')
  if (recoveries.length !== 2) fail('recoveries.length')
  equal(record(recoveries[0], 'recoveries[0]').outcome, 'party-only-reclaim', 'recoveries[0].outcome')
  equal(record(recoveries[1], 'recoveries[1]').outcome, 'both-reclaim', 'recoveries[1].outcome')
  for (const [index, recovery] of recoveries.entries()) {
    const item = record(recovery, `recoveries[${index}]`)
    equal(item.stateAfter, 'Reclaimed', `recoveries[${index}].stateAfter`)
    equal(item.fixedReclaimRecipients, true, `recoveries[${index}].fixedReclaimRecipients`)
    equal(item.expectedSides, index === 0 ? 1 : 3, `recoveries[${index}].expectedSides`)
    equal(item.completedSides, index === 0 ? 1 : 3, `recoveries[${index}].completedSides`)
    const custody = array(item.custodyAfter, `recoveries[${index}].custodyAfter`)
    validateCustody(custody, `recoveries[${index}].custodyAfter`)
    validateLifecycle(
      custody,
      index === 0
        ? [[true, true, true], [false, false, false]]
        : [[true, true, true], [true, true, true]],
      `recoveries[${index}].custodyAfter`,
    )
    custody.forEach((assetValue, sideIndex) => {
      const asset = record(assetValue, `recoveries[${index}].custodyAfter[${sideIndex}]`)
      const side = sideIndex === 0 ? terms.partySide : terms.counterpartySide
      const required = index === 1 || sideIndex === 0
      equal(
        asset.nextAssetIndex,
        required ? side.assets.length.toString() : '0',
        `recoveries[${index}].custodyAfter[${sideIndex}].nextAssetIndex`,
      )
      equal(
        asset.payoutRecipient,
        required ? side.reclaimRecipient : '0x0000000000000000000000000000000000000000',
        `recoveries[${index}].custodyAfter[${sideIndex}].payoutRecipient`,
      )
      if (required) {
        equal(
          asset.principalBalance,
          side.assets[0]!.amount.toString(),
          `recoveries[${index}].custodyAfter[${sideIndex}].principalBalance`,
        )
        equal(asset.htlcBalance, '0', `recoveries[${index}].custodyAfter[${sideIndex}].htlcBalance`)
      }
    })
  }

  const failure = record(root.resumableFailure, 'resumableFailure')
  equal(failure.stateBefore, 'BothCommitted', 'resumableFailure.stateBefore')
  equal(failure.stateAfter, 'ReclaimPending', 'resumableFailure.stateAfter')
  equal(failure.outcomeSelectionPreserved, true, 'resumableFailure.outcomeSelectionPreserved')
  equal(failure.completedSides, 1, 'resumableFailure.completedSides')
  equal(failure.completedPartyPayoutPreserved, true, 'resumableFailure.completedPartyPayoutPreserved')
  equal(failure.failedSideCursorUnchanged, true, 'resumableFailure.failedSideCursorUnchanged')
  equal(failure.trigger, 'counterparty-htlc-deficit', 'resumableFailure.trigger')

  const permanent = record(root.permanentAssetFailure, 'permanentAssetFailure')
  equal(permanent.failureMode, 'token-reverts', 'permanentAssetFailure.failureMode')
  equal(permanent.failingSide, 'counterparty', 'permanentAssetFailure.failingSide')
  equal(permanent.attempts, 2, 'permanentAssetFailure.attempts')
  equal(permanent.state, 'ReclaimPending', 'permanentAssetFailure.state')
  equal(permanent.expectedSides, 3, 'permanentAssetFailure.expectedSides')
  equal(permanent.completedSides, 1, 'permanentAssetFailure.completedSides')
  equal(permanent.selectedOutcomePreserved, true, 'permanentAssetFailure.selectedOutcomePreserved')
  equal(permanent.otherSideReleased, true, 'permanentAssetFailure.otherSideReleased')
  equal(permanent.otherSideRecipient, terms.partySide.reclaimRecipient, 'permanentAssetFailure.otherSideRecipient')
  equal(
    permanent.failingReclaimRecipient,
    terms.counterpartySide.reclaimRecipient,
    'permanentAssetFailure.failingReclaimRecipient',
  )
  address(permanent.failingHTLC, 'permanentAssetFailure.failingHTLC')
  equal(permanent.failingCursor, '0', 'permanentAssetFailure.failingCursor')
  equal(
    permanent.failingPayoutRecipient,
    '0x0000000000000000000000000000000000000000',
    'permanentAssetFailure.failingPayoutRecipient',
  )
  equal(
    permanent.failingBalance,
    terms.counterpartySide.assets[0]!.amount.toString(),
    'permanentAssetFailure.failingBalance',
  )
  const failureHashes = array(permanent.transactionHashes, 'permanentAssetFailure.transactionHashes')
  if (failureHashes.length !== 2 || failureHashes[0] === failureHashes[1]) {
    fail('permanentAssetFailure.transactionHashes')
  }
  failureHashes.forEach((value, index) => hash(value, `permanentAssetFailure.transactionHashes[${index}]`))

  const terminal = record(root.terminalOutcome, 'terminalOutcome')
  equal(terminal.state, 'Claimed', 'terminalOutcome.state')
  equal(terminal.expectedSides, 3, 'terminalOutcome.expectedSides')
  equal(terminal.completedSides, 3, 'terminalOutcome.completedSides')
  equal(terminal.payoutsFixedByTerms, true, 'terminalOutcome.payoutsFixedByTerms')
  const terminalCustody = array(terminal.custody, 'terminalOutcome.custody')
  const lastIndex = transitions.length - 1
  const lastCustody = array(
    record(transitions[lastIndex], `transitions[${lastIndex}]`).custodyAfter,
    `transitions[${lastIndex}].custodyAfter`,
  )
  if (JSON.stringify(terminalCustody) !== JSON.stringify(lastCustody)) fail('terminalOutcome.custody')
  terminalCustody.forEach((item, index) => {
    const asset = record(item, `terminalOutcome.custody[${index}]`)
    const side = index === 0 ? terms.partySide : terms.counterpartySide
    equal(asset.principal, side.principal, 'terminal principal ' + index)
    equal(asset.recipient, side.recipient, 'terminal recipient ' + index)
    equal(asset.token, side.assets[0]?.target, 'terminal token ' + index)
    equal(asset.recipientBalance, side.assets[0]?.amount.toString(), 'terminal payout ' + index)
    equal(asset.htlcBalance, '0', `terminalOutcome.custody[${index}].htlcBalance`)
    equal(asset.htlcDeployed, true, `terminalOutcome.custody[${index}].htlcDeployed`)
    equal(asset.htlcFunded, true, `terminalOutcome.custody[${index}].htlcFunded`)
    equal(asset.htlcReleased, true, `terminalOutcome.custody[${index}].htlcReleased`)
  })
  rejectSensitiveFields(root)
}

export function assertSameChainArtifactValidator(artifact: RedactedSameChainArtifact): void {
  const corruptions: readonly ((value: Record<string, unknown>) => void)[] = [
    value => { delete value.transitions },
    value => { (value.transitions as unknown[]).reverse() },
    value => { value.tradeId = `0x${'11'.repeat(32)}` },
    value => { (value.terminalOutcome as Record<string, unknown>).state = 'BothCommitted' },
    value => { (value.permanentAssetFailure as Record<string, unknown>).completedSides = 3 },
  ]
  for (const mutate of corruptions) {
    const copy = JSON.parse(JSON.stringify(artifact)) as Record<string, unknown>
    mutate(copy)
    let rejected = false
    try {
      validateSameChainDemoArtifact(copy)
    } catch {
      rejected = true
    }
    if (!rejected) throw new Error('same-chain artifact validator accepted corrupted data')
  }
}

function hydrateTerms(value: unknown): ProtocolTerms {
  const root = record(value, 'terms')
  return {
    partySide: hydrateSide(root.partySide, 'terms.partySide'),
    counterpartySide: hydrateSide(root.counterpartySide, 'terms.counterpartySide'),
  }
}

function hydrateSide(value: unknown, path: string): ProtocolTerms['partySide'] {
  const side = record(value, path)
  const assets = array(side.assets, `${path}.assets`).map((item, index) => {
    const asset = record(item, `${path}.assets[${index}]`)
    return {
      assetType: Number(asset.assetType),
      target: address(asset.target, `${path}.assets[${index}].target`),
      id: BigInt(String(asset.id)),
      amount: BigInt(String(asset.amount)),
    }
  })
  return {
    chainId: BigInt(String(side.chainId)),
    assets,
    principal: address(side.principal, `${path}.principal`),
    authorizationMode: Number(side.authorizationMode),
    principalKeyVersion: BigInt(String(side.principalKeyVersion)),
    reclaimRecipient: address(side.reclaimRecipient, `${path}.reclaimRecipient`),
    recipient: address(side.recipient, `${path}.recipient`),
    commitmentDeadline: BigInt(String(side.commitmentDeadline)),
    claimDeadline: BigInt(String(side.claimDeadline)),
    reclaimRelease: BigInt(String(side.reclaimRelease)),
    commitLock: bytes32(side.commitLock, `${path}.commitLock`),
    delegationPolicy: Number(side.delegationPolicy),
    delegate: address(side.delegate, `${path}.delegate`),
    delegateKeyVersion: BigInt(String(side.delegateKeyVersion)),
    sideNonce: bytes32(side.sideNonce, `${path}.sideNonce`),
  }
}

function rejectSensitiveFields(value: unknown, path = 'artifact'): void {
  if (Array.isArray(value)) {
    value.forEach((item, index) => rejectSensitiveFields(item, `${path}[${index}]`))
    return
  }
  if (value === null || typeof value !== 'object') return
  for (const [key, item] of Object.entries(value)) {
    if (/secret|signature|privatekey|activepqkey|recoverykey/i.test(key)) {
      throw new Error(`same-chain artifact contains sensitive field: ${path}.${key}`)
    }
    rejectSensitiveFields(item, `${path}.${key}`)
  }
}

function record(value: unknown, path: string): Record<string, unknown> {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) fail(path)
  return value as Record<string, unknown>
}

function array(value: unknown, path: string): unknown[] {
  if (!Array.isArray(value)) fail(path)
  return value
}

function equal(actual: unknown, expected: unknown, path: string): void {
  if (actual !== expected) fail(path)
}

function address(value: unknown, path: string): `0x${string}` {
  if (typeof value !== 'string' || !/^0x[0-9a-fA-F]{40}$/.test(value)) fail(path)
  return value as `0x${string}`
}

function bytes32(value: unknown, path: string): Hex32 {
  if (typeof value !== 'string' || !/^0x[0-9a-fA-F]{64}$/.test(value)) fail(path)
  return value as Hex32
}

function hash(value: unknown, path: string): void {
  bytes32(value, path)
}

function fail(path: string): never {
  throw new Error(`invalid same-chain demo artifact: ${path}`)
}

function validateCustody(items: unknown[], path: string): void {
  items.forEach((item, index) => {
    const asset = record(item, path + '[' + index + ']')
    equal(asset.role, index === 0 ? 'alice-asset' : 'bob-asset', path + '[' + index + '].role')
    address(asset.principal, path + '[' + index + '].principal')
    address(asset.recipient, path + '[' + index + '].recipient')
    address(asset.token, path + '[' + index + '].token')
    address(asset.htlc, path + '[' + index + '].htlc')
    for (const field of ['htlcDeployed', 'htlcFunded', 'htlcReleased'] as const) {
      if (typeof asset[field] !== 'boolean') fail(path + '[' + index + '].' + field)
    }
    address(asset.payoutRecipient, path + '[' + index + '].payoutRecipient')
    for (const field of [
      'principalBalance',
      'recipientBalance',
      'htlcBalance',
      'allowance',
      'nextAssetIndex',
    ] as const) {
      if (!/^[0-9]+$/.test(String(asset[field]))) fail(path + '[' + index + '].' + field)
    }
  })
}

function validateSettlementCustody(
  items: unknown[],
  terms: ProtocolTerms,
  transitionIndex: number,
  path: string,
): void {
  items.forEach((item, index) => {
    const asset = record(item, `${path}[${index}]`)
    const released = transitionIndex >= (index === 0 ? 3 : 5)
    const side = index === 0 ? terms.partySide : terms.counterpartySide
    equal(asset.nextAssetIndex, released ? side.assets.length.toString() : '0', `${path}[${index}].nextAssetIndex`)
    equal(
      asset.payoutRecipient,
      released ? side.recipient : '0x0000000000000000000000000000000000000000',
      `${path}[${index}].payoutRecipient`,
    )
  })
}

function validateLifecycle(
  items: unknown[],
  expected: readonly (readonly [boolean, boolean, boolean])[],
  path: string,
): void {
  items.forEach((item, index) => {
    const asset = record(item, `${path}[${index}]`)
    const lifecycle = expected[index]
    if (lifecycle === undefined) fail(`${path}[${index}]`)
    equal(asset.htlcDeployed, lifecycle[0], `${path}[${index}].htlcDeployed`)
    equal(asset.htlcFunded, lifecycle[1], `${path}[${index}].htlcFunded`)
    equal(asset.htlcReleased, lifecycle[2], `${path}[${index}].htlcReleased`)
  })
}

function validateCustodyDeltas(
  before: unknown[],
  after: unknown[],
  deltas: unknown[],
  path: string,
): void {
  validateCustody(after, path + '.custodyAfter')
  after.forEach((item, index) => {
    const previous = record(before[index], path + '.before[' + index + ']')
    const current = record(item, path + '.custodyAfter[' + index + ']')
    const change = record(deltas[index], path + '.balanceDeltas[' + index + ']')
    equal(change.role, current.role, path + '.balanceDeltas[' + index + '].role')
    equal(current.role, previous.role, path + '.custodyAfter[' + index + '].role')
    equal(current.token, previous.token, path + '.custodyAfter[' + index + '].token')
    equal(current.htlc, previous.htlc, path + '.custodyAfter[' + index + '].htlc')
    for (const field of ['principalBalance', 'recipientBalance', 'htlcBalance', 'allowance'] as const) {
      const expected = (BigInt(String(current[field])) - BigInt(String(previous[field]))).toString()
      equal(change[field], expected, path + '.balanceDeltas[' + index + '].' + field)
    }
  })
}
