import {describe, expect, test} from 'vitest'
import {
  KeyRole, RegistryActionTag, encodeRegistryNonceKey, keyPossessionDigest,
  registrationDigest, registryOperationDigest, walletRotationDigest,
} from '../../src/protocol.js'
import type {InitialRegistration, RegistryOperation} from '../../src/protocol.js'
import {keccak256} from 'viem'

const registry = '0x0000000000000000000000000000000000001000' as const
const eoa = '0x0000000000000000000000000000000000002000' as const
const target = '0x0000000000000000000000000000000000003000' as const
const activeKey = '0x0000000000000000000000000000000000004000616374697665' as const
const recoveryKey = '0x00000000000000000000000000000000000040007265636f76657279' as const
const nonce = `0x${'11'.repeat(32)}` as `0x${string}`

const registration: InitialRegistration = {
  eoa, activePQKey: activeKey, recoveryPQKey: recoveryKey, commitTarget: target,
  commitPayloadHash: `0x${'22'.repeat(32)}` as `0x${string}`, operationNonce: nonce, expiry: 2_000n,
}
const rotation: RegistryOperation = {
  action: RegistryActionTag.RotateActive, eoa, expectedActiveKeyVersion: 1n,
  expectedRecoveryKeyVersion: 1n, newActivePQKey: `${activeKey}32`, newActiveKeyVersion: 2n,
  newRecoveryPQKey: '0x', newRecoveryKeyVersion: 0n, operationNonce: nonce,
  expiry: 2_000n, recoveryAuthorized: false,
}

describe('v1.1 registry protocol hashing', () => {
  test('registration binds chain, registry, target, keys, commit and expiry', () => {
    const digest = registrationDigest(31337n, registry, registration)
    expect(registrationDigest(31337n, registry, registration)).toBe(digest)
    expect(registrationDigest(31338n, registry, registration)).not.toBe(digest)
    expect(registrationDigest(31337n, registry, {...registration, expiry: 2_001n})).not.toBe(digest)
  })
  test('lifecycle and possession digests bind action-specific data', () => {
    const digest = registryOperationDigest(31337n, registry, rotation)
    expect(registryOperationDigest(31337n, registry, {...rotation, newActiveKeyVersion: 3n})).not.toBe(digest)
    expect(keyPossessionDigest(digest, KeyRole.Active, rotation.newActivePQKey))
      .not.toBe(keyPossessionDigest(digest, KeyRole.Recovery, rotation.newActivePQKey))
  })
  test("wallet rotation binds internal epoch and both key hashes", () => {
    const currentHash = keccak256(activeKey)
    const digest = walletRotationDigest(31337n, target, 1n, currentHash, recoveryKey, nonce, 2_000n)
    expect(walletRotationDigest(31337n, target, 2n, currentHash, recoveryKey, nonce, 2_000n)).not.toBe(digest)
    expect(walletRotationDigest(31337n, target, 1n, currentHash, activeKey, nonce, 2_000n)).not.toBe(digest)
  })

  test('registry nonce keys are role and version scoped', () => {
    const key = keccak256(encodeRegistryNonceKey(31337n, registry, eoa, KeyRole.Active, 1n, nonce))
    expect(keccak256(encodeRegistryNonceKey(31337n, registry, eoa, KeyRole.Recovery, 1n, nonce))).not.toBe(key)
    expect(keccak256(encodeRegistryNonceKey(31337n, registry, eoa, KeyRole.Active, 2n, nonce))).not.toBe(key)
  })
})
