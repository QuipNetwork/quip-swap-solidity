import type {Address, Hash} from 'viem'
import {
  ExpectedSourceState,
  commitPayloadHash,
  createProtocolClient,
} from '../../../src/index.js'
import type {Hex32, ProtocolTerms, VerifiedCommitAuthorization} from '../../../src/index.js'
import {sameChainWrapperAbi} from '../../../src/generated/sameChainWrapperAbi.js'
import {directAuthorizationAbi} from '../../../src/generated/directAuthorizationAbi.js'
import {extractContractErrorName} from '../../../src/errors.js'
import type {ChainContext} from '../../../test/helpers/chain.js'
import {erc20MockAbi} from '../../../test/helpers/mockAbis.js'
import type {DemoChainDeployment} from '../shared/environment.js'
import {
  SAME_CHAIN_SETTLEMENT_SECRET,
  readSameChainSnapshot,
  submitSameChainDirectCommit,
  submitSameChainLazyCommit,
} from './success.js'
import type {SameChainSnapshot} from './success.js'

const ZERO32 = `0x${'00'.repeat(32)}` as Hex32
const fixed = (value: number): Hex32 => `0x${value.toString(16).padStart(64, '0')}` as Hex32
const burnAbi = [{
  type: 'function',
  name: 'burn',
  stateMutability: 'nonpayable',
  inputs: [{name: 'from', type: 'address'}, {name: 'amount', type: 'uint256'}],
  outputs: [],
}] as const

export interface SameChainNegativeRecord {
  readonly scenario:
    | 'counterparty-first'
    | 'repeated-party-commit'
    | 'mismatched-terms'
    | 'nonzero-progression'
    | 'wrong-authorization-caller'
    | 'wrong-signature'
    | 'replayed-action-nonce'
    | 'commit-at-deadline'
    | 'claim-from-party-committed'
    | 'wrong-settlement-secret'
    | 'claim-at-deadline'
    | 'reclaim-before-both-releases'
    | 'claim-after-terminal'
    | 'reclaim-after-terminal'
  readonly errorName: string
  readonly reverted: true
  readonly stateAndCustodyUnchanged: true
  readonly authorizationNoncePreserved: true
  readonly state: SameChainSnapshot['state']
}

export interface SameChainRecoveryTrace {
  readonly outcome: 'party-only-reclaim' | 'both-reclaim'
  readonly caller: Address
  readonly transactionHash: Hash
  readonly releaseTime: string
  readonly stateBefore: SameChainSnapshot['state']
  readonly stateAfter: 'Reclaimed'
  readonly custodyAfter: SameChainSnapshot['assets']
  readonly fixedReclaimRecipients: true
}

export interface SameChainAtomicRollbackTrace {
  readonly trigger: 'counterparty-reserve-deficit'
  readonly errorName: string
  readonly stateBefore: 'BothCommitted'
  readonly stateAfter: 'BothCommitted'
  readonly firstPayoutRolledBack: true
  readonly reservesAndBalancesUnchanged: true
}

export interface SameChainAdversarialTrace {
  readonly negativeControls: readonly SameChainNegativeRecord[]
  readonly recoveries: readonly [SameChainRecoveryTrace, SameChainRecoveryTrace]
  readonly atomicRollback: SameChainAtomicRollbackTrace
}

interface BoundarySnapshot {
  readonly protocol: SameChainSnapshot
  readonly aliceIdentity: {readonly active: boolean; readonly activeKeyVersion: string; readonly recoveryKeyVersion: string}
  readonly bobIdentity: {readonly active: boolean; readonly activeKeyVersion: string; readonly recoveryKeyVersion: string}
}

export async function runSameChainAdversarial(
  chain: ChainContext,
  deployment: Omit<DemoChainDeployment, 'funding'>,
  terms: ProtocolTerms,
  lock: Hex32,
  onProgress?: (message: string) => void,
): Promise<SameChainAdversarialTrace> {
  onProgress?.('Running isolated same-chain invalid-action controls')
  const negativeControls = await runNegativeControls(chain, deployment, terms, lock)

  onProgress?.('Demonstrating exact one-sided reclaim')
  const partyRecovery = await runPartyRecovery(chain, deployment, terms, lock)

  onProgress?.('Demonstrating atomic two-sided reclaim and payout rollback')
  const {recovery: bothRecovery, rollback} = await runBothRecovery(chain, deployment, terms, lock)

  const final = await boundarySnapshot(chain, deployment, terms, lock)
  if (final.protocol.state !== 'Unused' || final.aliceIdentity.active || final.bobIdentity.active) {
    throw new Error('isolated adversarial branches changed the primary demo state')
  }
  return {negativeControls, recoveries: [partyRecovery, bothRecovery], atomicRollback: rollback}
}

async function runNegativeControls(
  chain: ChainContext,
  deployment: Omit<DemoChainDeployment, 'funding'>,
  terms: ProtocolTerms,
  lock: Hex32,
): Promise<SameChainNegativeRecord[]> {
  const root = await chain.testClient.snapshot()
  const records: SameChainNegativeRecord[] = []
  try {
    records.push(await rejected('counterparty-first', chain, deployment, terms, lock, () =>
      submitSameChainLazyCommit({
        chain,
        deployment,
        terms,
        lock,
        party: false,
        actionNonce: fixed(20),
        operationNonce: fixed(220),
        activeSeed: fixed(103),
        recoverySeed: fixed(104),
      })
    ))

    const deadlineRoot = await chain.testClient.snapshot()
    await chain.warpTo(terms.partySide.commitmentDeadline)
    records.push(await rejected('commit-at-deadline', chain, deployment, terms, lock, () =>
      submitSameChainLazyCommit({
        chain,
        deployment,
        terms,
        lock,
        party: true,
        actionNonce: fixed(21),
        operationNonce: fixed(221),
        activeSeed: fixed(101),
        recoverySeed: fixed(102),
        expiry: terms.partySide.claimDeadline,
      })
    ))
    await chain.testClient.revert({id: deadlineRoot})

    await submitSameChainLazyCommit({
      chain,
      deployment,
      terms,
      lock,
      party: true,
      actionNonce: fixed(5),
      operationNonce: fixed(201),
      activeSeed: fixed(101),
      recoverySeed: fixed(102),
    })

    records.push(await rejected('repeated-party-commit', chain, deployment, terms, lock, () =>
      submitSameChainDirectCommit({
        chain,
        deployment,
        terms,
        lock,
        party: true,
        actionNonce: fixed(22),
        activeSeed: fixed(101),
      })
    ))

    const mismatchedTerms: ProtocolTerms = {
      ...terms,
      counterpartySide: {...terms.counterpartySide, sideNonce: fixed(99)},
    }
    records.push(await rejected('mismatched-terms', chain, deployment, terms, lock, () =>
      submitSameChainLazyCommit({
        chain,
        deployment,
        terms: mismatchedTerms,
        lock,
        party: false,
        actionNonce: fixed(23),
        operationNonce: fixed(223),
        activeSeed: fixed(103),
        recoverySeed: fixed(104),
      })
    ))

    records.push(await rejected('nonzero-progression', chain, deployment, terms, lock, () =>
      submitSameChainLazyCommit({
        chain,
        deployment,
        terms,
        lock,
        party: false,
        actionNonce: fixed(24),
        operationNonce: fixed(224),
        activeSeed: fixed(103),
        recoverySeed: fixed(104),
        bobCommitSecret: fixed(999),
      })
    ))

    records.push(await rejected('wrong-authorization-caller', chain, deployment, terms, lock, () =>
      simulateWrongAuthorizationCaller(chain, deployment, terms, lock)
    ))

    records.push(await rejected('wrong-signature', chain, deployment, terms, lock, () =>
      submitSameChainDirectCommit({
        chain,
        deployment,
        terms,
        lock,
        party: true,
        actionNonce: fixed(25),
        activeSeed: fixed(101),
        invalidSignature: true,
      })
    ))

    records.push(await rejected('replayed-action-nonce', chain, deployment, terms, lock, () =>
      submitSameChainDirectCommit({
        chain,
        deployment,
        terms,
        lock,
        party: true,
        actionNonce: fixed(5),
        activeSeed: fixed(101),
      })
    ))

    records.push(await rejected('claim-from-party-committed', chain, deployment, terms, lock, () =>
      submitClaim(chain, deployment, terms, lock, SAME_CHAIN_SETTLEMENT_SECRET)
    ))

    await submitSameChainLazyCommit({
      chain,
      deployment,
      terms,
      lock,
      party: false,
      actionNonce: fixed(6),
      operationNonce: fixed(202),
      activeSeed: fixed(103),
      recoverySeed: fixed(104),
    })

    records.push(await rejected('reclaim-before-both-releases', chain, deployment, terms, lock, () =>
      submitReclaimBoth(chain, deployment, terms, lock)
    ))

    records.push(await rejected('wrong-settlement-secret', chain, deployment, terms, lock, () =>
      submitClaim(chain, deployment, terms, lock, fixed(998))
    ))

    const claimDeadlineRoot = await chain.testClient.snapshot()
    await chain.warpTo(terms.partySide.claimDeadline)
    records.push(await rejected('claim-at-deadline', chain, deployment, terms, lock, () =>
      submitClaim(chain, deployment, terms, lock, SAME_CHAIN_SETTLEMENT_SECRET)
    ))
    await chain.testClient.revert({id: claimDeadlineRoot})

    await submitClaim(chain, deployment, terms, lock, SAME_CHAIN_SETTLEMENT_SECRET)
    records.push(await rejected('claim-after-terminal', chain, deployment, terms, lock, () =>
      submitClaim(chain, deployment, terms, lock, SAME_CHAIN_SETTLEMENT_SECRET)
    ))
    await chain.warpTo(terms.partySide.reclaimRelease > terms.counterpartySide.reclaimRelease
      ? terms.partySide.reclaimRelease
      : terms.counterpartySide.reclaimRelease)
    records.push(await rejected('reclaim-after-terminal', chain, deployment, terms, lock, () =>
      submitReclaimBoth(chain, deployment, terms, lock)
    ))
    return records
  } finally {
    await chain.testClient.revert({id: root})
  }
}

async function runPartyRecovery(
  chain: ChainContext,
  deployment: Omit<DemoChainDeployment, 'funding'>,
  terms: ProtocolTerms,
  lock: Hex32,
): Promise<SameChainRecoveryTrace> {
  const root = await chain.testClient.snapshot()
  try {
    await submitSameChainLazyCommit({
      chain,
      deployment,
      terms,
      lock,
      party: true,
      actionNonce: fixed(30),
      operationNonce: fixed(230),
      activeSeed: fixed(101),
      recoverySeed: fixed(102),
    })
    const before = await readSameChainSnapshot(chain, deployment.addresses.sameChainWrapper, terms, lock)
    await chain.warpTo(terms.partySide.reclaimRelease)
    const claimant = createProtocolClient({
      addresses: deployment.addresses,
      publicClient: chain.publicClient,
      walletClient: chain.charlie.walletClient,
    })
    const hash = await claimant.reclaimSameChainParty(terms, lock)
    await requireSuccess(chain, hash)
    const after = await readSameChainSnapshot(chain, deployment.addresses.sameChainWrapper, terms, lock)
    const party = after.assets[0]
    if (
      before.state !== 'PartyCommitted'
      || after.state !== 'Reclaimed'
      || party.principalBalance !== terms.partySide.assets[0]!.amount.toString()
      || party.wrapperBalance !== '0'
      || party.reserved !== '0'
    ) {
      throw new Error('party-only reclaim did not restore the signed party asset')
    }
    return {
      outcome: 'party-only-reclaim',
      caller: chain.charlie.address,
      transactionHash: hash,
      releaseTime: terms.partySide.reclaimRelease.toString(),
      stateBefore: before.state,
      stateAfter: 'Reclaimed',
      custodyAfter: after.assets,
      fixedReclaimRecipients: true,
    }
  } finally {
    await chain.testClient.revert({id: root})
  }
}

async function runBothRecovery(
  chain: ChainContext,
  deployment: Omit<DemoChainDeployment, 'funding'>,
  terms: ProtocolTerms,
  lock: Hex32,
): Promise<{readonly recovery: SameChainRecoveryTrace; readonly rollback: SameChainAtomicRollbackTrace}> {
  const root = await chain.testClient.snapshot()
  try {
    await submitSameChainLazyCommit({
      chain,
      deployment,
      terms,
      lock,
      party: true,
      actionNonce: fixed(40),
      operationNonce: fixed(240),
      activeSeed: fixed(101),
      recoverySeed: fixed(102),
    })
    await submitSameChainLazyCommit({
      chain,
      deployment,
      terms,
      lock,
      party: false,
      actionNonce: fixed(41),
      operationNonce: fixed(241),
      activeSeed: fixed(103),
      recoverySeed: fixed(104),
    })
    const release = terms.partySide.reclaimRelease > terms.counterpartySide.reclaimRelease
      ? terms.partySide.reclaimRelease
      : terms.counterpartySide.reclaimRelease
    await chain.warpTo(release)

    const bobAsset = terms.counterpartySide.assets[0]!
    let hash = await chain.deployer.walletClient.writeContract({
      address: bobAsset.target,
      abi: burnAbi,
      functionName: 'burn',
      args: [deployment.addresses.sameChainWrapper, 1n],
      chain: chain.publicClient.chain ?? null,
      account: chain.deployer.account,
    })
    await requireSuccess(chain, hash)

    const beforeFailure = await boundarySnapshot(chain, deployment, terms, lock)
    let failure: unknown
    try {
      await submitReclaimBoth(chain, deployment, terms, lock)
    } catch (error) {
      failure = error
    }
    if (failure === undefined) throw new Error('reserve-deficit reclaim unexpectedly succeeded')
    const afterFailure = await boundarySnapshot(chain, deployment, terms, lock)
    if (stable(beforeFailure) !== stable(afterFailure) || afterFailure.protocol.state !== 'BothCommitted') {
      throw new Error('failed dual reclaim did not roll back atomically')
    }
    const rollback: SameChainAtomicRollbackTrace = {
      trigger: 'counterparty-reserve-deficit',
      errorName: errorLabel(failure),
      stateBefore: 'BothCommitted',
      stateAfter: 'BothCommitted',
      firstPayoutRolledBack: true,
      reservesAndBalancesUnchanged: true,
    }

    hash = await chain.deployer.walletClient.writeContract({
      address: bobAsset.target,
      abi: erc20MockAbi,
      functionName: 'mint',
      args: [deployment.addresses.sameChainWrapper, 1n],
      chain: chain.publicClient.chain ?? null,
      account: chain.deployer.account,
    })
    await requireSuccess(chain, hash)
    const before = await readSameChainSnapshot(chain, deployment.addresses.sameChainWrapper, terms, lock)
    const reclaimHash = await submitReclaimBoth(chain, deployment, terms, lock)
    const after = await readSameChainSnapshot(chain, deployment.addresses.sameChainWrapper, terms, lock)
    if (
      before.state !== 'BothCommitted'
      || after.state !== 'Reclaimed'
      || after.assets[0].principalBalance !== terms.partySide.assets[0]!.amount.toString()
      || after.assets[1].principalBalance !== terms.counterpartySide.assets[0]!.amount.toString()
      || after.assets.some(asset => asset.wrapperBalance !== '0' || asset.reserved !== '0')
    ) {
      throw new Error('two-sided reclaim did not restore both signed assets')
    }
    return {
      rollback,
      recovery: {
        outcome: 'both-reclaim',
        caller: chain.charlie.address,
        transactionHash: reclaimHash,
        releaseTime: release.toString(),
        stateBefore: before.state,
        stateAfter: 'Reclaimed',
        custodyAfter: after.assets,
        fixedReclaimRecipients: true,
      },
    }
  } finally {
    await chain.testClient.revert({id: root})
  }
}

async function rejected(
  scenario: SameChainNegativeRecord['scenario'],
  chain: ChainContext,
  deployment: Omit<DemoChainDeployment, 'funding'>,
  terms: ProtocolTerms,
  lock: Hex32,
  attempt: () => Promise<unknown>,
): Promise<SameChainNegativeRecord> {
  const before = await boundarySnapshot(chain, deployment, terms, lock)
  let failure: unknown
  try {
    await attempt()
  } catch (error) {
    failure = error
  }
  if (failure === undefined) throw new Error(`negative control unexpectedly succeeded: ${scenario}`)
  const after = await boundarySnapshot(chain, deployment, terms, lock)
  if (stable(before) !== stable(after)) throw new Error(`negative control changed state or custody: ${scenario}`)
  return {
    scenario,
    errorName: errorLabel(failure),
    reverted: true,
    stateAndCustodyUnchanged: true,
    authorizationNoncePreserved: true,
    state: after.protocol.state,
  }
}

async function boundarySnapshot(
  chain: ChainContext,
  deployment: Omit<DemoChainDeployment, 'funding'>,
  terms: ProtocolTerms,
  lock: Hex32,
): Promise<BoundarySnapshot> {
  const [protocol, alice, bob] = await Promise.all([
    readSameChainSnapshot(chain, deployment.addresses.sameChainWrapper, terms, lock),
    chain.publicClient.readContract({
      address: deployment.addresses.directAuthorization,
      abi: directAuthorizationAbi,
      functionName: 'identityOf',
      args: [terms.partySide.principal],
    }),
    chain.publicClient.readContract({
      address: deployment.addresses.directAuthorization,
      abi: directAuthorizationAbi,
      functionName: 'identityOf',
      args: [terms.counterpartySide.principal],
    }),
  ])
  return {
    protocol,
    aliceIdentity: {
      active: alice.active,
      activeKeyVersion: alice.activeKeyVersion.toString(),
      recoveryKeyVersion: alice.recoveryKeyVersion.toString(),
    },
    bobIdentity: {
      active: bob.active,
      activeKeyVersion: bob.activeKeyVersion.toString(),
      recoveryKeyVersion: bob.recoveryKeyVersion.toString(),
    },
  }
}

async function simulateWrongAuthorizationCaller(
  chain: ChainContext,
  deployment: Omit<DemoChainDeployment, 'funding'>,
  terms: ProtocolTerms,
  lock: Hex32,
): Promise<void> {
  const actionNonce = fixed(26)
  const expiry = terms.partySide.commitmentDeadline
  const payloadHash = commitPayloadHash({
    terms,
    party: true,
    authorizationVerifier: deployment.addresses.directAuthorization,
    swapAddress: deployment.addresses.sameChainWrapper,
    lock,
    expectedSourceState: ExpectedSourceState.Unused,
    actionNonce,
    expiry,
  })
  const evidence: VerifiedCommitAuthorization = {
    payloadHash,
    wrapperCaller: chain.charlie.address,
    authenticatedSubmitter: terms.partySide.principal,
    authenticatedSubmitterKeyVersion: 1n,
    expectedSourceState: ExpectedSourceState.Unused,
    actionNonce,
    expiry,
  }
  await chain.publicClient.simulateContract({
    address: deployment.addresses.sameChainWrapper,
    abi: sameChainWrapperAbi,
    functionName: 'receiveAuthorizedCommit',
    args: [terms, true, lock, ZERO32, evidence, '0x'],
    account: chain.charlie.address,
  })
}

async function submitClaim(
  chain: ChainContext,
  deployment: Omit<DemoChainDeployment, 'funding'>,
  terms: ProtocolTerms,
  lock: Hex32,
  secret: Hex32,
): Promise<void> {
  const client = createProtocolClient({
    addresses: deployment.addresses,
    publicClient: chain.publicClient,
    walletClient: chain.charlie.walletClient,
  })
  await requireSuccess(chain, await client.claimSameChain(terms, lock, secret))
}

async function submitReclaimBoth(
  chain: ChainContext,
  deployment: Omit<DemoChainDeployment, 'funding'>,
  terms: ProtocolTerms,
  lock: Hex32,
): Promise<Hash> {
  const client = createProtocolClient({
    addresses: deployment.addresses,
    publicClient: chain.publicClient,
    walletClient: chain.charlie.walletClient,
  })
  const hash = await client.reclaimSameChainBoth(terms, lock)
  await requireSuccess(chain, hash)
  return hash
}

async function requireSuccess(chain: ChainContext, hash: Hash): Promise<void> {
  const receipt = await chain.publicClient.waitForTransactionReceipt({hash})
  if (receipt.status !== 'success') throw new Error(`transaction reverted: ${hash}`)
}

function errorLabel(error: unknown): string {
  return extractContractErrorName(error)
    ?? (error instanceof Error && error.message.includes('reverted') ? 'TransactionReverted' : 'Rejected')
}

function stable(value: unknown): string {
  return JSON.stringify(value)
}
