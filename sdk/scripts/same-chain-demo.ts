import {getAddress} from 'viem'
import type {Address} from 'viem'
import {
  AssetType,
  AuthorizationMode,
  DelegationPolicy,
  WrapperMode,
  settlementLock,
  tradeId,
  validateProtocolTerms,
  wrapperMode,
} from '../src/index.js'
import type {Hex32, ProtocolTerms, TimingPolicy} from '../src/index.js'
import {bootstrapProtocolChain} from './demo-environment.js'
import type {ChainContext, FoundryArtifact} from '../test/helpers/chain.js'

export const SAME_CHAIN_DEMO_SCHEMA = 'quip-swap-same-chain-demo.v1' as const
export const SAME_CHAIN_DEMO_CHAIN_ID = 31_337
export const SAME_CHAIN_DEMO_MOCK_VERIFIER = true as const

const ZERO_ADDRESS = getAddress('0x0000000000000000000000000000000000000000')
const ZERO32 = `0x${'00'.repeat(32)}` as Hex32
const fixed = (value: number): Hex32 => `0x${value.toString(16).padStart(64, '0')}` as Hex32
const SETTLEMENT_SECRET = fixed(1)

export interface SameChainTermsInput {
  readonly chainId: bigint
  readonly alice: Address
  readonly bob: Address
  readonly aliceToken: Address
  readonly bobToken: Address
  readonly now: bigint
}

export interface SameChainDemoFoundation {
  readonly schema: typeof SAME_CHAIN_DEMO_SCHEMA
  readonly phase: 'prepared'
  readonly mockVerifier: typeof SAME_CHAIN_DEMO_MOCK_VERIFIER
  readonly deployment: Awaited<ReturnType<typeof bootstrapProtocolChain>>
  readonly terms: ProtocolTerms
  readonly tradeId: Hex32
  readonly lock: Hex32
}

export function sameChainDemoPolicy(chainId: bigint): TimingPolicy {
  return {
    policyVersion: 1n,
    mode: WrapperMode.SameChain,
    partyChainId: chainId,
    counterpartyChainId: chainId,
    partyToCounterpartyDelay: 0n,
    counterpartyToPartyDelay: 0n,
  }
}

export function buildSameChainDemoTerms(input: SameChainTermsInput): ProtocolTerms {
  return {
    partySide: {
      chainId: input.chainId,
      assets: [{assetType: AssetType.ERC20, target: input.aliceToken, id: 0n, amount: 10n * 10n ** 18n}],
      principal: input.alice,
      authorizationMode: AuthorizationMode.RegisteredDirect,
      principalKeyVersion: 1n,
      reclaimRecipient: input.alice,
      recipient: input.bob,
      commitmentDeadline: input.now + 100n,
      claimDeadline: input.now + 1_000n,
      reclaimRelease: input.now + 1_400n,
      commitLock: ZERO32,
      delegationPolicy: DelegationPolicy.NotAllowed,
      delegate: ZERO_ADDRESS,
      delegateKeyVersion: 0n,
      sideNonce: fixed(2),
    },
    counterpartySide: {
      chainId: input.chainId,
      assets: [{assetType: AssetType.ERC20, target: input.bobToken, id: 0n, amount: 20n * 10n ** 18n}],
      principal: input.bob,
      authorizationMode: AuthorizationMode.RegisteredDirect,
      principalKeyVersion: 1n,
      reclaimRecipient: input.bob,
      recipient: input.alice,
      commitmentDeadline: input.now + 200n,
      claimDeadline: input.now + 1_100n,
      reclaimRelease: input.now + 1_300n,
      commitLock: ZERO32,
      delegationPolicy: DelegationPolicy.NotAllowed,
      delegate: ZERO_ADDRESS,
      delegateKeyVersion: 0n,
      sideNonce: fixed(3),
    },
  }
}

export async function runSameChainDemoFoundation(
  chain: ChainContext,
  load: (solFile: string, contract: string) => FoundryArtifact,
  onProgress?: (message: string) => void,
): Promise<SameChainDemoFoundation> {
  if (chain.chainId !== SAME_CHAIN_DEMO_CHAIN_ID) {
    throw new Error(`same-chain demo requires chain ID ${SAME_CHAIN_DEMO_CHAIN_ID}`)
  }
  onProgress?.('Deploying the current four-contract protocol stack')
  const deployment = await bootstrapProtocolChain(chain, load)
  await chain.warpTo(4_000_000_000n)

  onProgress?.('Deploying deterministic term assets')
  const aliceToken = await chain.deploy(load('ERC20Mock.sol', 'ERC20Mock'), ['AliceDemoToken', 'ALICE', 18])
  const bobToken = await chain.deploy(load('ERC20Mock.sol', 'ERC20Mock'), ['BobDemoToken', 'BOB', 18])
  const now = await chain.now()
  const terms = buildSameChainDemoTerms({
    chainId: BigInt(chain.chainId),
    alice: chain.alice.address,
    bob: chain.bob.address,
    aliceToken,
    bobToken,
    now,
  })
  const policy = sameChainDemoPolicy(BigInt(chain.chainId))
  validateProtocolTerms(terms, policy)
  if (wrapperMode(terms) !== WrapperMode.SameChain) throw new Error('prepared terms are not same-chain')

  onProgress?.('Binding canonical terms to the settlement lock')
  const id = tradeId(terms)
  return {
    schema: SAME_CHAIN_DEMO_SCHEMA,
    phase: 'prepared',
    mockVerifier: SAME_CHAIN_DEMO_MOCK_VERIFIER,
    deployment,
    terms,
    tradeId: id,
    lock: settlementLock(id, SETTLEMENT_SECRET),
  }
}

export function serializeSameChainDemoFoundation(artifact: SameChainDemoFoundation): string {
  return `${JSON.stringify(artifact, (_, value: unknown) => typeof value === 'bigint' ? value.toString() : value, 2)}\n`
}
