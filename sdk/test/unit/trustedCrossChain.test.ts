import type {Address} from 'viem'
import {describe, expect, it} from 'vitest'
import {AuthorizationMode, DelegationPolicy, WrapperMode, timingPolicyId} from '../../src/protocol.js'
import type {SideTerms, TimingPolicy} from '../../src/protocol.js'
import {TrustedCrossChainWorkflow, submitWithFeeBumps} from '../../src/workflows/trustedCrossChain.js'
import {AssetType} from '../../src/types.js'
import type {Hex32} from '../../src/types.js'
const ZERO = '0x0000000000000000000000000000000000000000' as Address
const ALICE = '0x1111111111111111111111111111111111111111' as Address
const BOB = '0x2222222222222222222222222222222222222222' as Address
const EXECUTOR = '0x3333333333333333333333333333333333333333' as Address
const VERIFIER = '0x4444444444444444444444444444444444444444' as Address
const WRAPPER = '0x5555555555555555555555555555555555555555' as Address
const policy: TimingPolicy = {policyVersion: 1n, mode: WrapperMode.CrossChain, partyChainId: 31337n, counterpartyChainId: 31338n, partyToCounterpartyDelay: 10n, counterpartyToPartyDelay: 10n}
const side = (party: boolean): Omit<SideTerms, 'commitLock' | 'sideNonce'> => ({
  chainId: party ? 31337n : 31338n, assets: [{assetType: AssetType.Native, target: ZERO, id: 0n, amount: 1n}],
  principal: party ? ALICE : BOB, authorizationMode: AuthorizationMode.QuipWallet, principalKeyVersion: 0n,
  reclaimRecipient: party ? ALICE : BOB, recipient: party ? BOB : ALICE,
  commitmentDeadline: party ? 100n : 200n, claimDeadline: party ? 300n : 350n, reclaimRelease: 500n,
  delegationPolicy: party ? DelegationPolicy.NotAllowed : DelegationPolicy.Permissionless,
  delegate: ZERO, delegateKeyVersion: 0n,
})
function workflow(start = 1): TrustedCrossChainWorkflow {
  let n = start
  return new TrustedCrossChainWorkflow({policy, partySide: side(true), counterpartySide: side(false), partyVerifier: VERIFIER, counterpartyVerifier: VERIFIER, partyWrapper: WRAPPER, counterpartyWrapper: WRAPPER, partyExpiry: 90n, counterpartyExpiry: 190n, requiredConfirmations: 3n, selectedBobSubmitter: EXECUTOR, randomHex32: () => `0x${(n++).toString(16).padStart(64, '0')}` as Hex32})
}
const inclusion = {transactionHash: `0x${'aa'.repeat(32)}` as Hex32, blockNumber: 10n, blockHash: `0x${'bb'.repeat(32)}` as Hex32}
describe('trusted cross-chain workflow', () => {
  it('builds exact terms and authorizations before execution', () => {
    const flow = workflow()
    expect(flow.terms.timingPolicyId).toBe(timingPolicyId(policy))
    expect(flow.terms.partySide.sideNonce).not.toBe(flow.terms.counterpartySide.sideNonce)
    expect(flow.partyAuthorization.payload.actionNonce).not.toBe(flow.counterpartyAuthorization.payload.actionNonce)
    expect(flow.terms.counterpartySide.commitLock).not.toMatch(/^0x0+$/)
    expect(flow.partyAuthorization.payload.terms).toBe(flow.terms)
    expect(flow.counterpartyAuthorization.payload.lock).toBe(flow.lock)
    expect(JSON.stringify(flow.status())).not.toContain('secret')
  })
  it('rejects zero protocol randomness before constructing terms or authorizations', () => {
    expect(() => new TrustedCrossChainWorkflow({policy, partySide: side(true), counterpartySide: side(false), partyVerifier: VERIFIER, counterpartyVerifier: VERIFIER, partyWrapper: WRAPPER, counterpartyWrapper: WRAPPER, partyExpiry: 90n, counterpartyExpiry: 190n, requiredConfirmations: 3n, selectedBobSubmitter: EXECUTOR, randomHex32: () => `0x${'00'.repeat(32)}` as Hex32})).toThrow('randomness must be nonzero')
  })
  it('keeps secrets non-enumerable and generates fresh progression secrets across runs', () => {
    const first = workflow(1); const second = workflow(101)
    expect(JSON.stringify(first, (_, value) => typeof value === 'bigint' ? value.toString() : value)).not.toContain(`0x${'01'.padStart(64, '0')}`)
    first.observeAlice(inclusion, 12n); second.observeAlice(inclusion, 12n)
    expect(first.enableBobCommit(EXECUTOR)).not.toBe(second.enableBobCommit(EXECUTOR))
  })
  it('rejects duplicate random material within one run', () => {
    const duplicate = `0x${'11'.repeat(32)}` as Hex32
    expect(() => new TrustedCrossChainWorkflow({policy, partySide: side(true), counterpartySide: side(false), partyVerifier: VERIFIER, counterpartyVerifier: VERIFIER, partyWrapper: WRAPPER, counterpartyWrapper: WRAPPER, partyExpiry: 90n, counterpartyExpiry: 190n, requiredConfirmations: 3n, selectedBobSubmitter: EXECUTOR, randomHex32: () => duplicate})).toThrow('randomness must be independent')
  })
  it('keeps the published preimage disabled through pending, non-finality and reorg', () => {
    const flow = workflow(); flow.markAlicePending()
    expect(flow.status().warning).toContain('pending')
    expect(() => flow.enableBobCommit(EXECUTOR)).toThrow('not final')
    flow.observeAlice(inclusion, 10n)
    expect(flow.status().aliceCommit).toBe('included-non-final')
    flow.rollbackAlice(inclusion.blockHash)
    expect(flow.status().aliceCommit).toBe('pending')
  })
  it('cannot hand off the settlement secret before Bob is committed', async () => {
    const flow = workflow(); flow.observeAlice(inclusion, 12n)
    expect(() => flow.observeFinalReveal()).toThrow('Bob is not committed')
    await expect(flow.handoffFinalClaim([{funded: true, submit: async () => inclusion.transactionHash}]))
      .rejects.toThrow('revealing claim is not final')
    expect(flow.status().stage).toBe('bob-enabled')
  })
  it('rolls finalized inclusion back before enablement and enters recovery after enablement', () => {
    const beforeEnable = workflow(); beforeEnable.observeAlice(inclusion, 12n)
    beforeEnable.rollbackAlice(inclusion.blockHash)
    expect(beforeEnable.status().aliceCommit).toBe('pending')
    expect(beforeEnable.status().bobCommitEnabled).toBe(false)

    const afterEnable = workflow(); afterEnable.observeAlice(inclusion, 12n)
    afterEnable.enableBobCommit(EXECUTOR)
    expect(afterEnable.status().stage).toBe('bob-commit-pending')
    expect(afterEnable.status().warning).toContain('awaiting Bob commit')
    afterEnable.rollbackAlice(inclusion.blockHash)
    expect(afterEnable.status().stage).toBe('recovery')
    expect(afterEnable.status().warning).toContain('after Bob submission was enabled')
    expect(() => afterEnable.markBobCommitted()).toThrow('reorganized after Bob submission was enabled')
    expect(afterEnable.status(500n).reclaimRecommended).toBe(true)
  })
  it('keeps final-claim handoff retryable when funded executors are censored', async () => {
    const flow = workflow(); flow.observeAlice(inclusion, 12n); flow.enableBobCommit(EXECUTOR)
    flow.markBobCommitted(); flow.observeFinalReveal()
    await expect(flow.handoffFinalClaim([
      {funded: true, submit: async () => { throw new Error('censored-a') }},
      {funded: true, submit: async () => { throw new Error('censored-b') }},
    ])).rejects.toThrow()
    expect(flow.status().stage).toBe('reveal-final')
    await expect(flow.handoffFinalClaim([{funded: true, submit: async () => inclusion.transactionHash}]))
      .resolves.toBe(inclusion.transactionHash)
    expect(flow.status().stage).toBe('final-claim')
  })
  it('enables only the selected executor after finality, then hands off final claim', async () => {
    const flow = workflow(); flow.observeAlice(inclusion, 12n)
    expect(flow.status().bobCommitEnabled).toBe(true)
    expect(() => flow.enableBobCommit(BOB)).toThrow('not selected')
    expect(flow.enableBobCommit(EXECUTOR)).not.toMatch(/^0x0+$/)
    expect(() => flow.enableBobCommit(EXECUTOR)).toThrow('already enabled')
    flow.markBobCommitted(); flow.observeFinalReveal()
    const finalHash = await flow.handoffFinalClaim([{funded: false, submit: async () => inclusion.transactionHash}, {funded: true, submit: async secret => { expect(secret).not.toMatch(/^0x0+$/); return inclusion.transactionHash }}]); expect(finalHash).toBe(inclusion.transactionHash); flow.markComplete(); expect(flow.status().stage).toBe('complete')
  })
  it('supports fee-bumped retry and reclaim recovery guidance', async () => {
    const bumps: bigint[] = []
    const result = await submitWithFeeBumps(async (bump, attempt) => { bumps.push(bump); if (attempt < 2) throw new Error('dropped'); return 'mined' }, {attempts: 3, feeBump: attempt => BigInt(100 + attempt * 20)})
    expect(result).toBe('mined'); expect(bumps).toEqual([100n, 120n, 140n])
    const flow = workflow(); flow.enterRecovery(); expect(flow.status(500n).reclaimRecommended).toBe(true)
  })
  it('allows Bob or the named delegate under specific delegation', () => {
    const make = (selectedBobSubmitter: Address): TrustedCrossChainWorkflow => {
      let n = 1
      const counterpartySide = {
        ...side(false),
        delegationPolicy: DelegationPolicy.SpecificDelegate,
        delegate: EXECUTOR,
        delegateKeyVersion: 1n,
      }
      return new TrustedCrossChainWorkflow({
        policy,
        partySide: side(true),
        counterpartySide,
        partyVerifier: VERIFIER,
        counterpartyVerifier: VERIFIER,
        partyWrapper: WRAPPER,
        counterpartyWrapper: WRAPPER,
        partyExpiry: 90n,
        counterpartyExpiry: 190n,
        requiredConfirmations: 3n,
        selectedBobSubmitter,
        randomHex32: () => `0x${(n++).toString(16).padStart(64, '0')}` as Hex32,
      })
    }
    expect(() => make(BOB)).not.toThrow()
    expect(() => make(EXECUTOR)).not.toThrow()
    expect(() => make(ALICE)).toThrow('Bob or the delegate')
  })
})
