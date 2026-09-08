import {encodeDeployData, getAddress} from 'viem'
import type {Address} from 'viem'
import {AssetType, PROTOTYPE_DEPLOYMENT_VERSION, predictPrototypeAddresses, prototypeComponents, prototypeDeploymentSalt} from '../../../src/index.js'
import {assetSupportRegistryAbi} from '../../../src/generated/assetSupportRegistryAbi.js'
import {crossChainWrapperAbi} from '../../../src/generated/crossChainWrapperAbi.js'
import {directAuthorizationAbi} from '../../../src/generated/directAuthorizationAbi.js'
import {sameChainWrapperAbi} from '../../../src/generated/sameChainWrapperAbi.js'
import type {ChainContext, FoundryArtifact} from '../../../test/helpers/chain.js'
import {erc20MockAbi} from '../../../test/helpers/mockAbis.js'

const createXAbi = [{
  type: 'function',
  name: 'deployCreate3',
  stateMutability: 'payable',
  inputs: [{
    name: 'salt',
    type: 'bytes32'
  }, {
    name: 'initCode',
    type: 'bytes'
  }],
  outputs: [{
    name: 'deployed',
    type: 'address'
  }]
}] as const

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
  readonly funding: DemoAssetSetup
}

export interface DemoDeploymentArtifact {
  readonly schema: 'quip-swap-demo-deployment.v1'
  readonly deploymentVersion: typeof PROTOTYPE_DEPLOYMENT_VERSION
  readonly deployer: Address
  readonly owner: Address
  readonly identityRegistration: 'lazy-on-first-commit'
  readonly chains: readonly [DemoChainDeployment, DemoChainDeployment]
}

export async function bootstrapDemoEnvironment(
  chainA: ChainContext,
  chainB: ChainContext,
  load: (
    solFile: string,
    contract: string) => FoundryArtifact,
): Promise<DemoDeploymentArtifact> {
  if (chainA.chainId !== 31_337 || chainB.chainId !== 31_338)
    throw new Error('demo requires chain IDs 31337 and 31338')
  if (chainA.deployer.address !== chainB.deployer.address)
    throw new Error('demo chains require the same deployer')

  const [left, right] = await Promise.all([
    bootstrapChain(chainA, chainA.alice.address, DEMO_ALICE_AMOUNT, load),
    bootstrapChain(chainB, chainB.bob.address, DEMO_BOB_AMOUNT, load),
  ])

  if (JSON.stringify(left.addresses) !== JSON.stringify(right.addresses))
    throw new Error('two-chain address graphs differ')

  return {
    schema: 'quip-swap-demo-deployment.v1',
    deploymentVersion: PROTOTYPE_DEPLOYMENT_VERSION,
    deployer: chainA.deployer.address,
    owner: chainA.deployer.address,
    identityRegistration: 'lazy-on-first-commit',
    chains: [left, right],
  }
}

export async function bootstrapProtocolChain(
  ctx: ChainContext,
  load: (
    solFile: string,
    contract: string) => FoundryArtifact,
): Promise<Omit<DemoChainDeployment, 'funding'>> {
  const createX = await ctx.deploy(load('CreateXMock.sol', 'CreateXMock'))
  const trustedVerifier = await ctx.deploy(load('KeyBoundVerifierMock.sol', 'KeyBoundVerifierMock'))
  const addresses = predictPrototypeAddresses(ctx.deployer.address, createX)
  const definitions: readonly [(typeof prototypeComponents)[number], string, string, readonly unknown[]][] = [
    ['assetSupportRegistry', 'AssetSupportRegistry.sol', 'AssetSupportRegistry', [ctx.deployer.address]],
    ['directAuthorization', 'DirectAuthorization.sol', 'DirectAuthorization', [trustedVerifier]],
    ['swapHTLC', 'SwapHTLC.sol', 'SwapHTLC', []],
    ['crossChainWrapper', 'CrossChainWrapper.sol', 'CrossChainWrapper', [addresses.directAuthorization, addresses.assetSupportRegistry, addresses.swapHTLC, ctx.deployer.address, 10n]],
    ['sameChainWrapper', 'SameChainWrapper.sol', 'SameChainWrapper', [addresses.directAuthorization, addresses.assetSupportRegistry, addresses.swapHTLC, ctx.deployer.address]],
  ]

  for (const [component, solFile, contract, args] of definitions) {
    const index = prototypeComponents.indexOf(component)
    const artifact = load(solFile, contract)
    const initCode = encodeDeployData({
      abi: artifact.abi,
      bytecode: artifact.bytecode,
      args: args as never
    })
    const hash = await ctx.deployer.walletClient.writeContract({
      address: createX,
      abi: createXAbi,
      functionName: 'deployCreate3',
      args: [prototypeDeploymentSalt(ctx.deployer.address, index), initCode],
      chain: ctx.publicClient.chain ?? null,
      account: ctx.deployer.account
    })

    await ctx.publicClient.waitForTransactionReceipt({
      hash
    })

    if ((await ctx.publicClient.getCode({
      address: addresses[component]
    })) === undefined)
      throw new Error(`missing deployed ${contract}`)
  }

  await verifyGraph(ctx, addresses, trustedVerifier)

  const delay = await ctx.publicClient.readContract({
    address: addresses.crossChainWrapper,
    abi: crossChainWrapperAbi,
    functionName: 'FINAL_CLAIM_DELAY'
  })

  if (delay !== 10n)
    throw new Error('local demo final claim delay mismatch')

  return {
    chainId: ctx.chainId,
    createX,
    trustedVerifier,
    addresses
  }
}

async function bootstrapChain(
  ctx: ChainContext,
  principal: Address,
  amount: bigint,
  load: (
    solFile: string,
    contract: string) => FoundryArtifact,
): Promise<DemoChainDeployment> {
  const protocol = await bootstrapProtocolChain(ctx, load)
  const {createX, trustedVerifier, addresses} = protocol
  const funding = await setupDemoFunding(ctx, addresses, principal, amount, load)

  return {
    chainId: ctx.chainId,
    createX,
    trustedVerifier,
    addresses,
    funding
  }
}

async function setupDemoFunding(
  ctx: ChainContext,
  addresses: DemoChainDeployment['addresses'],
  principal: Address,
  amount: bigint,
  load: (
    solFile: string,
    contract: string) => FoundryArtifact,
): Promise<DemoAssetSetup> {
  const token = await ctx.deploy(load('ERC20Mock.sol', 'ERC20Mock'), ['DemoToken', 'DEMO', 18])
  let hash = await ctx.deployer.walletClient.writeContract({
    address: addresses.assetSupportRegistry,
    abi: assetSupportRegistryAbi,
    functionName: 'setAssetSupport',
    args: [AssetType.ERC20, token, true],
    chain: ctx.publicClient.chain ?? null,
    account: ctx.deployer.account
  })

  await ctx.publicClient.waitForTransactionReceipt({
    hash
  })

  const actor = principal === ctx.alice.address ? ctx.alice : principal === ctx.bob.address ? ctx.bob : undefined

  if (actor === undefined)
    throw new Error('demo funding principal is not a configured actor')

  hash = await actor.walletClient.writeContract({
    address: token,
    abi: erc20MockAbi,
    functionName: 'mint',
    args: [principal, amount],
    chain: ctx.publicClient.chain ?? null,
    account: actor.account
  })
  await ctx.publicClient.waitForTransactionReceipt({
    hash
  })
  hash = await actor.walletClient.writeContract({
    address: token,
    abi: erc20MockAbi,
    functionName: 'approve',
    args: [addresses.crossChainWrapper, amount],
    chain: ctx.publicClient.chain ?? null,
    account: actor.account
  })
  await ctx.publicClient.waitForTransactionReceipt({
    hash
  })

  const [balance, allowance] = await Promise.all([
    ctx.publicClient.readContract({
      address: token,
      abi: erc20MockAbi,
      functionName: 'balanceOf',
      args: [principal]
    }),
    ctx.publicClient.readContract({
      address: token,
      abi: erc20MockAbi,
      functionName: 'allowance',
      args: [principal, addresses.crossChainWrapper]
    }),
  ])

  if (balance !== amount || allowance !== amount)
    throw new Error('demo funding or approval mismatch')

  return {
    assetType: 'ERC20',
    token,
    principal,
    owner: principal,
    wrapper: addresses.crossChainWrapper,
    amount: amount.toString(),
    balance: balance.toString(),
    allowance: allowance.toString()
  }
}

async function verifyGraph(
  ctx: ChainContext,
  addresses: DemoChainDeployment['addresses'],
  verifier: Address): Promise<void> {
  const [registryVerifier, crossChainAuthorization, sameChainAuthorization, crossChainOwner, sameChainOwner] = await Promise.all([
    ctx.publicClient.readContract({
      address: addresses.directAuthorization,
      abi: directAuthorizationAbi,
      functionName: 'TRUSTED_VERIFIER'
    }),
    ctx.publicClient.readContract({
      address: addresses.crossChainWrapper,
      abi: crossChainWrapperAbi,
      functionName: 'DIRECT_AUTHORIZATION'
    }),
    ctx.publicClient.readContract({
      address: addresses.sameChainWrapper,
      abi: sameChainWrapperAbi,
      functionName: 'DIRECT_AUTHORIZATION'
    }),
    ctx.publicClient.readContract({
      address: addresses.crossChainWrapper,
      abi: crossChainWrapperAbi,
      functionName: 'owner'
    }),
    ctx.publicClient.readContract({
      address: addresses.sameChainWrapper,
      abi: sameChainWrapperAbi,
      functionName: 'owner'
    }),
  ])

  if (getAddress(registryVerifier) !== verifier || getAddress(crossChainAuthorization) !== addresses.directAuthorization || getAddress(sameChainAuthorization) !== addresses.directAuthorization)
    throw new Error('immutable deployment graph mismatch')
  if (getAddress(crossChainOwner) !== ctx.deployer.address || getAddress(sameChainOwner) !== ctx.deployer.address)
    throw new Error('wrapper owner mismatch')
}

export function serializeDemoDeploymentArtifact(
  artifact: DemoDeploymentArtifact): string {
  return `${JSON.stringify(artifact, null, 2)}\n`
}
