/**
 * prepareApproval — pure Call construction for smart accounts.
 *
 * The allowance the Omnibus consumes is `allowance(msg.sender, omnibus)`, so a
 * smart account must grant it FROM ITS OWN ADDRESS; the SDK hands back the
 * exact `{to, value, data}` and never sends it.
 */
import {decodeFunctionData, parseAbi} from 'viem'
import type {Address} from 'viem'
import {describe, expect, it} from 'vitest'
import {prepareApproval} from '../../src/approvals.js'
import type {Erc1155ApprovalItem, Erc20ApprovalItem, Erc721ApprovalItem} from '../../src/approvals.js'
import {QuipSwapError} from '../../src/errors.js'

const OMNIBUS: Address = '0x9990000000000000000000000000000000000999'
const TOKEN: Address = '0x1110000000000000000000000000000000000111'
const MAX_UINT256 = (1n << 256n) - 1n

const approvalAbi = parseAbi([
  'function approve(address spender, uint256 amount)',
  'function setApprovalForAll(address operator, bool approved)',
])

const erc20Item: Erc20ApprovalItem = {
  kind: 'erc20',
  token: TOKEN,
  requiredAllowance: 1_000n,
  currentAllowance: 0n,
  satisfied: false,
}
const erc721Item: Erc721ApprovalItem = {
  kind: 'erc721',
  token: TOKEN,
  tokenId: 42n,
  tokenApproved: false,
  operatorApproved: false,
  satisfied: false,
}
const erc1155Item: Erc1155ApprovalItem = {kind: 'erc1155', token: TOKEN, operatorApproved: false, satisfied: false}

function decode(data: `0x${string}`) {
  return decodeFunctionData({abi: approvalAbi, data})
}

describe('prepareApproval', () => {
  it('ERC-20 exact: approve(omnibus, requiredAllowance) on the token, zero value', () => {
    const call = prepareApproval({omnibusAddress: OMNIBUS, item: erc20Item, erc20Mode: 'exact'})
    expect(call.to).toBe(TOKEN)
    expect(call.value).toBe(0n)
    expect(decode(call.data)).toEqual({functionName: 'approve', args: [OMNIBUS, 1_000n]})
  })

  it('ERC-20 unlimited: approve(omnibus, 2^256-1)', () => {
    const call = prepareApproval({omnibusAddress: OMNIBUS, item: erc20Item, erc20Mode: 'unlimited'})
    expect(decode(call.data)).toEqual({functionName: 'approve', args: [OMNIBUS, MAX_UINT256]})
  })

  it('ERC-20 without a mode throws INVALID_RANGE — the SDK never defaults to unlimited', () => {
    expect(() => prepareApproval({omnibusAddress: OMNIBUS, item: erc20Item})).toThrowError(QuipSwapError)
    try {
      prepareApproval({omnibusAddress: OMNIBUS, item: erc20Item})
    } catch (error) {
      expect((error as QuipSwapError).code).toBe('INVALID_RANGE')
    }
  })

  it('ERC-721 defaults to the single-token approve(omnibus, tokenId)', () => {
    const call = prepareApproval({omnibusAddress: OMNIBUS, item: erc721Item})
    expect(call.to).toBe(TOKEN)
    expect(decode(call.data)).toEqual({functionName: 'approve', args: [OMNIBUS, 42n]})
  })

  it("ERC-721 'operator' grants setApprovalForAll(omnibus, true)", () => {
    const call = prepareApproval({omnibusAddress: OMNIBUS, item: erc721Item, erc721Mode: 'operator'})
    expect(decode(call.data)).toEqual({functionName: 'setApprovalForAll', args: [OMNIBUS, true]})
  })

  it('ERC-1155 is always setApprovalForAll(omnibus, true)', () => {
    const call = prepareApproval({omnibusAddress: OMNIBUS, item: erc1155Item})
    expect(call.to).toBe(TOKEN)
    expect(call.value).toBe(0n)
    expect(decode(call.data)).toEqual({functionName: 'setApprovalForAll', args: [OMNIBUS, true]})
  })
})
