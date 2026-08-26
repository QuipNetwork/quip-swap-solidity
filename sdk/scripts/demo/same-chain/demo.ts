import {concatHex, getAddress, keccak256} from 'viem'
import type {Address, Hex} from 'viem'
import {
  AssetType,
  AuthorizationMode,
  DelegationPolicy,
  WrapperMode,
  createProtocolClient,
  settlementLock,
  tradeId,
  validateProtocolTerms,
  wrapperMode,
} from '../../../src/index.js'
import type {Hex32, ProtocolTerms, TimingPolicy} from '../../../src/index.js'
import {assetSupportRegistryAbi} from '../../../src/generated/assetSupportRegistryAbi.js'
import {directAuthorizationAbi} from '../../../src/generated/directAuthorizationAbi.js'
import {sameChainWrapperAbi} from '../../../src/generated/sameChainWrapperAbi.js'
import type {ChainContext, FoundryArtifact} from '../../../test/helpers/chain.js'
import {erc20MockAbi} from '../../../test/helpers/mockAbis.js'
import {bootstrapProtocolChain} from '../shared/environment.js'
import {runSameChainSuccess} from './success.js'
import {runSameChainAdversarial} from './adversarial.js'
import type {SameChainSuccessTrace} from './success.js'
import type {SameChainAdversarialTrace} from './adversarial.js'

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

export interface SameChainParticipantSetup {
  readonly role: 'alice' | 'bob'
  readonly principal: Address
  readonly recipient: Address
  readonly reclaimRecipient: Address
  readonly asset: Address
  readonly htlc: Address
  readonly amount: string
  readonly balance: string
  readonly allowance: string
  readonly supported: true
  readonly authorization: {
    readonly mode: 'registered-direct'
    readonly status: 'pending-lazy-registration'
    readonly expectedActiveKeyVersion: '1'
    readonly activeKeyHash: Hex32
    readonly recoveryKeyHash: Hex32
  }
}

export interface SameChainSetup {
  readonly wrapper: Address
  readonly state: 'Unused'
  readonly alice: SameChainParticipantSetup
  readonly bob: SameChainParticipantSetup
}

export interface SameChainDemoFoundation {
  readonly schema: typeof SAME_CHAIN_DEMO_SCHEMA
  readonly phase: 'claimed'
  readonly mockVerifier: typeof SAME_CHAIN_DEMO_MOCK_VERIFIER
  readonly publicTestSecrets: true
  readonly deployment: Awaited<ReturnType<typeof bootstrapProtocolChain>>
  readonly terms: ProtocolTerms
  readonly tradeId: Hex32
  readonly lock: Hex32
  readonly setup: SameChainSetup
  readonly adversarial: SameChainAdversarialTrace
  readonly success: SameChainSuccessTrace
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
  const lock = settlementLock(id, SETTLEMENT_SECRET)
  onProgress?.('Funding, allowlisting, and approving both same-chain assets')
  await bootstrapSameChainAssets(
    chain,
    deployment.addresses.assetSupportRegistry,
    deployment.addresses.sameChainWrapper,
    terms,
  )
  onProgress?.('Preparing both lazy direct-authorization identities')
  const setup = await readSameChainSetup(chain, deployment, terms, lock)
  const adversarial = await runSameChainAdversarial(chain, deployment, terms, lock, onProgress)
  const success = await runSameChainSuccess(chain, deployment, terms, lock, onProgress)
  return {
    schema: SAME_CHAIN_DEMO_SCHEMA,
    phase: 'claimed',
    mockVerifier: SAME_CHAIN_DEMO_MOCK_VERIFIER,
    publicTestSecrets: true,
    deployment,
    terms,
    tradeId: id,
    lock,
    setup,
    adversarial,
    success,
  }
}

function prototypePQKey(verifier: Address, seed: Hex32): Hex {
  return concatHex([verifier, seed])
}

async function bootstrapSameChainAssets(
  chain: ChainContext,
  registry: Address,
  wrapper: Address,
  terms: ProtocolTerms,
): Promise<void> {
  for (const [actor, side] of [[chain.alice, terms.partySide], [chain.bob, terms.counterpartySide]] as const) {
    const asset = side.assets[0]
    if (asset === undefined || asset.assetType !== AssetType.ERC20) {
      throw new Error('same-chain demo requires one ERC-20 per side')
    }
    let hash = await chain.deployer.walletClient.writeContract({
      address: registry,
      abi: assetSupportRegistryAbi,
      functionName: 'setAssetSupport',
      args: [AssetType.ERC20, asset.target, true],
      chain: chain.publicClient.chain ?? null,
      account: chain.deployer.account,
    })
    await chain.publicClient.waitForTransactionReceipt({hash})
    hash = await actor.walletClient.writeContract({
      address: asset.target,
      abi: erc20MockAbi,
      functionName: 'mint',
      args: [side.principal, asset.amount],
      chain: chain.publicClient.chain ?? null,
      account: actor.account,
    })
    await chain.publicClient.waitForTransactionReceipt({hash})
    hash = await actor.walletClient.writeContract({
      address: asset.target,
      abi: erc20MockAbi,
      functionName: 'approve',
      args: [wrapper, asset.amount],
      chain: chain.publicClient.chain ?? null,
      account: actor.account,
    })
    await chain.publicClient.waitForTransactionReceipt({hash})
  }
}

async function readSameChainSetup(
  chain: ChainContext,
  deployment: Awaited<ReturnType<typeof bootstrapProtocolChain>>,
  terms: ProtocolTerms,
  lock: Hex32,
): Promise<SameChainSetup> {
  const protocol = createProtocolClient({
    addresses: deployment.addresses,
    publicClient: chain.publicClient,
  })
  const participant = async (
    role: 'alice' | 'bob',
    side: ProtocolTerms['partySide'],
    party: boolean,
    activeSeed: Hex32,
    recoverySeed: Hex32,
  ): Promise<SameChainParticipantSetup> => {
    const asset = side.assets[0]
    if (asset === undefined) throw new Error(`${role} has no demo asset`)
    const [balance, allowance, supported, identity, htlc] = await Promise.all([
      chain.publicClient.readContract({
        address: asset.target,
        abi: erc20MockAbi,
        functionName: 'balanceOf',
        args: [side.principal],
      }),
      chain.publicClient.readContract({
        address: asset.target,
        abi: erc20MockAbi,
        functionName: 'allowance',
        args: [side.principal, deployment.addresses.sameChainWrapper],
      }),
      chain.publicClient.readContract({
        address: deployment.addresses.assetSupportRegistry,
        abi: assetSupportRegistryAbi,
        functionName: 'isSupported',
        args: [asset.assetType, asset.target],
      }),
      chain.publicClient.readContract({
        address: deployment.addresses.directAuthorization,
        abi: directAuthorizationAbi,
        functionName: 'identityOf',
        args: [side.principal],
      }),
      protocol.predictSameChainHTLC(terms, party, lock),
    ])
    if (balance !== asset.amount || allowance !== asset.amount || supported !== true) {
      throw new Error(`${role} asset bootstrap mismatch`)
    }
    if (identity.activeKeyVersion !== 0n || identity.recoveryKeyVersion !== 0n || identity.active) {
      throw new Error(`${role} identity registered before its first commit`)
    }
    return {
      role,
      principal: side.principal,
      recipient: side.recipient,
      reclaimRecipient: side.reclaimRecipient,
      asset: asset.target,
      htlc,
      amount: asset.amount.toString(),
      balance: balance.toString(),
      allowance: allowance.toString(),
      supported: true,
      authorization: {
        mode: 'registered-direct',
        status: 'pending-lazy-registration',
        expectedActiveKeyVersion: '1',
        activeKeyHash: keccak256(prototypePQKey(deployment.trustedVerifier, activeSeed)),
        recoveryKeyHash: keccak256(prototypePQKey(deployment.trustedVerifier, recoverySeed)),
      },
    }
  }

  const state = await chain.publicClient.readContract({
    address: deployment.addresses.sameChainWrapper,
    abi: sameChainWrapperAbi,
    functionName: 'state',
    args: [terms, lock],
  })
  if (state !== 0) throw new Error('same-chain state advanced during bootstrap')
  return {
    wrapper: deployment.addresses.sameChainWrapper,
    state: 'Unused',
    alice: await participant('alice', terms.partySide, true, fixed(101), fixed(102)),
    bob: await participant('bob', terms.counterpartySide, false, fixed(103), fixed(104)),
  }
}
