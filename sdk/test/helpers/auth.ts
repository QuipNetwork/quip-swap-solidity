/**
 * The ONE definition of test CommitAuth building for the Anvil-backed suites
 * (integration, cross-chain, smoke) — mirrors the Foundry `AuthHelper`.
 *
 * Test infrastructure only — never exported from the SDK package.
 */
import {keccak256, toHex} from 'viem'
import type {Address} from 'viem'
import {buildKeyedSigner} from '../../src/commitAuth.js'
import type {CommitAuth} from '../../src/commitAuth.js'
import type {Hex32} from '../../src/types.js'
import type {ChainContext, Fixture} from './chain.js'
import {walletFactoryMockAbi} from './mockAbis.js'

/**
 * Non-empty placeholder signature ('envelope' in ASCII, matching the Foundry
 * AuthHelper). The AcceptAll VerifierMock ignores signature CONTENT, but the
 * signature must be NON-EMPTY — an empty one selects the WALLET route, which
 * requires the sender to be registered in the fixture's WalletFactoryMock.
 */
export const PLACEHOLDER_SIGNATURE = '0x656e76656c6f7065' as const

/** The commitment test wallets are registered under (any non-zero value works). */
export const TEST_COMMITMENT: Hex32 = keccak256(toHex('sdk test commitment'))

/**
 * Keyed ERC-7913 auth for `addr` via the fixture's AcceptAll VerifierMock
 * (the 20-byte address doubles as the key; 40-byte blob).
 */
export function keyedAuth(fixture: Fixture, addr: Address): CommitAuth {
  return {signer: buildKeyedSigner(fixture.verifier, addr), signature: PLACEHOLDER_SIGNATURE}
}

/**
 * Wallet-route auth for `addr`: the EMPTY signature selects the route; the
 * signer blob is shape-checked attribution only. The SENDER must be
 * registered in the fixture's WalletFactoryMock (see {@link registerWallet}).
 */
export function walletAuth(fixture: Fixture, addr: Address): CommitAuth {
  return {signer: buildKeyedSigner(fixture.verifier, addr), signature: '0x'}
}

/**
 * Registers `wallet` in the fixture's WalletFactoryMock under `commitment`
 * ({@link TEST_COMMITMENT} by default) so it passes the wallet route's
 * membership check. Pass the zero commitment to deregister.
 */
export async function registerWallet(
  ctx: ChainContext,
  fixture: Fixture,
  wallet: Address,
  commitment: Hex32 = TEST_COMMITMENT,
): Promise<void> {
  const hash = await ctx.deployer.walletClient.writeContract({
    address: fixture.walletFactory,
    abi: walletFactoryMockAbi,
    functionName: 'setWallet',
    args: [wallet, commitment],
    chain: ctx.publicClient.chain ?? null,
    account: ctx.deployer.account,
  })
  await ctx.publicClient.waitForTransactionReceipt({hash})
}

/** Deregisters `wallet` (sets its commitment back to zero). */
export async function deregisterWallet(ctx: ChainContext, fixture: Fixture, wallet: Address): Promise<void> {
  await registerWallet(ctx, fixture, wallet, `0x${'00'.repeat(32)}` as Hex32)
}
