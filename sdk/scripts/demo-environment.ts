import {encodeDeployData, getAddress} from 'viem'
import type {Address, Hex} from 'viem'
import {
  BASE_SEPOLIA_TO_OP_SEPOLIA_POLICY,
  BASE_SEPOLIA_TO_OP_SEPOLIA_POLICY_ID,
  OP_SEPOLIA_TO_BASE_SEPOLIA_POLICY,
  OP_SEPOLIA_TO_BASE_SEPOLIA_POLICY_ID,
  PROTOTYPE_DEPLOYMENT_VERSION,
  AssetType,
  WrapperMode,
  predictPrototypeAddresses,
  prototypeComponents,
  prototypeDeploymentSalt,
  timingPolicyId,
} from '../src/index.js'
import {assetSupportRegistryAbi} from '../src/generated/assetSupportRegistryAbi.js'
import {crossChainWrapperAbi} from '../src/generated/crossChainWrapperAbi.js'
import {pqAuthorizationGatewayAbi} from '../src/generated/pqAuthorizationGatewayAbi.js'
import {pqIdentityRegistryAbi} from '../src/generated/pqIdentityRegistryAbi.js'
import {sameChainWrapperAbi} from '../src/generated/sameChainWrapperAbi.js'
import {timingPolicyRegistryAbi} from '../src/generated/timingPolicyRegistryAbi.js'
import type {TimingPolicy} from '../src/index.js'
import type {ChainContext, FoundryArtifact} from '../test/helpers/chain.js'
import {erc20MockAbi} from '../test/helpers/mockAbis.js'

const createXAbi = [{type: 'function', name: 'deployCreate3', stateMutability: 'payable', inputs: [{name: 'salt', type: 'bytes32'}, {name: 'initCode', type: 'bytes'}], outputs: [{name: 'deployed', type: 'address'}]}] as const

export const DEMO_ALICE_AMOUNT = 10n * 10n ** 18n
export const DEMO_BOB_AMOUNT = 20n * 10n ** 18n

export interface DemoAssetSetup {
  readonly assetType: 'ERC20'
  readonly token: Address
  readonly principal: Address
  readonly owner: Address
  readonly wrapper: Address
  readonly amount: string
  readonly balance: string
  readonly allowance: string
}

export interface DemoChainDeployment {
  readonly chainId: number
  readonly createX: Address
  readonly trustedVerifier: Address
  readonly addresses: Readonly<Record<(typeof prototypeComponents)[number], Address>>
  readonly localSameChainPolicyId: Hex
  readonly funding: DemoAssetSetup
}

export interface DemoDeploymentArtifact {
  readonly schema: 'quip-swap-demo-deployment.v1'
  readonly deploymentVersion: typeof PROTOTYPE_DEPLOYMENT_VERSION
  readonly deployer: Address
  readonly identityRegistration: 'lazy-on-first-commit'
  readonly canonicalPolicyIds: readonly [Hex, Hex]
  readonly chains: readonly [DemoChainDeployment, DemoChainDeployment]
}

export async function bootstrapDemoEnvironment(
  chainA: ChainContext,
  chainB: ChainContext,
  load: (solFile: string, contract: string) => FoundryArtifact,
): Promise<DemoDeploymentArtifact> {
  if (chainA.chainId !== 31_337 || chainB.chainId !== 31_338) throw new Error('demo requires chain IDs 31337 and 31338')
  if (chainA.deployer.address !== chainB.deployer.address) throw new Error('demo chains require the same deployer')
  const [left, right] = await Promise.all([
    bootstrapChain(chainA, chainA.alice.address, DEMO_ALICE_AMOUNT, load),
    bootstrapChain(chainB, chainB.bob.address, DEMO_BOB_AMOUNT, load),
  ])
  if (JSON.stringify(left.addresses) !== JSON.stringify(right.addresses)) throw new Error('two-chain address graphs differ')
  return {
    schema: 'quip-swap-demo-deployment.v1',
    deploymentVersion: PROTOTYPE_DEPLOYMENT_VERSION,
    deployer: chainA.deployer.address,
    identityRegistration: 'lazy-on-first-commit',
    canonicalPolicyIds: [BASE_SEPOLIA_TO_OP_SEPOLIA_POLICY_ID, OP_SEPOLIA_TO_BASE_SEPOLIA_POLICY_ID],
    chains: [left, right],
  }
}

async function bootstrapChain(
  ctx: ChainContext,
  principal: Address,
  amount: bigint,
  load: (solFile: string, contract: string) => FoundryArtifact,
): Promise<DemoChainDeployment> {
  const createX = await ctx.deploy(load('CreateXMock.sol', 'CreateXMock'))
  const trustedVerifier = await ctx.deploy(load('KeyBoundVerifierMock.sol', 'KeyBoundVerifierMock'))
  const addresses = predictPrototypeAddresses(ctx.deployer.address, createX)
  const definitions: readonly [string, string, readonly unknown[]][] = [
    ['AssetSupportRegistry.sol', 'AssetSupportRegistry', [ctx.deployer.address]],
    ['TimingPolicyRegistry.sol', 'TimingPolicyRegistry', [ctx.deployer.address]],
    ['PQIdentityRegistry.sol', 'PQIdentityRegistry', [trustedVerifier]],
    ['PQAuthorizationGateway.sol', 'PQAuthorizationGateway', [addresses.identityRegistry]],
    ['CrossChainWrapper.sol', 'CrossChainWrapper', [addresses.authorizationGateway, addresses.timingPolicyRegistry, addresses.assetSupportRegistry]],
    ['SameChainWrapper.sol', 'SameChainWrapper', [addresses.authorizationGateway, addresses.timingPolicyRegistry, addresses.assetSupportRegistry]],
  ]
  for (const [index, [solFile, contract, args]] of definitions.entries()) {
    const artifact = load(solFile, contract)
    const initCode = encodeDeployData({abi: artifact.abi, bytecode: artifact.bytecode, args: args as never})
    const hash = await ctx.deployer.walletClient.writeContract({address: createX, abi: createXAbi, functionName: 'deployCreate3', args: [prototypeDeploymentSalt(ctx.deployer.address, index), initCode], chain: ctx.publicClient.chain ?? null, account: ctx.deployer.account})
    await ctx.publicClient.waitForTransactionReceipt({hash})
    const component = prototypeComponents[index]
    if (component === undefined || (await ctx.publicClient.getCode({address: addresses[component]})) === undefined) throw new Error(`missing deployed ${contract}`)
  }
  const localPolicy: TimingPolicy = {policyVersion: 1n, mode: WrapperMode.SameChain, partyChainId: BigInt(ctx.chainId), counterpartyChainId: BigInt(ctx.chainId), partyToCounterpartyDelay: 0n, counterpartyToPartyDelay: 0n}
  const policies = [[BASE_SEPOLIA_TO_OP_SEPOLIA_POLICY_ID, BASE_SEPOLIA_TO_OP_SEPOLIA_POLICY], [OP_SEPOLIA_TO_BASE_SEPOLIA_POLICY_ID, OP_SEPOLIA_TO_BASE_SEPOLIA_POLICY], [timingPolicyId(localPolicy), localPolicy]] as const
  for (const [policyId, policy] of policies) {
    const hash = await ctx.deployer.walletClient.writeContract({address: addresses.timingPolicyRegistry, abi: timingPolicyRegistryAbi, functionName: 'registerPolicy', args: [policyId, policy], chain: ctx.publicClient.chain ?? null, account: ctx.deployer.account})
    await ctx.publicClient.waitForTransactionReceipt({hash})
  }
  await verifyGraph(ctx, addresses, trustedVerifier)
  const funding = await setupDemoFunding(ctx, addresses, principal, amount, load)
  return {chainId: ctx.chainId, createX, trustedVerifier, addresses, localSameChainPolicyId: timingPolicyId(localPolicy), funding}
}

async function setupDemoFunding(
  ctx: ChainContext,
  addresses: DemoChainDeployment['addresses'],
  principal: Address,
  amount: bigint,
  load: (solFile: string, contract: string) => FoundryArtifact,
): Promise<DemoAssetSetup> {
  const token = await ctx.deploy(load('ERC20Mock.sol', 'ERC20Mock'), ['DemoToken', 'DEMO', 18])
  let hash = await ctx.deployer.walletClient.writeContract({address: addresses.assetSupportRegistry, abi: assetSupportRegistryAbi, functionName: 'setAssetSupport', args: [AssetType.ERC20, token, true], chain: ctx.publicClient.chain ?? null, account: ctx.deployer.account})
  await ctx.publicClient.waitForTransactionReceipt({hash})
  const actor = principal === ctx.alice.address ? ctx.alice : principal === ctx.bob.address ? ctx.bob : undefined
  if (actor === undefined) throw new Error('demo funding principal is not a configured actor')
  hash = await actor.walletClient.writeContract({address: token, abi: erc20MockAbi, functionName: 'mint', args: [principal, amount], chain: ctx.publicClient.chain ?? null, account: actor.account})
  await ctx.publicClient.waitForTransactionReceipt({hash})
  hash = await actor.walletClient.writeContract({address: token, abi: erc20MockAbi, functionName: 'approve', args: [addresses.crossChainWrapper, amount], chain: ctx.publicClient.chain ?? null, account: actor.account})
  await ctx.publicClient.waitForTransactionReceipt({hash})
  const [balance, allowance] = await Promise.all([
    ctx.publicClient.readContract({address: token, abi: erc20MockAbi, functionName: 'balanceOf', args: [principal]}),
    ctx.publicClient.readContract({address: token, abi: erc20MockAbi, functionName: 'allowance', args: [principal, addresses.crossChainWrapper]}),
  ])
  if (balance !== amount || allowance !== amount) throw new Error('demo funding or approval mismatch')
  return {assetType: 'ERC20', token, principal, owner: principal, wrapper: addresses.crossChainWrapper, amount: amount.toString(), balance: balance.toString(), allowance: allowance.toString()}
}

async function verifyGraph(ctx: ChainContext, addresses: DemoChainDeployment['addresses'], verifier: Address): Promise<void> {
  const registryVerifier = await ctx.publicClient.readContract({address: addresses.identityRegistry, abi: pqIdentityRegistryAbi, functionName: 'TRUSTED_VERIFIER'})
  const gatewayRegistry = await ctx.publicClient.readContract({address: addresses.authorizationGateway, abi: pqAuthorizationGatewayAbi, functionName: 'REGISTRY'})
  const crossChainGateway = await ctx.publicClient.readContract({address: addresses.crossChainWrapper, abi: crossChainWrapperAbi, functionName: 'DIRECT_GATEWAY'})
  const sameChainGateway = await ctx.publicClient.readContract({address: addresses.sameChainWrapper, abi: sameChainWrapperAbi, functionName: 'DIRECT_GATEWAY'})
  if (getAddress(registryVerifier) !== verifier || getAddress(gatewayRegistry) !== addresses.identityRegistry || getAddress(crossChainGateway) !== addresses.authorizationGateway || getAddress(sameChainGateway) !== addresses.authorizationGateway) throw new Error('immutable deployment graph mismatch')
}

export function serializeDemoDeploymentArtifact(artifact: DemoDeploymentArtifact): string {
  return `${JSON.stringify(artifact, null, 2)}\n`
}
