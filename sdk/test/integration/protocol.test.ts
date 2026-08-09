import type {Abi, Address, Hex} from 'viem'
import {beforeAll, describe, expect, it} from 'vitest'
import {
  ActionTag, AuthorizationMode, DelegationPolicy, ExpectedSourceState, WrapperMode,
  assetHash, commitPayloadHash, deriveCommitLock, gateContextId, gateTerms, settlementLock,
  timingPolicyId, tradeId, validateProtocolTerms, encodeAuthorizationNonceKey, encodeRegistryNonceKey,
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
})

const read = async <T>(functionName: string, args: readonly unknown[]): Promise<T> =>
  await ctx.publicClient.readContract({address: harness, abi, functionName, args: args as unknown[]}) as T

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
})
