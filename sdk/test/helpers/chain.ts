/**
 * Per-chain test context: Viem clients, Foundry-artifact deployment, time
 * control, and the standard contract fixture used by integration tests.
 *
 * Deployment order in {@link deployFixture}:
 * 1. WalletFactoryMock (a settable registry backing the wallet commit
 *    route), then Omnibus with the two-argument constructor
 *    (owner, walletFactory); an AcceptAll ERC-7913 VerifierMock is deployed
 *    and activated post-deploy via setVerifierActivity (owner action)
 * 2. mock tokens (ERC20 / ERC721 / ERC1155 / fee-on-transfer ERC20)
 * 3. harnesses (TermsLibHarness, OmnibusHarness) for differential tests
 *
 * Timestamp control: the protocol's windows are judged against
 * block.timestamp, so tests use `evm_setNextBlockTimestamp` + mining
 * (mirroring the `vm.warp` anchors in test/Omnibus/Omnibus.t.sol) rather
 * than waiting on wall-clock time.
 *
 * Test infrastructure only — never exported from the SDK package.
 */
import {readFileSync} from 'node:fs'
import {dirname, join} from 'node:path'
import {fileURLToPath} from 'node:url'
import {createPublicClient, createTestClient, createWalletClient, defineChain, getAddress, http, stringToHex} from 'viem'
import type {Abi, Address, Hex, PublicClient, TestClient, WalletClient} from 'viem'
import {privateKeyToAccount} from 'viem/accounts'
import type {PrivateKeyAccount} from 'viem/accounts'

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..')

/**
 * Anvil's standard, PUBLICLY KNOWN development mnemonic accounts.
 * These keys are a documented Anvil fixture — safe for local tests only,
 * never funded or used anywhere real.
 */
export const ANVIL_KEYS = [
  '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80', // deployer / owner
  '0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d', // alice
  '0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a', // bob
  '0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6', // charlie (third-party actor)
] as const

/** A Foundry artifact's ABI and deployable bytecode. */
export interface FoundryArtifact {
  readonly abi: Abi
  readonly bytecode: Hex
}

/**
 * Loads a Foundry artifact (ABI + creation bytecode) from `out/`.
 *
 * Test-only: deployment bytecode is intentionally NOT part of the SDK's
 * public API; only this test helper reads it.
 *
 * @param solFile - The source file name, e.g. `'Omnibus.sol'`.
 * @param contract - The contract name, e.g. `'Omnibus'`.
 */
export function loadArtifact(solFile: string, contract: string): FoundryArtifact {
  const path = join(repoRoot, 'out', solFile, `${contract}.json`)
  const artifact = JSON.parse(readFileSync(path, 'utf8')) as {abi: Abi; bytecode: {object: Hex}}
  return {abi: artifact.abi, bytecode: artifact.bytecode.object}
}

/** A test actor: a funded Anvil account with public+wallet clients. */
export interface TestActor {
  readonly account: PrivateKeyAccount
  readonly address: Address
  readonly walletClient: WalletClient
}

/** Everything a test file needs to talk to one Anvil chain. */
export interface ChainContext {
  readonly chainId: number
  readonly rpcUrl: string
  readonly publicClient: PublicClient
  readonly testClient: TestClient
  /** Actor 0 — contract deployer and Omnibus owner. */
  readonly deployer: TestActor
  /** Actor 1 — the standard proposer. */
  readonly alice: TestActor
  /** Actor 2 — the standard taker. */
  readonly bob: TestActor
  /** Actor 3 — a third-party actor (permissionless-path tests). */
  readonly charlie: TestActor
  /** Deploys a contract and returns its address. */
  deploy(artifact: FoundryArtifact, args?: readonly unknown[]): Promise<Address>
  /** Reads the latest block timestamp. */
  now(): Promise<bigint>
  /** Warps the chain to an absolute timestamp (must be in the future) and mines a block. */
  warpTo(timestamp: bigint): Promise<void>
}

/**
 * Connects clients and actors to a running Anvil node.
 *
 * @param rpcUrl - The node's RPC endpoint.
 * @param chainId - The node's chain id (must match what Anvil was started with).
 */
export function connectChain(rpcUrl: string, chainId: number): ChainContext {
  const chain = defineChain({
    id: chainId,
    name: `anvil-${chainId}`,
    nativeCurrency: {name: 'Ether', symbol: 'ETH', decimals: 18},
    rpcUrls: {default: {http: [rpcUrl]}},
  })
  const transport = http(rpcUrl)
  const publicClient = createPublicClient({chain, transport}) as PublicClient
  const testClient = createTestClient({chain, mode: 'anvil', transport})

  const actorFor = (key: `0x${string}`): TestActor => {
    const account = privateKeyToAccount(key)
    return {
      account,
      address: account.address,
      walletClient: createWalletClient({chain, transport, account}),
    }
  }

  const [deployer, alice, bob, charlie] = [
    actorFor(ANVIL_KEYS[0]),
    actorFor(ANVIL_KEYS[1]),
    actorFor(ANVIL_KEYS[2]),
    actorFor(ANVIL_KEYS[3]),
  ]

  async function deploy(artifact: FoundryArtifact, args: readonly unknown[] = []): Promise<Address> {
    const hash = await deployer.walletClient.deployContract({
      abi: artifact.abi,
      bytecode: artifact.bytecode,
      args: args as unknown[],
      chain,
      account: deployer.account,
    })
    const receipt = await publicClient.waitForTransactionReceipt({hash})
    if (receipt.contractAddress == null) {
      throw new Error('deployment produced no contract address')
    }
    // checksum so addresses compare byte-equal with viem-decoded event data
    return getAddress(receipt.contractAddress)
  }

  async function now(): Promise<bigint> {
    const block = await publicClient.getBlock()
    return block.timestamp
  }

  async function warpTo(timestamp: bigint): Promise<void> {
    // evm_setNextBlockTimestamp only applies to the NEXT block, so mine one
    // immediately — afterwards `latest.timestamp === timestamp`, mirroring
    // the vm.warp anchors in the Foundry suite
    await testClient.setNextBlockTimestamp({timestamp})
    await testClient.mine({blocks: 1})
  }

  return {chainId, rpcUrl, publicClient, testClient, deployer, alice, bob, charlie, deploy, now, warpTo}
}

/** Addresses of the standard per-chain contract fixture. */
export interface Fixture {
  readonly omnibus: Address
  /** AcceptAll ERC-7913 VerifierMock, activated on omnibus AND omnibusHarness. */
  readonly verifier: Address
  /**
   * WalletFactoryMock backing the wallet commit route on omnibus AND
   * omnibusHarness: a settable registry — `setWallet(account, vaultId)`
   * makes `account` pass the `vaultIdOf(msg.sender) != 0` membership check.
   */
  readonly walletFactory: Address
  readonly erc20: Address
  readonly erc721: Address
  readonly erc1155: Address
  readonly feeERC20: Address
  readonly termsLibHarness: Address
  readonly omnibusHarness: Address
}

/**
 * Deploys the standard fixture onto a chain. Commit is permissionless on the
 * keyed route — any funded account may commit; the wallet route (empty
 * signature) additionally requires the sender to be registered in the
 * fixture's WalletFactoryMock.
 *
 * @param ctx - The chain context from {@link connectChain}.
 * @returns The deployed addresses.
 */
export async function deployFixture(ctx: ChainContext): Promise<Fixture> {
  // 1. the wallet-factory registry double, then the three-argument constructor:
  // (initialOwner, walletFactory, version); verifiers are activated post-deploy
  // via setVerifierActivity (owner action)
  const walletFactory = await ctx.deploy(loadArtifact('WalletFactoryMock.sol', 'WalletFactoryMock'))
  const omnibusArtifact = loadArtifact('Omnibus.sol', 'Omnibus')
  const omnibus = await ctx.deploy(omnibusArtifact, [
    ctx.deployer.address,
    walletFactory,
    stringToHex('QUIP:Omnibus:sdk-test', {size: 32}),
  ])

  // an AcceptAll ERC-7913 verifier mock backs the keyed commit route
  const verifier = await ctx.deploy(loadArtifact('VerifierMock.sol', 'VerifierMock'))

  const activateVerifier = async (target: Address): Promise<void> => {
    const hash = await ctx.deployer.walletClient.writeContract({
      address: target,
      abi: omnibusArtifact.abi,
      functionName: 'setVerifierActivity',
      args: [verifier, true],
      chain: null,
      account: ctx.deployer.account,
    })
    await ctx.publicClient.waitForTransactionReceipt({hash})
  }
  await activateVerifier(omnibus)

  // 2. mock assets
  const erc20 = await ctx.deploy(loadArtifact('ERC20Mock.sol', 'ERC20Mock'), ['MockToken', 'MTK', 18])
  const erc721 = await ctx.deploy(loadArtifact('ERC721Mock.sol', 'ERC721Mock'), ['MockNFT', 'MNFT'])
  const erc1155 = await ctx.deploy(loadArtifact('ERC1155Mock.sol', 'ERC1155Mock'), [
    'https://example.com/token/{id}.json',
  ])
  const feeERC20 = await ctx.deploy(loadArtifact('FeeOnTransferERC20Mock.sol', 'FeeOnTransferERC20Mock'), [
    'FeeToken',
    'FEE',
    100n, // 1% skim per transfer
  ])

  // 3. harnesses for differential tests (harness constructor matches Omnibus)
  const termsLibHarness = await ctx.deploy(loadArtifact('TermsLibHarness.sol', 'TermsLibHarness'))
  const omnibusHarness = await ctx.deploy(loadArtifact('OmnibusHarness.sol', 'OmnibusHarness'), [
    ctx.deployer.address,
    walletFactory,
  ])
  await activateVerifier(omnibusHarness)

  return {omnibus, verifier, walletFactory, erc20, erc721, erc1155, feeERC20, termsLibHarness, omnibusHarness}
}
