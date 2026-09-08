import type {Address} from 'viem'
import {AuthorizationMode, DelegationPolicy, prepareTradeCommand, WrapperMode} from '../../../src/index.js'
import type {SideTerms, TimingPolicy} from '../../../src/index.js'
import {AssetType} from '../../../src/index.js'
import type {Hex32} from '../../../src/index.js'

const ZERO = '0x0000000000000000000000000000000000000000' as Address
const ALICE = '0x1111111111111111111111111111111111111111' as Address
const BOB = '0x2222222222222222222222222222222222222222' as Address
const EXECUTOR = '0x3333333333333333333333333333333333333333' as Address
const VERIFIER = '0x4444444444444444444444444444444444444444' as Address
const WRAPPER = '0x5555555555555555555555555555555555555555' as Address
const policy: TimingPolicy = {
  policyVersion: 1n,
  mode: WrapperMode.CrossChain,
  partyChainId: 31337n,
  counterpartyChainId: 31338n,
  partyToCounterpartyDelay: 10n,
  counterpartyToPartyDelay: 10n
}
const side = (
  party: boolean): Omit<SideTerms, 'commitLock' | 'sideNonce'> => ({
    chainId: party ? 31337n : 31338n,
    assets: [{
      assetType: AssetType.Native,
      target: ZERO,
      id: 0n,
      amount: 1n
    }],
    principal: party ? ALICE : BOB,
    authorizationMode: AuthorizationMode.QuipWallet,
    principalKeyVersion: 0n,
    reclaimRecipient: party ? ALICE : BOB,
    recipient: party ? BOB : ALICE,
    commitmentDeadline: party ? 100n : 200n,
    claimDeadline: party ? 350n : 300n,
    reclaimRelease: 500n,
    delegationPolicy: party ? DelegationPolicy.NotAllowed : DelegationPolicy.Permissionless,
    delegate: ZERO,
    delegateKeyVersion: 0n
  })

export function fixturesForClientOutput() {
  let n = 1

  return prepareTradeCommand({
    workflow: {
      policy,
      partySide: side(true),
      counterpartySide: side(false),
      partyVerifier: VERIFIER,
      counterpartyVerifier: VERIFIER,
      partyWrapper: WRAPPER,
      counterpartyWrapper: WRAPPER,
      partyExpiry: 90n,
      counterpartyExpiry: 190n,
      requiredConfirmations: 3n,
      selectedBobSubmitter: EXECUTOR,
      randomHex32: () => `0x${(n++).toString(16).padStart(64, '0')}` as Hex32
    },
    finalClaimExecutors: [EXECUTOR],
    secretMode: 'unsafe-demo'
  })
}
