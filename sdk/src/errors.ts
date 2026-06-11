/**
 * SDK error type and contract custom-error decoding.
 *
 * Every error the SDK raises is a {@link QuipSdkError} carrying a stable
 * machine-readable `code`. Errors that originate from a reverted contract
 * call additionally carry the decoded Solidity custom-error name in
 * `contractErrorName`, and the original Viem error is always preserved in
 * `cause` — never discarded.
 */
import {BaseError, ContractFunctionRevertedError} from 'viem'

/**
 * Stable machine-readable SDK error codes.
 *
 * Codes prefixed with contract semantics (e.g. `CONTRACT_REVERT`) wrap an
 * on-chain revert; the rest are produced by SDK-side preflight validation
 * BEFORE any transaction is sent. SDK validation mirrors but never replaces
 * contract enforcement.
 */
export type QuipSdkErrorCode =
  // asset / terms structural validation (mirrors TermsLib.validateAsset / validateTerms)
  | 'ZERO_AMOUNT'
  | 'INVALID_NATIVE_ASSET'
  | 'INVALID_ERC20_ASSET'
  | 'INVALID_ERC721_ASSET'
  | 'INVALID_ERC1155_ASSET'
  | 'INVALID_ASSET_TYPE'
  | 'EMPTY_ASSETS'
  | 'ZERO_ADDRESS_RECIPIENT'
  | 'ZERO_DEADLINE'
  | 'DISORDERED_DEADLINES'
  | 'ZERO_CHAIN_ID'
  // pairing / window validation (mirrors TermsLib.validateTermPairing / enforceWithin)
  | 'INVALID_RANGE'
  | 'WINDOW_VIOLATED'
  // secrets and hex inputs
  | 'INVALID_HEX32'
  // client preflight
  | 'CHAIN_ID_MISMATCH'
  | 'NOT_QUIP_WALLET'
  | 'MISSING_WALLET_CLIENT'
  | 'MISSING_ACCOUNT'
  | 'TERMS_NOT_ON_CHAIN'
  // cross-chain schedule validation
  | 'SECRET_HOLDER_NOT_PROPOSER'
  | 'INSUFFICIENT_BUFFER'
  // deployments
  | 'UNKNOWN_DEPLOYMENT'
  // receipts / events
  | 'TRANSACTION_REVERTED'
  | 'EVENT_NOT_FOUND'
  // wrapped on-chain revert (see contractErrorName for the Solidity error)
  | 'CONTRACT_REVERT'

/**
 * Structured details carried by every {@link QuipSdkError}.
 */
export interface QuipSdkErrorDetails {
  /** Stable machine-readable code; safe to branch on. */
  readonly code: QuipSdkErrorCode
  /** Human-readable explanation with remediation guidance. */
  readonly message: string
  /**
   * The decoded Solidity custom-error name (e.g. `CallerNotQuipWallet`,
   * `WindowViolated`) when the error wraps an on-chain revert and the error
   * was decodable from the Omnibus ABI.
   */
  readonly contractErrorName?: string
  /** The original underlying error (e.g. the Viem error), never discarded. */
  readonly cause?: unknown
  /** Additional structured context (offending values, window bounds, ...). */
  readonly details?: unknown
}

/**
 * The error class thrown by every SDK function.
 *
 * @example
 * ```ts
 * try {
 *   await client.commit({lock, party, counterparty})
 * } catch (err) {
 *   if (err instanceof QuipSdkError && err.code === 'NOT_QUIP_WALLET') {
 *     // the sender is not registered with the QuipFactory
 *   }
 * }
 * ```
 */
export class QuipSdkError extends Error implements QuipSdkErrorDetails {
  override readonly name = 'QuipSdkError'
  readonly code: QuipSdkErrorCode
  readonly contractErrorName?: string
  override readonly cause?: unknown
  readonly details?: unknown

  constructor(args: QuipSdkErrorDetails) {
    super(args.message)
    this.code = args.code
    if (args.contractErrorName !== undefined) this.contractErrorName = args.contractErrorName
    if (args.cause !== undefined) this.cause = args.cause
    if (args.details !== undefined) this.details = args.details
  }
}

/**
 * Extracts the decoded Solidity custom-error name from a Viem error, if any.
 *
 * Viem decodes custom errors against the contract ABI during
 * `simulateContract` / `readContract`; this helper walks the error chain
 * (structured decoding — no parsing of human-readable strings) and returns
 * e.g. `"CallerNotQuipWallet"` or `"WindowViolated"`.
 *
 * @param error - Any error thrown by a Viem contract action.
 * @returns The custom error name, or `undefined` when the revert could not
 *   be decoded (e.g. an out-of-ABI token error with no registered ABI).
 */
export function extractContractErrorName(error: unknown): string | undefined {
  if (error instanceof BaseError) {
    const revert = error.walk(e => e instanceof ContractFunctionRevertedError)
    if (revert instanceof ContractFunctionRevertedError) {
      return revert.data?.errorName ?? revert.signature
    }
  }
  return undefined
}

/**
 * Wraps an error thrown by a Viem contract action into a
 * {@link QuipSdkError} with code `CONTRACT_REVERT`, preserving the original
 * error in `cause` and the decoded custom-error name (when available) in
 * `contractErrorName`.
 *
 * @param error - The original error thrown by Viem.
 * @param context - Short description of the operation that failed.
 * @returns A `QuipSdkError` wrapping the original error.
 */
export function wrapContractError(error: unknown, context: string): QuipSdkError {
  const contractErrorName = extractContractErrorName(error)
  const suffix = contractErrorName !== undefined ? ` (contract error: ${contractErrorName})` : ''
  return new QuipSdkError({
    code: 'CONTRACT_REVERT',
    message: `${context} reverted${suffix}`,
    ...(contractErrorName !== undefined ? {contractErrorName} : {}),
    cause: error,
  })
}
