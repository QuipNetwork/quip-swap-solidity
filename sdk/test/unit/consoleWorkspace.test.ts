import {mkdtemp, readFile, rm, stat, writeFile} from 'node:fs/promises'
import {tmpdir} from 'node:os'
import {join} from 'node:path'
import type {Address} from 'viem'
import {describe, expect, it} from 'vitest'
import {
  AssetType,
  AuthorizationMode,
  CONSOLE_CONFIG_SCHEMA,
  DelegationPolicy,
  WrapperMode,
  initializePartyWorkspace,
  inspectPartyWorkspace,
  loadConsoleConfigIdentity,
  prepareTradeCommand,
  restoreWorkspaceWorkflowState,
  runConsole,
  saveWorkspaceWorkflowState,
  withWorkspaceMutation,
} from '../../src/index.js'
import type {Hex32, SideTerms, TimingPolicy} from '../../src/index.js'

const ZERO = '0x0000000000000000000000000000000000000000' as Address
const ALICE = '0x1111111111111111111111111111111111111111' as Address
const BOB = '0x2222222222222222222222222222222222222222' as Address
const EXECUTOR = '0x3333333333333333333333333333333333333333' as Address
const VERIFIER = '0x4444444444444444444444444444444444444444' as Address
const WRAPPER = '0x5555555555555555555555555555555555555555' as Address
const hexN = (n: number) => `0x${n.toString(16).padStart(64, '0')}` as Hex32
const policy: TimingPolicy = {policyVersion: 1n, mode: WrapperMode.CrossChain, partyChainId: 31337n, counterpartyChainId: 31338n, partyToCounterpartyDelay: 10n, counterpartyToPartyDelay: 10n}
const side = (party: boolean): Omit<SideTerms, 'commitLock' | 'sideNonce'> => ({chainId: party ? 31337n : 31338n, assets: [{assetType: AssetType.Native, target: ZERO, id: 0n, amount: 1n}], principal: party ? ALICE : BOB, authorizationMode: AuthorizationMode.QuipWallet, principalKeyVersion: 0n, reclaimRecipient: party ? ALICE : BOB, recipient: party ? BOB : ALICE, commitmentDeadline: party ? 100n : 200n, claimDeadline: party ? 300n : 350n, reclaimRelease: 500n, delegationPolicy: party ? DelegationPolicy.NotAllowed : DelegationPolicy.Permissionless, delegate: ZERO, delegateKeyVersion: 0n})

function prepared() {
  let n = 1
  return prepareTradeCommand({workflow: {policy, partySide: side(true), counterpartySide: side(false), partyVerifier: VERIFIER, counterpartyVerifier: VERIFIER, partyWrapper: WRAPPER, counterpartyWrapper: WRAPPER, partyExpiry: 90n, counterpartyExpiry: 190n, requiredConfirmations: 3n, selectedBobSubmitter: EXECUTOR, randomHex32: () => hexN(n++)}, finalClaimExecutors: [EXECUTOR], secretMode: 'unsafe-demo'})
}

async function fixture() {
  const root = await mkdtemp(join(tmpdir(), 'quip-workspace-'))
  const workspace = join(root, 'alice')
  const configPath = join(root, 'config.json')
  const addresses = {assetSupportRegistry: ALICE, directAuthorization: VERIFIER, crossChainWrapper: WRAPPER, sameChainWrapper: ALICE}
  const deploymentChain = (chainId: number) => ({chainId, trustedVerifier: VERIFIER, addresses})
  const configValue = {
    schema: CONSOLE_CONFIG_SCHEMA,
    networkId: 'local-31337-31338',
    localParty: 'alice',
    prototype: true,
    mockVerifier: true,
    requiredConfirmations: 3,
    chains: [{chainId: 31337, rpcUrl: 'http://127.0.0.1:8545'}, {chainId: 31338, rpcUrl: 'http://127.0.0.1:8546'}],
    actors: {alice: ALICE, bob: BOB, permissionlessExecutor: EXECUTOR},
    timingPolicy: {policyVersion: '1', mode: 'CrossChain', partyChainId: '31337', counterpartyChainId: '31338', partyToCounterpartyDelay: '10', counterpartyToPartyDelay: '10'},
    artifactExchange: {directory: root},
    deployment: {schema: 'quip-swap-demo-deployment.v1', chains: [deploymentChain(31337), deploymentChain(31338)]},
  }
  await writeFile(configPath, `${JSON.stringify(configValue)}\n`, {mode: 0o600})
  const config = await loadConsoleConfigIdentity(configPath)
  return {root, workspace, configPath, config}
}

describe('isolated console workspaces', () => {
  it('initializes owner-only party directories through the executable', async () => {
    const value = await fixture()
    try {
      let stdout = ''; let stderr = ''
      const code = await runConsole(['init', '--party', 'alice', '--state-root', value.workspace, '--config', value.configPath, '--json'], {stdout: text => { stdout += text }, stderr: text => { stderr += text }})
      expect(code).toBe(0)
      expect(JSON.parse(stdout)).toMatchObject({ok: true, party: 'alice', result: {networkId: 'local-31337-31338'}})
      expect(stderr).toBe('')
      for (const path of [value.workspace, join(value.workspace, 'public'), join(value.workspace, 'private'), join(value.workspace, 'journal')]) {
        expect((await stat(path)).mode & 0o777).toBe(0o700)
      }
      expect((await stat(join(value.workspace, 'workspace.json'))).mode & 0o777).toBe(0o600)
      expect((await stat(join(value.workspace, 'public', 'config.json'))).mode & 0o777).toBe(0o600)
      await expect(initializePartyWorkspace({root: value.workspace, party: 'alice', config: value.config})).rejects.toThrow('already exists')
    } finally { await rm(value.root, {recursive: true, force: true}) }
  })

  it('rejects the wrong party, network, configuration, TradeID, and generation', async () => {
    const value = await fixture()
    try {
      await initializePartyWorkspace({root: value.workspace, party: 'alice', config: value.config})
      const expected = {party: 'alice' as const, networkId: value.config.networkId, configDigest: value.config.digest}
      await expect(inspectPartyWorkspace(value.workspace, {...expected, party: 'bob'})).rejects.toThrow('party mismatch')
      await expect(inspectPartyWorkspace(value.workspace, {...expected, networkId: 'other'})).rejects.toThrow('network mismatch')
      await expect(inspectPartyWorkspace(value.workspace, {...expected, configDigest: `sha256:${'00'.repeat(32)}`})).rejects.toThrow('configuration mismatch')
      await expect(inspectPartyWorkspace(value.workspace, {...expected, tradeId: hexN(9)})).rejects.toThrow('TradeID mismatch')
      await expect(inspectPartyWorkspace(value.workspace, {...expected, generation: 1})).rejects.toThrow('generation mismatch')
    } finally { await rm(value.root, {recursive: true, force: true}) }
  })

  it('serializes mutations with an exclusive lock and releases it after failure', async () => {
    const value = await fixture()
    try {
      await initializePartyWorkspace({root: value.workspace, party: 'alice', config: value.config})
      let release!: () => void
      const held = new Promise<void>(resolve => { release = resolve })
      const first = withWorkspaceMutation(value.workspace, async () => held)
      await new Promise(resolve => setTimeout(resolve, 10))
      await expect(withWorkspaceMutation(value.workspace, async () => undefined)).rejects.toThrow('locked')
      release(); await first
      await expect(withWorkspaceMutation(value.workspace, async () => { throw new Error('transition failed') })).rejects.toThrow('transition failed')
      await expect(withWorkspaceMutation(value.workspace, async () => 'available')).resolves.toBe('available')
    } finally { await rm(value.root, {recursive: true, force: true}) }
  })

  it('atomically binds and restores matched public/private trade generations', async () => {
    const value = await fixture()
    try {
      await initializePartyWorkspace({root: value.workspace, party: 'alice', config: value.config})
      const expected = {party: 'alice' as const, networkId: value.config.networkId, configDigest: value.config.digest}
      const state = prepared().alice
      await saveWorkspaceWorkflowState({root: value.workspace, expected, publicState: state.publicState, secretState: state.secretState})
      const restored = await restoreWorkspaceWorkflowState(value.workspace, {...expected, tradeId: state.publicState.tradeId, generation: 1})
      expect(restored.publicState).toEqual(state.publicState)
      expect(restored.secretState).toEqual(state.secretState)
      expect(await readFile(join(value.workspace, 'public', '000000000001.json'), 'utf8')).not.toContain(state.secretState.settlementSecret)
    } finally { await rm(value.root, {recursive: true, force: true}) }
  })

  it('does not advance the manifest when a proposed generation is invalid', async () => {
    const value = await fixture()
    try {
      await initializePartyWorkspace({root: value.workspace, party: 'alice', config: value.config})
      const expected = {party: 'alice' as const, networkId: value.config.networkId, configDigest: value.config.digest}
      const state = prepared().alice
      await expect(saveWorkspaceWorkflowState({root: value.workspace, expected, publicState: {...state.publicState, generation: 2}, secretState: {...state.secretState, generation: 2}})).rejects.toThrow('does not advance')
      expect(await inspectPartyWorkspace(value.workspace, expected)).toMatchObject({tradeId: null, generation: 0})
    } finally { await rm(value.root, {recursive: true, force: true}) }
  })
})
