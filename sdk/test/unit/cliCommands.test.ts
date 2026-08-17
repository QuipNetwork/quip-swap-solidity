import type {Address} from 'viem'
import {describe, expect, it} from 'vitest'
import {
  applyPartyCommand,
  AuthorizationMode,
  cliCommandSpecs,
  cliWorkflowCommands,
  DelegationPolicy,
  prepareTradeCommand,
  WrapperMode,
} from '../../src/index.js'
import type {SideTerms, TimingPolicy} from '../../src/index.js'
import {AssetType} from '../../src/index.js'
import type {Hex32} from '../../src/index.js'

const ZERO = '0x0000000000000000000000000000000000000000' as Address
const ALICE = '0x1111111111111111111111111111111111111111' as Address
const BOB = '0x2222222222222222222222222222222222222222' as Address
const EXECUTOR = '0x3333333333333333333333333333333333333333' as Address
const VERIFIER = '0x4444444444444444444444444444444444444444' as Address
const WRAPPER = '0x5555555555555555555555555555555555555555' as Address
const hexN = (n: number) => `0x${n.toString(16).padStart(64, '0')}` as Hex32
const policy: TimingPolicy = {policyVersion: 1n, mode: WrapperMode.CrossChain, partyChainId: 31337n, counterpartyChainId: 31338n, partyToCounterpartyDelay: 10n, counterpartyToPartyDelay: 10n}
const side = (party: boolean): Omit<SideTerms, 'commitLock' | 'sideNonce'> => ({chainId: party ? 31337n : 31338n, assets: [{assetType: AssetType.Native, target: ZERO, id: 0n, amount: 1n}], principal: party ? ALICE : BOB, authorizationMode: AuthorizationMode.QuipWallet, principalKeyVersion: 0n, reclaimRecipient: party ? ALICE : BOB, recipient: party ? BOB : ALICE, commitmentDeadline: party ? 100n : 200n, claimDeadline: party ? 300n : 350n, reclaimRelease: 500n, delegationPolicy: party ? DelegationPolicy.NotAllowed : DelegationPolicy.Permissionless, delegate: ZERO, delegateKeyVersion: 0n})
function prepared() {
  let n = 1
  return prepareTradeCommand({workflow: {policy, partySide: side(true), counterpartySide: side(false), partyVerifier: VERIFIER, counterpartyVerifier: VERIFIER, partyWrapper: WRAPPER, counterpartyWrapper: WRAPPER, partyExpiry: 90n, counterpartyExpiry: 190n, requiredConfirmations: 3n, selectedBobSubmitter: EXECUTOR, randomHex32: () => hexN(n++)}, finalClaimExecutors: [EXECUTOR], secretMode: 'unsafe-demo'})
}
const inclusion = {transactionHash: hexN(20), blockNumber: '10', blockHash: hexN(21)}

describe('trusted workflow CLI commands', () => {
  it('wires the complete party-separated transition sequence', () => {
    const initial = prepared()
    let alice = applyPartyCommand(initial.alice.publicState, initial.alice.secretState, {command: 'mark-alice-pending'})
    alice = applyPartyCommand(alice.publicState, alice.secretState, {command: 'mark-alice-included-non-final', inclusion})
    alice = applyPartyCommand(alice.publicState, alice.secretState, {command: 'mark-alice-final', inclusion})
    alice = applyPartyCommand(alice.publicState, alice.secretState, {command: 'release-bob-secret', aliceAddress: ALICE})
    expect(alice.publicState.stage).toBe('bob-commit-pending')
    expect(alice.transfer).toBeDefined()

    let bob = applyPartyCommand(initial.bob.publicState, initial.bob.secretState, {command: 'submit-bob-commit', transfer: alice.transfer!, transactionHash: hexN(22)})
    expect(bob.publicState.stage).toBe('bob-committed')
    bob = applyPartyCommand(bob.publicState, bob.secretState, {command: 'observe-reveal', settlementSecret: initial.alice.secretState.settlementSecret, inclusion})
    bob = applyPartyCommand(bob.publicState, bob.secretState, {command: 'handoff-final-claim', executor: EXECUTOR, transactionHash: hexN(23)})
    bob = applyPartyCommand(bob.publicState, bob.secretState, {command: 'mark-complete'})
    expect(bob.publicState.stage).toBe('complete')
    expect(bob.publicState.generation).toBe(5)
  })

  it('rejects early release, wrong-party commands, invalid transfers, and premature reveal', () => {
    const initial = prepared()
    expect(() => applyPartyCommand(initial.alice.publicState, initial.alice.secretState, {command: 'release-bob-secret', aliceAddress: ALICE})).toThrow('not final')
    expect(applyPartyCommand(initial.bob.publicState, initial.bob.secretState, {command: 'mark-alice-pending'}).publicState.aliceCommit.status).toBe('pending')
    expect(() => applyPartyCommand(initial.bob.publicState, initial.bob.secretState, {command: 'observe-reveal', settlementSecret: initial.alice.secretState.settlementSecret, inclusion})).toThrow('not committed')
  })

  it('keeps status read-only and supports party-local recovery', () => {
    const initial = prepared()
    const status = applyPartyCommand(initial.alice.publicState, initial.alice.secretState, {command: 'status'})
    expect(status.publicState).toBe(initial.alice.publicState)
    const recovery = applyPartyCommand(status.publicState, status.secretState, {command: 'enter-recovery', reason: 'RPC disagreement'})
    expect(recovery.publicState).toMatchObject({stage: 'recovery', recovery: {active: true, reason: 'RPC disagreement'}})
  })

  it('keeps internal reducer commands separate from the public console surface', () => {
    expect(cliWorkflowCommands).toContain('mark-alice-final')
    expect(cliCommandSpecs.map(spec => spec.command)).not.toContain('mark-alice-final')
  })
})
