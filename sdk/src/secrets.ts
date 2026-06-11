/**
 * Cryptographically secure secret generation for hashlocks.
 *
 * Secrecy lifecycle (applies to every secret produced or accepted here):
 * - The LOCK may be shared freely; it is published on-chain at commit.
 * - The SECRET must remain private until the holder claims — the on-chain
 *   `Claim` event then reveals it publicly.
 * - Revealing the secret early compromises a cross-chain flow: anyone can
 *   claim once they hold the secret inside an open claim window.
 * - Losing the secret makes claiming impossible; escrowed assets are then
 *   only recoverable via reclaim after `reclaimRelease`.
 *
 * The SDK never logs or prints secrets, and error messages never echo
 * secret values.
 */
import {bytesToHex} from 'viem'
import {assertHex32, generateLock} from './hashing.js'
import type {Hex32, SecretLockPair} from './types.js'

/**
 * Generates a fresh 32-byte secret and its lock.
 *
 * Uses `crypto.getRandomValues` (the runtime's CSPRNG — available in
 * browsers, Node.js >= 19, and Bun). Never uses `Math.random()`,
 * timestamps, counters, or any other predictable source: a guessable
 * secret lets an attacker claim the counterparty's escrowed assets.
 *
 * @returns A {@link SecretLockPair} where `lock === generateLock(secret)`.
 *   Keep `secret` private until claim; `lock` is safe to share.
 * @see Omnibus._generateLock
 * @example
 * ```ts
 * const {secret, lock} = generateSecret()
 * // share `lock` with the counterparty; keep `secret` private
 * ```
 */
export function generateSecret(): SecretLockPair {
  const bytes = new Uint8Array(32)
  // SECURITY: CSPRNG only. globalThis.crypto exists in all supported runtimes.
  globalThis.crypto.getRandomValues(bytes)
  const secret = bytesToHex(bytes) as Hex32
  return Object.freeze({secret, lock: generateLock(secret)})
}

/**
 * Validates an externally supplied secret and derives its lock.
 *
 * Use this instead of {@link generateLock} when the secret comes from
 * storage or another process and you want the validated pair back.
 *
 * @param secret - A 0x-prefixed 32-byte hex string.
 * @returns The validated {@link SecretLockPair}.
 * @throws QuipSdkError `INVALID_HEX32` if the secret is malformed or not
 *   exactly 32 bytes (the error never echoes the supplied value).
 * @example
 * ```ts
 * const pair = secretToPair(loadSecretFromVault())
 * ```
 */
export function secretToPair(secret: string): SecretLockPair {
  assertHex32(secret, 'secret')
  return Object.freeze({secret, lock: generateLock(secret)})
}
