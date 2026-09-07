import type {Address} from 'viem'
import {describe, expect, it} from 'vitest'
import {AuthorizationMode, DelegationPolicy, WrapperMode} from '../../src/protocol.js'
import type {SideTerms, TimingPolicy} from '../../src/protocol.js'
import {TrustedCrossChainWorkflow} from '../../src/workflows/trustedCrossChain.js'
import {AssetType} from '../../src/types.js'
import type {Hex32} from '../../src/types.js'
import {connectChain} from '../helpers/chain.js'
const rpcA = process.env['QUIP_SDK_CHAIN_A_RPC_URL']!
const rpcB = process.env['QUIP_SDK_CHAIN_B_RPC_URL']!
const idA = Number(process.env['QUIP_SDK_CHAIN_A_ID']!); const idB = Number(process.env['QUIP_SDK_CHAIN_B_ID']!)
const a = connectChain(rpcA, idA); const b = connectChain(rpcB, idB)
const ZERO = '0x0000000000000000000000000000000000000000' as Address
const VERIFIER = '0x4444444444444444444444444444444444444444' as Address
const WRAPPER = '0x5555555555555555555555555555555555555555' as Address
const policy: TimingPolicy = {policyVersion: 1n, mode: WrapperMode.CrossChain, partyChainId: BigInt(idA), counterpartyChainId: BigInt(idB), partyToCounterpartyDelay: 10n, counterpartyToPartyDelay: 10n}
const side = (party: boolean): Omit<SideTerms, 'commitLock' | 'sideNonce'> => ({chainId: BigInt(party ? idA : idB), assets: [{assetType: AssetType.Native, target: ZERO, id: 0n, amount: 1n}], principal: party ? a.alice.address : b.bob.address, authorizationMode: AuthorizationMode.QuipWallet, principalKeyVersion: 0n, reclaimRecipient: party ? a.alice.address : b.bob.address, recipient: party ? b.bob.address : a.alice.address, commitmentDeadline: party ? 100n : 200n, claimDeadline: party ? 350n : 300n, reclaimRelease: 500n, delegationPolicy: DelegationPolicy.Permissionless, delegate: ZERO, delegateKeyVersion: 0n})
function flow(): TrustedCrossChainWorkflow {
  let n = 1
  return new TrustedCrossChainWorkflow({policy, partySide: side(true), counterpartySide: side(false), partyVerifier: VERIFIER, counterpartyVerifier: VERIFIER, partyWrapper: WRAPPER, counterpartyWrapper: WRAPPER, partyExpiry: 90n, counterpartyExpiry: 190n, requiredConfirmations: 3n, selectedBobSubmitter: b.charlie.address, randomHex32: () => `0x${(n++).toString(16).padStart(64, '0')}` as Hex32})
}
describe('trusted workflow across two Anvil chains', () => {
  it('handles pending, reorg, finality, reveal, final claim and recovery', async () => {
    const coordinator = flow(); coordinator.markAlicePending()
    const snapshot = await a.testClient.snapshot()
    const tx1 = await a.alice.walletClient.sendTransaction({account: a.alice.account, chain: null, to: a.alice.address, value: 0n})
    const receipt1 = await a.publicClient.waitForTransactionReceipt({hash: tx1})
    const block1 = await a.publicClient.getBlock({blockNumber: receipt1.blockNumber})
    coordinator.observeAlice({transactionHash: tx1, blockNumber: receipt1.blockNumber, blockHash: block1.hash}, receipt1.blockNumber)
    expect(coordinator.status().aliceCommit).toBe('included-non-final')
    await a.testClient.revert({id: snapshot}); coordinator.rollbackAlice(block1.hash)
    expect(coordinator.status().aliceCommit).toBe('pending')

    const tx2 = await a.alice.walletClient.sendTransaction({account: a.alice.account, chain: null, to: a.alice.address, value: 0n})
    const receipt2 = await a.publicClient.waitForTransactionReceipt({hash: tx2})
    const block2 = await a.publicClient.getBlock({blockNumber: receipt2.blockNumber})
    await a.testClient.mine({blocks: 2}); const head = receipt2.blockNumber + 2n
    coordinator.observeAlice({transactionHash: tx2, blockNumber: receipt2.blockNumber, blockHash: block2.hash}, head)
    expect(coordinator.status().bobCommitEnabled).toBe(true)
    coordinator.enableBobCommit(b.charlie.address); coordinator.markBobCommitted()
    await b.testClient.mine({blocks: 1})
    coordinator.observeFinalReveal(); await coordinator.handoffFinalClaim([{funded: true, submit: async () => tx2}]); coordinator.markComplete()
    expect(coordinator.status().stage).toBe('complete')

    const recovery = flow(); recovery.enterRecovery()
    expect(recovery.status(500n).reclaimRecommended).toBe(true)
  })
})
