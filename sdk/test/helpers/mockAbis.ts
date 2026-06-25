/**
 * Minimal mock-contract ABI surfaces used by the test suites (mint, balance
 * / ownership / approval reads, and the QuipFactoryMock registry). Kept
 * separate from `chain.ts` so the chain context / fixture deployment helper
 * stays focused on lifecycle, and the surfaces can be imported on their own.
 *
 * Test infrastructure only — never exported from the SDK package.
 */

/** QuipFactoryMock surface: registerWallet / unregisterWallet (test gating). */
export const quipFactoryMockAbi = [
  {
    type: 'function',
    name: 'registerWallet',
    stateMutability: 'nonpayable',
    inputs: [
      {name: 'wallet', type: 'address'},
      {name: 'vaultId', type: 'bytes32'},
      {name: 'owner', type: 'address'},
    ],
    outputs: [],
  },
  {
    type: 'function',
    name: 'unregisterWallet',
    stateMutability: 'nonpayable',
    inputs: [{name: 'wallet', type: 'address'}],
    outputs: [],
  },
] as const

/** ERC20Mock surface: mint, balanceOf, approve, allowance. */
export const erc20MockAbi = [
  {
    type: 'function',
    name: 'mint',
    stateMutability: 'nonpayable',
    inputs: [
      {name: 'to', type: 'address'},
      {name: 'amount', type: 'uint256'},
    ],
    outputs: [],
  },
  {
    type: 'function',
    name: 'balanceOf',
    stateMutability: 'view',
    inputs: [{name: 'account', type: 'address'}],
    outputs: [{name: '', type: 'uint256'}],
  },
  {
    type: 'function',
    name: 'approve',
    stateMutability: 'nonpayable',
    inputs: [
      {name: 'spender', type: 'address'},
      {name: 'amount', type: 'uint256'},
    ],
    outputs: [{name: '', type: 'bool'}],
  },
  {
    type: 'function',
    name: 'allowance',
    stateMutability: 'view',
    inputs: [
      {name: 'owner', type: 'address'},
      {name: 'spender', type: 'address'},
    ],
    outputs: [{name: '', type: 'uint256'}],
  },
] as const

/** ERC721Mock surface: mint, ownerOf, approve, setApprovalForAll. */
export const erc721MockAbi = [
  {
    type: 'function',
    name: 'mint',
    stateMutability: 'nonpayable',
    inputs: [
      {name: 'to', type: 'address'},
      {name: 'tokenId', type: 'uint256'},
    ],
    outputs: [],
  },
  {
    type: 'function',
    name: 'ownerOf',
    stateMutability: 'view',
    inputs: [{name: 'tokenId', type: 'uint256'}],
    outputs: [{name: '', type: 'address'}],
  },
  {
    type: 'function',
    name: 'approve',
    stateMutability: 'nonpayable',
    inputs: [
      {name: 'to', type: 'address'},
      {name: 'tokenId', type: 'uint256'},
    ],
    outputs: [],
  },
  {
    type: 'function',
    name: 'setApprovalForAll',
    stateMutability: 'nonpayable',
    inputs: [
      {name: 'operator', type: 'address'},
      {name: 'approved', type: 'bool'},
    ],
    outputs: [],
  },
] as const

/** ERC1155Mock surface: mint, balanceOf, setApprovalForAll. */
export const erc1155MockAbi = [
  {
    type: 'function',
    name: 'mint',
    stateMutability: 'nonpayable',
    inputs: [
      {name: 'to', type: 'address'},
      {name: 'id', type: 'uint256'},
      {name: 'amount', type: 'uint256'},
      {name: 'data', type: 'bytes'},
    ],
    outputs: [],
  },
  {
    type: 'function',
    name: 'balanceOf',
    stateMutability: 'view',
    inputs: [
      {name: 'account', type: 'address'},
      {name: 'id', type: 'uint256'},
    ],
    outputs: [{name: '', type: 'uint256'}],
  },
  {
    type: 'function',
    name: 'setApprovalForAll',
    stateMutability: 'nonpayable',
    inputs: [
      {name: 'operator', type: 'address'},
      {name: 'approved', type: 'bool'},
    ],
    outputs: [],
  },
] as const
