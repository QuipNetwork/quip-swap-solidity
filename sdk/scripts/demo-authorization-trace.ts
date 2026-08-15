import {getAddress} from 'viem'
import type {Address, Hex} from 'viem'
import {AuthorizationMode, commitPayloadHash} from '../src/index.js'
import type {Hex32, PreparedAuthorization} from '../src/index.js'

export const AUTHORIZATION_TRACE_SCHEMA = 'quip-swap-authorization-trace.v1' as const

export type DemoCommitSide = 'alice' | 'bob'
export type DemoAuthorizationMode = 'quip-wallet' | 'registered-direct'

export interface AuthorizationTraceContext {
  readonly side: DemoCommitSide
  readonly prepared: PreparedAuthorization
  readonly signatureVerifier: Address
  readonly authenticatedSubmitter: Address
}

export type AuthorizationTraceResult =
  | {readonly status: 'accepted'; readonly transactionHash: Hex}
  | {readonly status: 'reverted'; readonly transactionHash?: Hex; readonly errorName: string}

export interface AuthorizationBoundaryRecord {
  readonly sequence: number
  readonly side: DemoCommitSide
  readonly chainId: string
  readonly authorizationMode: DemoAuthorizationMode
  readonly signatureVerifier: Address
  readonly wallet: Address | null
  readonly gateway: Address | null
  readonly commitPayloadHash: Hex32
  readonly authenticatedSubmitter: Address
  readonly actionNonce: Hex32
  readonly expiry: string
  readonly status: AuthorizationTraceResult['status']
  readonly transactionHash: Hex | null
  readonly errorName: string | null
}

export interface AuthorizationTraceArtifact {
  readonly schema: typeof AUTHORIZATION_TRACE_SCHEMA
  readonly records: readonly AuthorizationBoundaryRecord[]
}

export class AuthorizationTraceRecorder {
  readonly #records: AuthorizationBoundaryRecord[] = []

  record(context: AuthorizationTraceContext, result: AuthorizationTraceResult): AuthorizationBoundaryRecord {
    const payload = context.prepared.payload
    validatePreparedAuthorization(context.prepared)
    const side = payload.party ? payload.terms.partySide : payload.terms.counterpartySide
    const endpoint = getAddress(payload.authorizationVerifier)
    const wallet = side.authorizationMode === AuthorizationMode.QuipWallet ? endpoint : null
    const gateway = side.authorizationMode === AuthorizationMode.RegisteredDirect ? endpoint : null
    const mode = authorizationModeName(side.authorizationMode)
    if (context.side !== (payload.party ? 'alice' : 'bob')) throw new Error('authorization trace side does not match payload')
    if (result.status === 'reverted' && result.errorName.trim() === '') throw new Error('reverted authorization requires an error name')
    const record: AuthorizationBoundaryRecord = {
      sequence: this.#records.length + 1,
      side: context.side,
      chainId: side.chainId.toString(),
      authorizationMode: mode,
      signatureVerifier: getAddress(context.signatureVerifier),
      wallet,
      gateway,
      commitPayloadHash: context.prepared.payloadHash,
      authenticatedSubmitter: getAddress(context.authenticatedSubmitter),
      actionNonce: payload.actionNonce,
      expiry: payload.expiry.toString(),
      status: result.status,
      transactionHash: result.transactionHash ?? null,
      errorName: result.status === 'reverted' ? result.errorName : null,
    }
    this.#records.push(record)
    return record
  }

  artifact(): AuthorizationTraceArtifact {
    return {schema: AUTHORIZATION_TRACE_SCHEMA, records: this.#records.map(record => ({...record}))}
  }
}

function validatePreparedAuthorization(prepared: PreparedAuthorization): void {
  if (commitPayloadHash(prepared.payload) !== prepared.payloadHash) {
    throw new Error('authorization trace payload hash mismatch')
  }
}

function authorizationModeName(mode: AuthorizationMode): DemoAuthorizationMode {
  if (mode === AuthorizationMode.QuipWallet) return 'quip-wallet'
  if (mode === AuthorizationMode.RegisteredDirect) return 'registered-direct'
  throw new Error('unsupported authorization mode')
}

const SENSITIVE_TRACE_FIELDS = new Set(['signature', 'pqSignature', 'commitData', 'settlementSecret', 'bobCommitSecret', 'preimage'])

export function serializeAuthorizationTrace(artifact: AuthorizationTraceArtifact): string {
  assertSafeTraceValue(artifact)
  return `${JSON.stringify(artifact, null, 2)}\n`
}

function assertSafeTraceValue(value: unknown): void {
  if (value === null || typeof value !== 'object') return
  if (Array.isArray(value)) {
    for (const entry of value) assertSafeTraceValue(entry)
    return
  }
  for (const [key, entry] of Object.entries(value)) {
    if (SENSITIVE_TRACE_FIELDS.has(key)) throw new Error(`authorization trace contains sensitive field: ${key}`)
    assertSafeTraceValue(entry)
  }
}
