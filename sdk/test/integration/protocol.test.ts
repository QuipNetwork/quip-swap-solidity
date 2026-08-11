import type {Abi, Address, Hex} from 'viem'
import {beforeAll, describe, expect, it} from 'vitest'
import {
  ActionTag, AuthorizationMode, DelegationPolicy, ExpectedSourceState, WrapperMode,
  assetHash, commitPayloadHash, deriveCommitLock, gateContextId, gateTerms, settlementLock,
  timingPolicyId, tradeId, validateCommitProgression, validateProtocolTerms,
  encodeAuthorizationNonceKey, encodeRegistryNonceKey,
} from '../../src/protocol.js'
import type {ProtocolTerms, SideTerms, TimingPolicy} from '../../src/protocol.js'
import {AssetType} from '../../src/types.js'
import type {Hex32} from '../../src/types.js'
import {connectChain, loadArtifact} from '../helpers/chain.js'
import type {ChainContext} from '../helpers/chain.js'

const RPC_URL = process.env['QUIP_SDK_RPC_URL']
const CHAIN_ID = Number(process.env['QUIP_SDK_CHAIN_ID'] ?? '31337')
if (RPC_URL === undefined) throw new Error('QUIP_SDK_RPC_URL is not set')

const ZERO32 = `0x${'00'.repeat(32)}` as Hex32
const SECRET = `0x${'11'.repeat(32)}` as Hex32
const BOB_SECRET = `0x${'22'.repeat(32)}` as Hex32
const ACTION_NONCE = `0x${'33'.repeat(32)}` as Hex32
const ALICE = '0x1111111111111111111111111111111111111111' as Address
const BOB = '0x2222222222222222222222222222222222222222' as Address
const DELEGATE = '0x3333333333333333333333333333333333333333' as Address
const VERIFIER = '0x4444444444444444444444444444444444444444' as Address
const SWAP = '0x5555555555555555555555555555555555555555' as Address
const TOKEN = '0x6666666666666666666666666666666666666666' as Address

const policy: TimingPolicy = {
  policyVersion: 1n, mode: WrapperMode.CrossChain, partyChainId: 31337n, counterpartyChainId: 31338n,
  partyToCounterpartyDelay: 100n, counterpartyToPartyDelay: 100n,
}

function side(overrides: Partial<SideTerms> = {}): SideTerms {
  return {
    chainId: 31337n,
    assets: [
      {assetType: AssetType.Native, target: '0x0000000000000000000000000000000000000000', id: 0n, amount: 1n},
      {assetType: AssetType.ERC20, target: TOKEN, id: 0n, amount: 2n},
    ],
    principal: ALICE, authorizationMode: AuthorizationMode.QuipWallet, principalKeyVersion: 0n,
    reclaimRecipient: ALICE, recipient: BOB, commitmentDeadline: 100n, claimDeadline: 300n,
    reclaimRelease: 500n, commitLock: ZERO32, delegationPolicy: DelegationPolicy.NotAllowed,
    delegate: '0x0000000000000000000000000000000000000000', delegateKeyVersion: 0n,
    sideNonce: `0x${'aa'.repeat(32)}` as Hex32, ...overrides,
  }
}

function vector(): ProtocolTerms {
  const gate: ProtocolTerms = {
    timingPolicyId: timingPolicyId(policy),
    partySide: side(),
    counterpartySide: side({
      chainId: 31338n, principal: BOB, authorizationMode: AuthorizationMode.RegisteredDirect,
      principalKeyVersion: 7n, reclaimRecipient: BOB, recipient: ALICE, commitmentDeadline: 200n,
      claimDeadline: 350n, delegationPolicy: DelegationPolicy.SpecificDelegate, delegate: DELEGATE,
      delegateKeyVersion: 3n, sideNonce: `0x${'bb'.repeat(32)}` as Hex32,
    }),
  }
  return {...gate, counterpartySide: {...gate.counterpartySide, commitLock: deriveCommitLock(gateContextId(gate), BOB_SECRET)}}
}

const abiTerms = (terms: ProtocolTerms) => ({
  ...terms,
  partySide: {...terms.partySide, assets: terms.partySide.assets.map(a => ({...a}))},
  counterpartySide: {...terms.counterpartySide, assets: terms.counterpartySide.assets.map(a => ({...a}))},
})

let ctx: ChainContext
let harness: Address
let abi: Abi
beforeAll(async () => {
  ctx = connectChain(RPC_URL, CHAIN_ID)
  const artifact = loadArtifact('ProtocolHashingHarness.sol', 'ProtocolHashingHarness')
  abi = artifact.abi
  harness = await ctx.deploy(artifact)
  const progressionArtifact = loadArtifact('ProgressionGateHarness.sol', 'ProgressionGateHarness')
  progressionAbi = progressionArtifact.abi
  progressionHarness = await ctx.deploy(progressionArtifact)
})

const read = async <T>(functionName: string, args: readonly unknown[]): Promise<T> =>
  await ctx.publicClient.readContract({address: harness, abi, functionName, args: args as unknown[]}) as T

let progressionHarness: Address
let progressionAbi: Abi

const progressionRead = async (terms: ProtocolTerms, party: boolean, secret: Hex32): Promise<void> =>
  await ctx.publicClient.readContract({
    address: progressionHarness, abi: progressionAbi, functionName: 'validate',
    args: [abiTerms(terms), party, secret],
  }) as void

const sdkAccepts = (operation: () => void): boolean => {
  try { operation(); return true } catch { return false }
}

const solidityAccepts = async (operation: () => Promise<unknown>): Promise<boolean> => {
  try { await operation(); return true } catch { return false }
}

function deterministicVectors(): Array<{terms: ProtocolTerms, policy: TimingPolicy, secret: Hex32}> {
  return Array.from({length: 16}, (_, index) => {
    const n = BigInt(index + 1)
    const generatedPolicy: TimingPolicy = {
      policyVersion: n, mode: WrapperMode.CrossChain,
      partyChainId: 31_337n + n * 2n, counterpartyChainId: 31_338n + n * 2n,
      partyToCounterpartyDelay: n * 3n, counterpartyToPartyDelay: n * 5n,
    }
    const bobSecret = `0x${(0x1000n + n).toString(16).padStart(64, '0')}` as Hex32
    const base: ProtocolTerms = {
      timingPolicyId: timingPolicyId(generatedPolicy),
      partySide: side({
        chainId: generatedPolicy.partyChainId,
        assets: [{assetType: AssetType.Native, target: '0x0000000000000000000000000000000000000000', id: 0n, amount: n}],
        commitmentDeadline: 100n + n, claimDeadline: 400n + n, reclaimRelease: 900n + n * 10n,
        sideNonce: `0x${(0x2000n + n).toString(16).padStart(64, '0')}` as Hex32,
      }),
      counterpartySide: side({
        chainId: generatedPolicy.counterpartyChainId,
        assets: [{assetType: AssetType.Native, target: '0x0000000000000000000000000000000000000000', id: 0n, amount: n + 100n}],
        principal: BOB, authorizationMode: AuthorizationMode.RegisteredDirect, principalKeyVersion: n,
        reclaimRecipient: BOB, recipient: ALICE, commitmentDeadline: 200n + n,
        claimDeadline: 500n + n, reclaimRelease: 1_000n + n * 10n,
        delegationPolicy: DelegationPolicy.SpecificDelegate, delegate: DELEGATE, delegateKeyVersion: n,
        sideNonce: `0x${(0x3000n + n).toString(16).padStart(64, '0')}` as Hex32,
      }),
    }
    return {policy: generatedPolicy, secret: bobSecret, terms: {...base, counterpartySide: {
      ...base.counterpartySide, commitLock: deriveCommitLock(gateContextId(base), bobSecret),
    }}}
  })
}

describe('v1.1 canonical Solidity/TypeScript vectors', () => {
  it('matches every protocol hash and projection', async () => {
    const terms = vector()
    const encoded = abiTerms(terms)
    const context = gateContextId(terms)
    const trade = tradeId(terms)
    const lock = settlementLock(trade, SECRET)
    expect(await read<Hex32>('exposedTimingPolicyId', [policy])).toBe(timingPolicyId(policy))
    expect(await read<Hex32>('exposedGateContextId', [encoded])).toBe(context)
    expect(await read<Hex32>('exposedCommitLock', [context, BOB_SECRET])).toBe(terms.counterpartySide.commitLock)
    expect(await read<Hex32>('exposedTradeId', [encoded])).toBe(trade)
    expect(await read<Hex32>('exposedSettlementLock', [trade, SECRET])).toBe(lock)
    expect(await read<Hex32>('exposedAssetHash', [encoded, true])).toBe(assetHash(terms.partySide))
    const payload = {terms, party: false, authorizationVerifier: VERIFIER, swapAddress: SWAP, lock,
      expectedSourceState: ExpectedSourceState.Unused, actionNonce: ACTION_NONCE, expiry: 99n}
    expect(await read<Hex32>('exposedCommitPayloadHash', [encoded, false, VERIFIER, SWAP, lock,
      ExpectedSourceState.Unused, ACTION_NONCE, 99n])).toBe(commitPayloadHash(payload))
    expect(await read<Hex>("exposedAuthorizationNonceKey", [31338n, VERIFIER, BOB, 7n, ACTION_NONCE]))
      .toBe(encodeAuthorizationNonceKey(31338n, VERIFIER, BOB, 7n, ACTION_NONCE))
    expect(await read<Hex>("exposedRegistryNonceKey", [31338n, SWAP, BOB, 1, 9n, ACTION_NONCE]))
      .toBe(encodeRegistryNonceKey(31338n, SWAP, BOB, 1, 9n, ACTION_NONCE))
    expect(gateTerms(terms).counterpartySide.commitLock).toBe(ZERO32)
    expect(ActionTag.Commit).toBe(0)
  })

  it('accepts the valid vector and rejects matching malformed vectors', async () => {
    const terms = vector()
    validateProtocolTerms(terms, policy)
    await expect(read('exposedValidateTerms', [abiTerms(terms), policy])).resolves.toBeUndefined()
    const invalid = [
      {...terms, partySide: {...terms.partySide, commitLock: terms.counterpartySide.commitLock}},
      {...terms, timingPolicyId: ZERO32},
      {...terms, partySide: {...terms.partySide, assets: [...terms.partySide.assets].reverse()}},
    ]
    for (const candidate of invalid) {
      expect(() => validateProtocolTerms(candidate, policy)).toThrow()
      await expect(read('exposedValidateTerms', [abiTerms(candidate), policy])).rejects.toThrow()
    }
  })

  it("domain-separates every v1.1 hash family and binds canonical fields", async () => {
    const terms = vector()
    const encoded = abiTerms(terms)
    const context = await read<Hex32>("exposedGateContextId", [encoded])
    const trade = await read<Hex32>("exposedTradeId", [encoded])
    const lock = await read<Hex32>("exposedSettlementLock", [trade, SECRET])
    const commitLock = await read<Hex32>("exposedCommitLock", [context, BOB_SECRET])
    const assets = await read<Hex32>("exposedAssetHash", [encoded, true])
    const timing = await read<Hex32>("exposedTimingPolicyId", [policy])
    expect(new Set([context, trade, lock, commitLock, assets, timing]).size).toBe(6)

    const changed = {...terms, partySide: {...terms.partySide, sideNonce: SECRET}}
    expect(tradeId(changed)).not.toBe(trade)
    expect(gateContextId(changed)).not.toBe(context)
    expect(settlementLock(tradeId(changed), SECRET)).not.toBe(lock)
  })
  it('matches deterministic generated hash vectors', async () => {
    for (const [index, generated] of deterministicVectors().entries()) {
      const {terms, policy: generatedPolicy, secret} = generated
      const encoded = abiTerms(terms)
      const context = gateContextId(terms)
      const trade = tradeId(terms)
      const settlementSecret = `0x${(0x4000n + BigInt(index)).toString(16).padStart(64, '0')}` as Hex32
      const actionNonce = `0x${(0x5000n + BigInt(index)).toString(16).padStart(64, '0')}` as Hex32
      const lock = settlementLock(trade, settlementSecret)
      expect(await read<Hex32>('exposedTimingPolicyId', [generatedPolicy])).toBe(timingPolicyId(generatedPolicy))
      expect(await read<Hex32>('exposedGateContextId', [encoded])).toBe(context)
      expect(await read<Hex32>('exposedCommitLock', [context, secret])).toBe(terms.counterpartySide.commitLock)
      expect(await read<Hex32>('exposedTradeId', [encoded])).toBe(trade)
      expect(await read<Hex32>('exposedSettlementLock', [trade, settlementSecret])).toBe(lock)
      for (const party of [true, false]) {
        const sideTerms = party ? terms.partySide : terms.counterpartySide
        const payload = {terms, party, authorizationVerifier: VERIFIER, swapAddress: SWAP, lock,
          expectedSourceState: ExpectedSourceState.Unused, actionNonce, expiry: 10_000n + BigInt(index)}
        expect(await read<Hex32>('exposedAssetHash', [encoded, party])).toBe(assetHash(sideTerms))
        expect(await read<Hex32>('exposedCommitPayloadHash', [encoded, party, VERIFIER, SWAP, lock,
          ExpectedSourceState.Unused, actionNonce, payload.expiry])).toBe(commitPayloadHash(payload))
      }
    }
  })

  it('matches Solidity term and progression acceptance predicates', async () => {
    for (const generated of deterministicVectors()) {
      const {terms, policy: generatedPolicy, secret} = generated
      const malformed: ProtocolTerms[] = [
        {...terms, timingPolicyId: ZERO32},
        {...terms, partySide: {...terms.partySide, commitLock: terms.counterpartySide.commitLock}},
        {...terms, counterpartySide: {...terms.counterpartySide, commitLock: ZERO32}},
        {...terms, partySide: {...terms.partySide, claimDeadline: terms.partySide.commitmentDeadline}},
        {...terms, partySide: {...terms.partySide, delegationPolicy: DelegationPolicy.NotAllowed}},
      ]
      for (const candidate of [terms, ...malformed]) {
        const sdk = sdkAccepts(() => validateProtocolTerms(candidate, generatedPolicy))
        const solidity = await solidityAccepts(() => read('exposedValidateTerms', [abiTerms(candidate), generatedPolicy]))
        expect(solidity, `ValidTerms parity for ${tradeId(candidate)}`).toBe(sdk)
      }
      const progressionCases: Array<[boolean, Hex32]> = [
        [true, ZERO32], [true, secret], [false, secret], [false, ZERO32], [false, SECRET],
      ]
      for (const [party, candidateSecret] of progressionCases) {
        const sdk = sdkAccepts(() => validateCommitProgression(terms, party, candidateSecret))
        const solidity = await solidityAccepts(() => progressionRead(terms, party, candidateSecret))
        expect(solidity, `progression parity for party=${party}`).toBe(sdk)
      }
    }
  })

})
