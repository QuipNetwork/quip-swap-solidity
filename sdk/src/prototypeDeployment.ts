import {
  concat,
  encodeAbiParameters,
  getAddress,
  getContractAddress,
  getCreate2Address,
  keccak256,
  pad,
  stringToHex,
  toHex,
} from 'viem'
import type {Address, Hex} from 'viem'
import {
  BASE_SEPOLIA_TO_OP_SEPOLIA_POLICY_ID,
  OP_SEPOLIA_TO_BASE_SEPOLIA_POLICY_ID,
} from './prototypeTiming.js'
import type {Hex32} from './types.js'

export const PROTOTYPE_DEPLOYMENT_VERSION = 'v1.1.0-alpha.1'
export const CANONICAL_CREATEX: Address = getAddress('0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed')
const CREATE3_PROXY_INITCODE_HASH: Hex32 =
  '0x21c35dbe1b344a2488cf3321d6ce542f8e9f305544ff09e4993a62319a497c1f'

export const prototypeComponents = [
  'assetSupportRegistry',
  'timingPolicyRegistry',
  'identityRegistry',
  'authorizationGateway',
  'crossChainWrapper',
  'sameChainWrapper',
] as const

export type PrototypeComponent = (typeof prototypeComponents)[number]
export type PrototypeDeploymentAddresses = Readonly<Record<PrototypeComponent, Address>>

export interface PrototypeDeploymentManifest {
  readonly version: typeof PROTOTYPE_DEPLOYMENT_VERSION
  readonly chainId: bigint
  readonly createX: Address
  readonly deployer: Address
  readonly owner: Address
  readonly trustedVerifier: Address
  readonly addresses: PrototypeDeploymentAddresses
  readonly policyIds: readonly [Hex32, Hex32]
  readonly vectorHash: Hex32
}

export function prototypeDeploymentSalt(deployer: Address, index: number): Hex32 {
  const entropy = keccak256(concat([stringToHex(`QUIP:Swap:${PROTOTYPE_DEPLOYMENT_VERSION}:`), toHex(index, {size: 1})]))
    .slice(2, 24) as string
  return concat([deployer, '0x00', `0x${entropy}`]) as Hex32
}

export function predictPrototypeAddresses(
  deployer: Address,
  createX: Address = CANONICAL_CREATEX,
): PrototypeDeploymentAddresses {
  const entries = prototypeComponents.map((component, index) => {
    const rawSalt = prototypeDeploymentSalt(deployer, index)
    const guardedSalt = keccak256(concat([pad(deployer, {size: 32}), rawSalt]))
    const proxy = getCreate2Address({from: createX, salt: guardedSalt, bytecodeHash: CREATE3_PROXY_INITCODE_HASH})
    return [component, getContractAddress({from: proxy, nonce: 1n})] as const
  })
  return Object.fromEntries(entries) as unknown as PrototypeDeploymentAddresses
}

export function prototypeDeploymentVectorHash(
  chainId: bigint,
  createX: Address,
  deployer: Address,
  owner: Address,
  trustedVerifier: Address,
  addresses: PrototypeDeploymentAddresses,
): Hex32 {
  return keccak256(
    encodeAbiParameters(
      [
        {type: 'string'},
        {type: 'uint256'},
        {type: 'address'},
        {type: 'address'},
        {type: 'address'},
        {type: 'address'},
        {type: 'address[6]'},
        {type: 'bytes32[2]'},
      ],
      [
        PROTOTYPE_DEPLOYMENT_VERSION,
        chainId,
        createX,
        deployer,
        owner,
        trustedVerifier,
        prototypeComponents.map(component => addresses[component]) as unknown as readonly [
          Address,
          Address,
          Address,
          Address,
          Address,
          Address,
        ],
        [BASE_SEPOLIA_TO_OP_SEPOLIA_POLICY_ID, OP_SEPOLIA_TO_BASE_SEPOLIA_POLICY_ID],
      ],
    ),
  )
}

export function buildPrototypeDeploymentManifest(args: {
  readonly chainId: bigint
  readonly deployer: Address
  readonly owner: Address
  readonly trustedVerifier: Address
  readonly createX?: Address
}): PrototypeDeploymentManifest {
  const createX = args.createX ?? CANONICAL_CREATEX
  const addresses = predictPrototypeAddresses(args.deployer, createX)
  return {
    version: PROTOTYPE_DEPLOYMENT_VERSION,
    chainId: args.chainId,
    createX,
    deployer: args.deployer,
    owner: args.owner,
    trustedVerifier: args.trustedVerifier,
    addresses,
    policyIds: [BASE_SEPOLIA_TO_OP_SEPOLIA_POLICY_ID, OP_SEPOLIA_TO_BASE_SEPOLIA_POLICY_ID],
    vectorHash: prototypeDeploymentVectorHash(
      args.chainId,
      createX,
      args.deployer,
      args.owner,
      args.trustedVerifier,
      addresses,
    ),
  }
}
