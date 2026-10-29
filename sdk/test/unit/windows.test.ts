/**
 * Half-open window math unit tests.
 *
 * Covers: `enforceWithin` boundary semantics (lower inclusive, upper
 * EXCLUSIVE, degenerate ranges), and that each derived per-action window
 * matches the `enforceWithin` calls `Omnibus.commit/claim/reclaim` actually
 * make.
 *
 * Parallels `test/TermsLib/behaviors/enforceWithin.t.sol` and the timing
 * model documented in `test/Omnibus/Omnibus.t.sol`.
 */
import {describe, expect, it} from 'vitest'
import {QuipSwapError} from '../../src/errors.js'
import {
  enforceWithin,
  isWithinWindow,
  MAX_UINT256,
  proposerClaimWindow,
  proposerCommitWindow,
  reclaimWindow,
  takerClaimWindow,
  takerCommitWindow,
  validateClaimWindow,
  validateCommitWindow,
  validateReclaimWindow,
} from '../../src/windows.js'
import {
  ALICE_CLAIM_DEADLINE,
  ALICE_COMMIT_DEADLINE,
  ALICE_RECLAIM_RELEASE,
  AT_PROPOSER_CLAIM,
  AT_PROPOSER_COMMIT,
  AT_PROPOSER_RECLAIM,
  AT_TAKER_CLAIM,
  AT_TAKER_COMMIT,
  BOB_COMMIT_DEADLINE,
  CHAIN_A,
  CHAIN_B,
  aliceTerms,
  bobTerms,
} from '../helpers/fixtures.js'

function codeOf(fn: () => unknown): string {
  try {
    fn()
  } catch (error) {
    if (error instanceof QuipSwapError) return error.code
    throw error
  }
  throw new Error('expected the call to throw a QuipSwapError')
}

const alice = aliceTerms(CHAIN_A) // proposer
const bob = bobTerms(CHAIN_A) // taker

describe('enforceWithin', () => {
  it('accepts the inclusive lower bound', () => {
    expect(() => enforceWithin(100n, 200n, 100n)).not.toThrow()
  })

  it('rejects timestamp == upper — the upper bound is EXCLUSIVE', () => {
    // adjacent windows share a boundary; exactly one window accepts the
    // shared instant, so upper must reject (contract: WindowViolated)
    expect(codeOf(() => enforceWithin(100n, 200n, 200n))).toBe('WINDOW_VIOLATED')
  })

  it('accepts upper - 1', () => {
    expect(() => enforceWithin(100n, 200n, 199n)).not.toThrow()
  })

  it('rejects timestamp below lower', () => {
    expect(codeOf(() => enforceWithin(100n, 200n, 99n))).toBe('WINDOW_VIOLATED')
  })

  it('rejects degenerate ranges lower >= upper (contract: InvalidRange)', () => {
    expect(codeOf(() => enforceWithin(200n, 200n, 200n))).toBe('INVALID_RANGE')
    expect(codeOf(() => enforceWithin(201n, 200n, 200n))).toBe('INVALID_RANGE')
  })
})

describe('isWithinWindow', () => {
  it('matches enforceWithin semantics without throwing', () => {
    const window = {lower: 100n, upper: 200n}
    expect(isWithinWindow(window, 100n)).toBe(true)
    expect(isWithinWindow(window, 199n)).toBe(true)
    expect(isWithinWindow(window, 200n)).toBe(false)
    expect(isWithinWindow(window, 99n)).toBe(false)
    expect(isWithinWindow({lower: 200n, upper: 200n}, 200n)).toBe(false) // degenerate
  })
})

describe('derived action windows match the contract enforceWithin calls', () => {
  it('proposer commit window = [0, proposer.commitmentDeadline)', () => {
    expect(proposerCommitWindow(alice)).toEqual({lower: 0n, upper: ALICE_COMMIT_DEADLINE})
  })

  it('taker commit window = [proposer.commitmentDeadline, taker.commitmentDeadline)', () => {
    expect(takerCommitWindow(bob, alice)).toEqual({lower: ALICE_COMMIT_DEADLINE, upper: BOB_COMMIT_DEADLINE})
  })

  it('proposer claim window = [taker.commitmentDeadline, proposer.claimDeadline)', () => {
    expect(proposerClaimWindow(alice, bob)).toEqual({lower: BOB_COMMIT_DEADLINE, upper: ALICE_CLAIM_DEADLINE})
  })

  it('taker claim window = [proposer.claimDeadline, proposer.reclaimRelease)', () => {
    expect(takerClaimWindow(alice)).toEqual({lower: ALICE_CLAIM_DEADLINE, upper: ALICE_RECLAIM_RELEASE})
  })

  it('reclaim window = [leg.reclaimRelease, +inf)', () => {
    expect(reclaimWindow(alice)).toEqual({lower: ALICE_RECLAIM_RELEASE, upper: MAX_UINT256})
  })
})

describe('validateCommitWindow', () => {
  it('accepts the proposer inside [0, proposer.commitmentDeadline)', () => {
    expect(() => validateCommitWindow(alice, bob, AT_PROPOSER_COMMIT)).not.toThrow()
  })

  it('rejects the proposer at its deadline (upper exclusive)', () => {
    expect(codeOf(() => validateCommitWindow(alice, bob, ALICE_COMMIT_DEADLINE))).toBe('WINDOW_VIOLATED')
  })

  it('rejects the taker BEFORE the proposer deadline elapses', () => {
    // the taker's window only OPENS at proposer.commitmentDeadline
    expect(codeOf(() => validateCommitWindow(bob, alice, AT_PROPOSER_COMMIT))).toBe('WINDOW_VIOLATED')
  })

  it('accepts the taker inside [proposer.commitmentDeadline, taker.commitmentDeadline)', () => {
    expect(() => validateCommitWindow(bob, alice, AT_TAKER_COMMIT)).not.toThrow()
    expect(() => validateCommitWindow(bob, alice, ALICE_COMMIT_DEADLINE)).not.toThrow() // lower inclusive
  })

  it('rejects the taker at its own deadline', () => {
    expect(codeOf(() => validateCommitWindow(bob, alice, BOB_COMMIT_DEADLINE))).toBe('WINDOW_VIOLATED')
  })
})

describe('validateClaimWindow', () => {
  // ---- same-chain: ONE window, [taker.commitmentDeadline, proposer.claimDeadline),
  // enforced identically for BOTH argument orders (mirrors the contract fix:
  // roles derive from the terms' deadlines, never from argument order) ----

  it('same-chain: accepts the conventional order inside [taker.commitmentDeadline, proposer.claimDeadline)', () => {
    expect(() => validateClaimWindow(alice, bob, AT_PROPOSER_CLAIM)).not.toThrow()
  })

  it('same-chain: accepts the SWAPPED order in the same window', () => {
    expect(() => validateClaimWindow(bob, alice, AT_PROPOSER_CLAIM)).not.toThrow()
  })

  it('same-chain: rejects both orders before the taker commitment deadline', () => {
    expect(codeOf(() => validateClaimWindow(alice, bob, AT_TAKER_COMMIT))).toBe('WINDOW_VIOLATED')
    expect(codeOf(() => validateClaimWindow(bob, alice, AT_TAKER_COMMIT))).toBe('WINDOW_VIOLATED')
  })

  it('REGRESSION (audit): same-chain SWAPPED order is rejected in what used to be the taker window', () => {
    // pre-fix, (bob, alice) selected the taker branch and accepted here,
    // extending the secret holder's window through proposer.reclaimRelease
    expect(codeOf(() => validateClaimWindow(bob, alice, AT_TAKER_CLAIM))).toBe('WINDOW_VIOLATED')
    expect(codeOf(() => validateClaimWindow(bob, alice, ALICE_RECLAIM_RELEASE - 1n))).toBe('WINDOW_VIOLATED')
  })

  it('same-chain: rejects both orders at proposer.claimDeadline (upper exclusive)', () => {
    expect(codeOf(() => validateClaimWindow(alice, bob, ALICE_CLAIM_DEADLINE))).toBe('WINDOW_VIOLATED')
    expect(codeOf(() => validateClaimWindow(bob, alice, ALICE_CLAIM_DEADLINE))).toBe('WINDOW_VIOLATED')
  })

  // ---- cross-chain: the redeem window survives, selected by CHAIN, not order ----

  const remoteBob = bobTerms(CHAIN_B)

  it('cross-chain: accepts the proposer reveal leg inside [taker.commitmentDeadline, proposer.claimDeadline)', () => {
    // claim on the taker's chain: counterparty is the taker (remote-schedule bob)
    expect(() => validateClaimWindow(alice, remoteBob, AT_PROPOSER_CLAIM)).not.toThrow()
  })

  it('cross-chain: accepts the taker redeem leg inside [proposer.claimDeadline, proposer.reclaimRelease)', () => {
    // claim on the proposer's chain: counterparty is the proposer
    expect(() => validateClaimWindow(remoteBob, alice, AT_TAKER_CLAIM)).not.toThrow()
  })

  it('cross-chain: rejects the taker redeem leg before proposer.claimDeadline', () => {
    expect(codeOf(() => validateClaimWindow(remoteBob, alice, AT_PROPOSER_CLAIM))).toBe('WINDOW_VIOLATED')
  })

  it('cross-chain: rejects the taker redeem leg at proposer.reclaimRelease (upper exclusive)', () => {
    expect(codeOf(() => validateClaimWindow(remoteBob, alice, ALICE_RECLAIM_RELEASE))).toBe('WINDOW_VIOLATED')
  })
})

describe('validateReclaimWindow', () => {
  it('rejects before the leg reclaimRelease', () => {
    expect(codeOf(() => validateReclaimWindow(alice, AT_TAKER_CLAIM))).toBe('WINDOW_VIOLATED')
  })

  it('accepts at and after reclaimRelease (lower inclusive, no upper bound)', () => {
    expect(() => validateReclaimWindow(alice, ALICE_RECLAIM_RELEASE)).not.toThrow()
    expect(() => validateReclaimWindow(alice, AT_PROPOSER_RECLAIM)).not.toThrow()
    expect(() => validateReclaimWindow(alice, MAX_UINT256 - 1n)).not.toThrow()
  })
})
