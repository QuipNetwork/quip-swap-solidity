/**
 * Approval inspection and planning for non-native assets.
 *
 * The committer is `msg.sender` of the commit transaction — in production a
 * QuipWallet CONTRACT (never its owner's EOA; see the QuipWallet gate on
 * `Omnibus.commit`). Assets must belong to that wallet and approvals must
 * be issued BY that wallet, so every check here asks: "can the Omnibus
 * contract pull this asset from the committing wallet?"
 *
 * Fee-on-transfer caveat: `Omnibus.commit` reconciles received balances
 * (`TermsLib.transferAssetsNoNative`). If an ERC-20/ERC-1155 delivers less
 * than the declared amount (fee-on-transfer, deflationary), commit reverts
 * with `UnexpectedAmountReceived` EVEN IF the approval plan is fully
 * satisfied. A satisfied plan is necessary, not sufficient.
 */
import type {Address, PublicClient, WalletClient} from 'viem'
import {QuipSdkError, wrapContractError} from './errors.js'
import {AssetType} from './types.js'
import type {Terms} from './types.js'

/** Minimal ERC-20 surface used for approval planning. */
const erc20Abi = [
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
] as const

/** Minimal ERC-721 surface used for approval planning. */
const erc721Abi = [
  {
    type: 'function',
    name: 'getApproved',
    stateMutability: 'view',
    inputs: [{name: 'tokenId', type: 'uint256'}],
    outputs: [{name: '', type: 'address'}],
  },
  {
    type: 'function',
    name: 'isApprovedForAll',
    stateMutability: 'view',
    inputs: [
      {name: 'owner', type: 'address'},
      {name: 'operator', type: 'address'},
    ],
    outputs: [{name: '', type: 'bool'}],
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

/** Minimal ERC-1155 surface used for approval planning. */
const erc1155Abi = [
  {
    type: 'function',
    name: 'isApprovedForAll',
    stateMutability: 'view',
    inputs: [
      {name: 'account', type: 'address'},
      {name: 'operator', type: 'address'},
    ],
    outputs: [{name: '', type: 'bool'}],
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

/** ERC-20 approval status for one token (amounts aggregated across asset entries). */
export interface Erc20ApprovalItem {
  readonly kind: 'erc20'
  /** The token contract. */
  readonly token: Address
  /** Sum of every asset entry for this token in the terms. */
  readonly requiredAllowance: bigint
  /** `allowance(committer, omnibus)` at plan time. */
  readonly currentAllowance: bigint
  /** `currentAllowance >= requiredAllowance`. */
  readonly satisfied: boolean
}

/** ERC-721 approval status for one specific token id. */
export interface Erc721ApprovalItem {
  readonly kind: 'erc721'
  readonly token: Address
  readonly tokenId: bigint
  /** `getApproved(tokenId) == omnibus`. */
  readonly tokenApproved: boolean
  /** `isApprovedForAll(committer, omnibus)`. */
  readonly operatorApproved: boolean
  /** Either single-token or operator approval suffices. */
  readonly satisfied: boolean
}

/** ERC-1155 approval status for one token contract (operator approval covers all ids). */
export interface Erc1155ApprovalItem {
  readonly kind: 'erc1155'
  readonly token: Address
  /** `isApprovedForAll(committer, omnibus)`. */
  readonly operatorApproved: boolean
  readonly satisfied: boolean
}

/** One entry of an {@link ApprovalPlan}. */
export type ApprovalItem = Erc20ApprovalItem | Erc721ApprovalItem | Erc1155ApprovalItem

/** The result of {@link planApprovals}. */
export interface ApprovalPlan {
  /** The wallet whose assets will be pulled (the commit sender). */
  readonly committer: Address
  /** The Omnibus contract that must be able to pull them. */
  readonly omnibusAddress: Address
  /** One item per (token / token+id) requiring approval; empty if all-native. */
  readonly items: readonly ApprovalItem[]
  /** True iff every item is satisfied. */
  readonly satisfied: boolean
}

/** Arguments for {@link planApprovals}. */
export interface PlanApprovalsArgs {
  /** Public client on the chain where `terms.chainId` points. */
  readonly publicClient: PublicClient
  /** The deployed Omnibus address (the spender/operator to check for). */
  readonly omnibusAddress: Address
  /**
   * The committing wallet — the QuipWallet CONTRACT address that will send
   * the commit transaction, NOT its owner's EOA.
   */
  readonly committer: Address
  /** The side's terms whose assets will be escrowed. */
  readonly terms: Terms
}

/**
 * Inspects on-chain approvals for every non-native asset in a side's terms
 * and returns a typed plan describing what is missing.
 *
 * Checks performed (mirroring what `TermsLib.transferAssetsNoNative` will
 * need at commit time):
 * - ERC-20: `allowance(committer, omnibus) >= sum(required amounts)` —
 *   multiple entries of the same token are AGGREGATED.
 * - ERC-721: `getApproved(tokenId) == omnibus` OR
 *   `isApprovedForAll(committer, omnibus)`.
 * - ERC-1155: `isApprovedForAll(committer, omnibus)`.
 *
 * Native assets need no approval (they ride along as `msg.value`).
 *
 * Note: nonstandard ERC-20s exist (missing return values, fee-on-transfer).
 * A satisfied plan does not guarantee commit success for fee-on-transfer
 * tokens — the contract reverts with `UnexpectedAmountReceived` when less
 * than the declared amount arrives.
 *
 * @param args - See {@link PlanApprovalsArgs}.
 * @returns The typed {@link ApprovalPlan}.
 * @throws QuipSdkError `CONTRACT_REVERT` when an allowance/approval read
 *   itself reverts (e.g. a non-token target address).
 * @see TermsLib.transferAssetsNoNative
 * @example
 * ```ts
 * const plan = await planApprovals({publicClient, omnibusAddress, committer: quipWallet, terms})
 * for (const item of plan.items.filter(i => !i.satisfied)) {
 *   const hash = await submitApproval({publicClient, walletClient, omnibusAddress, item, erc20Mode: 'exact'})
 * }
 * ```
 */
export async function planApprovals(args: PlanApprovalsArgs): Promise<ApprovalPlan> {
  const {publicClient, omnibusAddress, committer, terms} = args

  // aggregate ERC-20 requirements per token: the contract pulls each asset
  // entry separately, so the allowance must cover the SUM
  const erc20Required = new Map<string, {token: Address; amount: bigint}>()
  // one ERC-721 check per (token, id); one ERC-1155 check per token
  const erc721Items: {token: Address; tokenId: bigint}[] = []
  const erc1155Tokens = new Map<string, Address>()

  for (const asset of terms.assets) {
    if (asset.assetType === AssetType.Native) continue
    if (asset.assetType === AssetType.ERC20) {
      const key = asset.target.toLowerCase()
      const existing = erc20Required.get(key)
      erc20Required.set(key, {token: asset.target, amount: (existing?.amount ?? 0n) + asset.amount})
    } else if (asset.assetType === AssetType.ERC721) {
      erc721Items.push({token: asset.target, tokenId: asset.id})
    } else {
      erc1155Tokens.set(asset.target.toLowerCase(), asset.target)
    }
  }

  const items: ApprovalItem[] = []
  try {
    for (const {token, amount} of erc20Required.values()) {
      const currentAllowance = await publicClient.readContract({
        address: token,
        abi: erc20Abi,
        functionName: 'allowance',
        args: [committer, omnibusAddress],
      })
      items.push({
        kind: 'erc20',
        token,
        requiredAllowance: amount,
        currentAllowance,
        satisfied: currentAllowance >= amount,
      })
    }
    for (const {token, tokenId} of erc721Items) {
      const [approvedAddress, operatorApproved] = await Promise.all([
        publicClient.readContract({address: token, abi: erc721Abi, functionName: 'getApproved', args: [tokenId]}),
        publicClient.readContract({
          address: token,
          abi: erc721Abi,
          functionName: 'isApprovedForAll',
          args: [committer, omnibusAddress],
        }),
      ])
      const tokenApproved = approvedAddress.toLowerCase() === omnibusAddress.toLowerCase()
      items.push({
        kind: 'erc721',
        token,
        tokenId,
        tokenApproved,
        operatorApproved,
        satisfied: tokenApproved || operatorApproved,
      })
    }
    for (const token of erc1155Tokens.values()) {
      const operatorApproved = await publicClient.readContract({
        address: token,
        abi: erc1155Abi,
        functionName: 'isApprovedForAll',
        args: [committer, omnibusAddress],
      })
      items.push({kind: 'erc1155', token, operatorApproved, satisfied: operatorApproved})
    }
  } catch (error) {
    throw wrapContractError(error, 'Reading token approvals')
  }

  return {committer, omnibusAddress, items, satisfied: items.every(item => item.satisfied)}
}

/**
 * ERC-20 approval sizing. The choice is explicit because it is a real
 * trade-off the application must own:
 * - `'exact'` approves only the required amount (safer: a compromised or
 *   buggy spender can take at most the swap amount; costs one approval per
 *   swap).
 * - `'unlimited'` approves `type(uint256).max` (convenient: one approval
 *   forever; risk: the spender can pull ANY future balance).
 *
 * The SDK never defaults to unlimited.
 */
export type Erc20ApprovalMode = 'exact' | 'unlimited'

/** Arguments for {@link submitApproval}. */
export interface SubmitApprovalArgs {
  /** Public client used for simulation. */
  readonly publicClient: PublicClient
  /** Wallet client of the COMMITTER (the wallet that owns the assets). */
  readonly walletClient: WalletClient
  /** The Omnibus address to approve as spender/operator. */
  readonly omnibusAddress: Address
  /** The unsatisfied plan item to fix. */
  readonly item: ApprovalItem
  /** REQUIRED for ERC-20 items: exact or unlimited (see {@link Erc20ApprovalMode}). */
  readonly erc20Mode?: Erc20ApprovalMode
  /**
   * For ERC-721 items: `'token'` approves only the specific token id
   * (default — least privilege); `'operator'` grants `setApprovalForAll`.
   */
  readonly erc721Mode?: 'token' | 'operator'
}

const MAX_UINT256 = (1n << 256n) - 1n

/**
 * Simulates and submits the approval transaction that satisfies one
 * unsatisfied {@link ApprovalItem}.
 *
 * Always simulates before writing (`simulateContract` → `writeContract`)
 * so approval failures surface as decoded errors, not burned gas. Nothing
 * is auto-approved: the application explicitly invokes this per item.
 *
 * @param args - See {@link SubmitApprovalArgs}.
 * @returns The transaction hash. Wait for its receipt before re-planning —
 *   a hash alone does not mean the approval landed.
 * @throws QuipSdkError `MISSING_ACCOUNT` when the wallet client has no
 *   account; `INVALID_RANGE` (mode missing for ERC-20); `CONTRACT_REVERT`
 *   when simulation/submission fails.
 * @example
 * ```ts
 * const hash = await submitApproval({
 *   publicClient, walletClient, omnibusAddress,
 *   item: unsatisfiedItem, erc20Mode: 'exact',
 * })
 * await publicClient.waitForTransactionReceipt({hash})
 * ```
 */
export async function submitApproval(args: SubmitApprovalArgs): Promise<`0x${string}`> {
  const {publicClient, walletClient, omnibusAddress, item} = args
  const account = walletClient.account
  if (account === undefined) {
    throw new QuipSdkError({
      code: 'MISSING_ACCOUNT',
      message: 'The wallet client must have an account to submit an approval',
    })
  }

  try {
    if (item.kind === 'erc20') {
      if (args.erc20Mode === undefined) {
        throw new QuipSdkError({
          code: 'INVALID_RANGE',
          message:
            "ERC-20 approvals require an explicit erc20Mode ('exact' or 'unlimited'); the SDK never defaults to unlimited",
        })
      }
      const amount = args.erc20Mode === 'exact' ? item.requiredAllowance : MAX_UINT256
      const {request} = await publicClient.simulateContract({
        address: item.token,
        abi: erc20Abi,
        functionName: 'approve',
        args: [omnibusAddress, amount],
        account,
      })
      return await walletClient.writeContract(request)
    }

    if (item.kind === 'erc721') {
      if ((args.erc721Mode ?? 'token') === 'token') {
        const {request} = await publicClient.simulateContract({
          address: item.token,
          abi: erc721Abi,
          functionName: 'approve',
          args: [omnibusAddress, item.tokenId],
          account,
        })
        return await walletClient.writeContract(request)
      }
      const {request} = await publicClient.simulateContract({
        address: item.token,
        abi: erc721Abi,
        functionName: 'setApprovalForAll',
        args: [omnibusAddress, true],
        account,
      })
      return await walletClient.writeContract(request)
    }

    // erc1155: operator approval is the only mechanism the standard offers
    const {request} = await publicClient.simulateContract({
      address: item.token,
      abi: erc1155Abi,
      functionName: 'setApprovalForAll',
      args: [omnibusAddress, true],
      account,
    })
    return await walletClient.writeContract(request)
  } catch (error) {
    if (error instanceof QuipSdkError) throw error
    throw wrapContractError(error, `Approving ${item.kind} ${item.token}`)
  }
}
