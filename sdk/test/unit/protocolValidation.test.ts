import {describe, expect, it} from 'vitest'
import type {Address} from 'viem'
import {
  AssetType, AuthorizationMode, DelegationPolicy, ExpectedSourceState, WrapperMode,
  commitPayloadHash, validateCommitPayouts, deriveCommitLock, expectedSourceState, gateContextId, validateProtocolTerms, wrapperMode,
} from '../../src/index.js'
import type {Hex32, ProtocolTerms, SideTerms, TimingPolicy} from '../../src/index.js'

const Z = '0x0000000000000000000000000000000000000000' as Address
const Z32 = `0x${'00'.repeat(32)}` as Hex32
const H = (
  n: number): Hex32 => `0x${n.toString(16).padStart(64, '0')}` as Hex32
const A = '0x1111111111111111111111111111111111111111' as Address
const B = '0x2222222222222222222222222222222222222222' as Address
const D = '0x3333333333333333333333333333333333333333' as Address
const T = '0x6666666666666666666666666666666666666666' as Address

const side = (
  party: boolean,
  chainId: bigint): SideTerms => ({
    chainId,
    assets: [
      {
        assetType: AssetType.Native,
        target: Z,
        id: 0n,
        amount: party ? 10n : 20n
      },
      {
        assetType: AssetType.ERC20,
        target: T,
        id: 0n,
        amount: party ? 30n : 40n
      },
    ],
    principal: party ? A : B,
    authorizationMode: party ? AuthorizationMode.QuipWallet : AuthorizationMode.RegisteredDirect,
    principalKeyVersion: party ? 0n : 7n,
    reclaimRecipient: party ? A : B,
    recipient: party ? B : A,
    commitmentDeadline: party ? 100n : 200n,
    claimDeadline: party ? 400n : 300n,
    reclaimRelease: party ? 900n : 800n,
    commitLock: Z32,
    delegationPolicy: party ? DelegationPolicy.NotAllowed : DelegationPolicy.SpecificDelegate,
    delegate: party ? Z : D,
    delegateKeyVersion: party ? 0n : 3n,
    sideNonce: party ? H(1) : H(2),
  })

function cross(): ProtocolTerms {
  const base = {
    partySide: side(true, 1n),
    counterpartySide: side(false, 2n)
  }

  return {
...base,
    counterpartySide: {
      ...base.counterpartySide,
      commitLock: deriveCommitLock(gateContextId(base), H(3)),
    }
  }
}

const crossPolicy: TimingPolicy = {
  policyVersion: 1n,
  mode: WrapperMode.CrossChain,
  partyChainId: 1n,
  counterpartyChainId: 2n,
  partyToCounterpartyDelay: 10n,
  counterpartyToPartyDelay: 10n,
}
const samePolicy: TimingPolicy = {
  policyVersion: 1n,
  mode: WrapperMode.SameChain,
  partyChainId: 1n,
  counterpartyChainId: 1n,
  partyToCounterpartyDelay: 0n,
  counterpartyToPartyDelay: 0n,
}
const accepts = (
  terms: ProtocolTerms,
  policy: TimingPolicy): boolean => {
  try {
    validateProtocolTerms(terms, policy);

    return true
  }
  catch {
    return false
  }
}

describe('current protocol term validation', () => {
  it('reserves the final claim budget, including equality at the margin', () => {
    const base = cross()
    const terms = {
...base,
      partySide: {
...base.partySide,
        commitmentDeadline: 200n,
        claimDeadline: 300n,
        reclaimRelease: 500n
      },
      counterpartySide: {
...base.counterpartySide,
        commitmentDeadline: 220n,
        claimDeadline: 320n,
        reclaimRelease: 520n
      }
    }

    for (const deadline of [320n, 300n, 291n]) {
      expect(accepts({
...terms,
        counterpartySide: {
...terms.counterpartySide,
          claimDeadline: deadline
        }
      }, crossPolicy)).toBe(false)
    }
    for (const deadline of [290n, 289n]) {
      expect(accepts({
...terms,
        counterpartySide: {
...terms.counterpartySide,
          claimDeadline: deadline
        }
      }, crossPolicy)).toBe(true)
    }
  })

  for (const sameChain of [false, true])
    for (const party of [false, true]) {
      it(`rejects zero ${party ? 'party' : 'counterparty'} nonce in ${sameChain ? 'same' : 'cross'} chain terms`, () => {
        const terms = sameChain ? {
          partySide: side(true, 1n),
          counterpartySide: side(false, 1n)
        } : cross()
        const policy = sameChain ? samePolicy : crossPolicy
        const selected = party ? 'partySide' : 'counterpartySide'

        expect(accepts({
...terms,
          [selected]: {
...terms[selected],
            sideNonce: Z32
          }
        }, policy)).toBe(false)
        for (const nonce of [H(1), `0x${'ff'.repeat(32)}` as Hex32]) {
          expect(accepts({
...terms,
            partySide: {
...terms.partySide,
              sideNonce: nonce
            },
            counterpartySide: {
...terms.counterpartySide,
              sideNonce: nonce
            }
          }, policy)).toBe(true)
        }
      })
    }

  it('derives both modes and all source-state projections', () => {
    const same = {
      partySide: side(true, 1n),
      counterpartySide: side(false, 1n)
    }

    expect(wrapperMode(cross())).toBe(WrapperMode.CrossChain)
    expect(wrapperMode(same)).toBe(WrapperMode.SameChain)
    expect(expectedSourceState(true, WrapperMode.CrossChain)).toBe(ExpectedSourceState.Unused)
    expect(expectedSourceState(false, WrapperMode.CrossChain)).toBe(ExpectedSourceState.Unused)
    expect(expectedSourceState(true, WrapperMode.SameChain)).toBe(ExpectedSourceState.Unused)
    expect(expectedSourceState(false, WrapperMode.SameChain)).toBe(ExpectedSourceState.PartyCommitted)
    expect(accepts(cross(), crossPolicy)).toBe(true)
    expect(accepts(same, samePolicy)).toBe(true)
  })

  it('rejects unsupported numeric enum values', () => {
    const terms = cross()

    expect(accepts({
...terms,
      partySide: {
        ...terms.partySide,
        authorizationMode: 9 as AuthorizationMode,
      }
    }, crossPolicy)).toBe(false)
    expect(accepts({
...terms,
      partySide: {
        ...terms.partySide,
        delegationPolicy: 9 as DelegationPolicy,
      }
    }, crossPolicy)).toBe(false)
    expect(accepts({
...terms,
      partySide: {
...terms.partySide,
        assets: [{
          ...terms.partySide.assets[0]!,
          assetType: 9 as AssetType,
        }]
      }
    }, crossPolicy)).toBe(false)
  })

  it('rejects malformed identities, authorization, delegation, and deadlines', () => {
    const terms = cross()
    const invalid: ProtocolTerms[] = [
      {
...terms,
        partySide: {
...terms.partySide,
          chainId: 0n
        }
      },
      {
...terms,
        partySide: {
...terms.partySide,
          principal: Z
        }
      },
      {
...terms,
        partySide: {
...terms.partySide,
          recipient: Z
        }
      },
      {
...terms,
        partySide: {
...terms.partySide,
          reclaimRecipient: Z
        }
      },
      {
...terms,
        partySide: {
...terms.partySide,
          principalKeyVersion: 1n
        }
      },
      {
...terms,
        counterpartySide: {
...terms.counterpartySide,
          principalKeyVersion: 0n
        }
      },
      {
...terms,
        partySide: {
...terms.partySide,
          delegationPolicy: DelegationPolicy.SpecificDelegate
        }
      },
      {
...terms,
        counterpartySide: {
...terms.counterpartySide,
          delegate: Z
        }
      },
      {
...terms,
        counterpartySide: {
...terms.counterpartySide,
          delegateKeyVersion: 0n
        }
      },
      {
...terms,
        partySide: {
...terms.partySide,
          delegate: D
        }
      },
      {
...terms,
        partySide: {
...terms.partySide,
          claimDeadline: 100n
        }
      },
      {
...terms,
        partySide: {
...terms.partySide,
          commitmentDeadline: 200n
        }
      },
      {
...terms,
        partySide: {
...terms.partySide,
          claimDeadline: 801n,
          reclaimRelease: 802n
        }
      },
      {
...terms,
        counterpartySide: {
...terms.counterpartySide,
          claimDeadline: 901n,
          reclaimRelease: 902n
        }
      },
    ]

    for (const candidate of invalid)
      expect(accepts(candidate, crossPolicy)).toBe(false)
  })

  it('rejects malformed progression and asset canonicalization', () => {
    const terms = cross()
    const invalid: ProtocolTerms[] = [
      {
...terms,
        partySide: {
...terms.partySide,
          commitLock: H(4)
        }
      },
      {
...terms,
        counterpartySide: {
...terms.counterpartySide,
          commitLock: Z32
        }
      },
      {
...terms,
        partySide: {
...terms.partySide,
          assets: []
        }
      },
      {
...terms,
        partySide: {
...terms.partySide,
          assets: [{
...terms.partySide.assets[0]!,
            amount: 0n
          }]
        }
      },
      {
...terms,
        partySide: {
...terms.partySide,
          assets: [terms.partySide.assets[0]!, terms.partySide.assets[0]!]
        }
      },
      {
...terms,
        partySide: {
...terms.partySide,
          assets: [...terms.partySide.assets].reverse()
        }
      },
    ]

    for (const candidate of invalid)
      expect(accepts(candidate, crossPolicy)).toBe(false)

    const same = {
      partySide: side(true, 1n),
      counterpartySide: side(false, 1n)
    }

    expect(accepts({
...same,
      counterpartySide: {
...same.counterpartySide,
        commitLock: H(5)
      }
    }, samePolicy)).toBe(false)
    expect(accepts({
...same,
      partySide: {
...same.partySide,
        reclaimRelease: 300n
      }
    }, samePolicy)).toBe(false)
  })
})

const wrapper = '0xabcdefabcdefabcdefabcdefabcdefabcdefabcd' as Address

describe('local wrapper payout validation', () => {
  for (const same of [false, true])
    for (const party of [false, true]) {
      for (const field of ['recipient', 'reclaimRecipient'] as const) {
        it(`rejects ${same ? 'same' : 'cross'} chain ${party ? 'party' : 'counterparty'} ${field}`, () => {
          const terms = same ? {
            partySide: side(true, 1n),
            counterpartySide: side(false, 1n)
          } : cross()
          const bad = {
...terms,
            [party ? 'partySide' : 'counterpartySide']: {
              ...(party ? terms.partySide : terms.counterpartySide),
              [field]: `0x${wrapper.slice(2).toUpperCase()}`,
            }
          } as ProtocolTerms

          expect(() => validateCommitPayouts(bad, same ? true : party, wrapper)).toThrow('executing wrapper')
          expect(() => commitPayloadHash({
            terms: bad,
            party: same ? true : party,
            authorizationVerifier: A,
            swapAddress: wrapper,
            lock: H(9),
            expectedSourceState: ExpectedSourceState.Unused,
            actionNonce: H(8),
            expiry: 99n,
          })).toThrow('executing wrapper')
          if (!same)
            expect(() => validateCommitPayouts(bad, !party, wrapper)).not.toThrow()
        })
      }
    }
})
