/** AUTO-GENERATED from out/PQIdentityRegistry.sol/PQIdentityRegistry.json. */
export const pqIdentityRegistryAbi = [
  {
    "type": "constructor",
    "inputs": [
      {
        "name": "trustedVerifier",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "EXPECTED_VERIFIER_PROFILE",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "EXPECTED_VERIFIER_VERSION",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "TRUSTED_VERIFIER",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "TRUSTED_VERIFIER_CODEHASH",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "activeKey",
    "inputs": [
      {
        "name": "eoa",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "version",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "bytes",
        "internalType": "bytes"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "execute",
    "inputs": [
      {
        "name": "request",
        "type": "tuple",
        "internalType": "struct RegistryOperation",
        "components": [
          {
            "name": "action",
            "type": "uint8",
            "internalType": "enum RegistryActionTag"
          },
          {
            "name": "eoa",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "expectedActiveKeyVersion",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "expectedRecoveryKeyVersion",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "newActivePQKey",
            "type": "bytes",
            "internalType": "bytes"
          },
          {
            "name": "newActiveKeyVersion",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "newRecoveryPQKey",
            "type": "bytes",
            "internalType": "bytes"
          },
          {
            "name": "newRecoveryKeyVersion",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "operationNonce",
            "type": "bytes32",
            "internalType": "bytes32"
          },
          {
            "name": "expiry",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "recoveryAuthorized",
            "type": "bool",
            "internalType": "bool"
          }
        ]
      },
      {
        "name": "authorization",
        "type": "tuple",
        "internalType": "struct RegistryAuthorization",
        "components": [
          {
            "name": "eoaSignature",
            "type": "bytes",
            "internalType": "bytes"
          },
          {
            "name": "authorizingPQSignature",
            "type": "bytes",
            "internalType": "bytes"
          },
          {
            "name": "activeProofOfPossession",
            "type": "bytes",
            "internalType": "bytes"
          },
          {
            "name": "recoveryProofOfPossession",
            "type": "bytes",
            "internalType": "bytes"
          }
        ]
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "identityOf",
    "inputs": [
      {
        "name": "eoa",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "tuple",
        "internalType": "struct PQIdentity",
        "components": [
          {
            "name": "activePQKey",
            "type": "bytes",
            "internalType": "bytes"
          },
          {
            "name": "activeKeyVersion",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "recoveryPQKey",
            "type": "bytes",
            "internalType": "bytes"
          },
          {
            "name": "recoveryKeyVersion",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "active",
            "type": "bool",
            "internalType": "bool"
          }
        ]
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "isRegistryNonceConsumed",
    "inputs": [
      {
        "name": "nonceKey",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "isTrustedKey",
    "inputs": [
      {
        "name": "key",
        "type": "bytes",
        "internalType": "bytes"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "operationDigest",
    "inputs": [
      {
        "name": "request",
        "type": "tuple",
        "internalType": "struct RegistryOperation",
        "components": [
          {
            "name": "action",
            "type": "uint8",
            "internalType": "enum RegistryActionTag"
          },
          {
            "name": "eoa",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "expectedActiveKeyVersion",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "expectedRecoveryKeyVersion",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "newActivePQKey",
            "type": "bytes",
            "internalType": "bytes"
          },
          {
            "name": "newActiveKeyVersion",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "newRecoveryPQKey",
            "type": "bytes",
            "internalType": "bytes"
          },
          {
            "name": "newRecoveryKeyVersion",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "operationNonce",
            "type": "bytes32",
            "internalType": "bytes32"
          },
          {
            "name": "expiry",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "recoveryAuthorized",
            "type": "bool",
            "internalType": "bool"
          }
        ]
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "possessionDigest",
    "inputs": [
      {
        "name": "requestDigest",
        "type": "bytes32",
        "internalType": "bytes32"
      },
      {
        "name": "role",
        "type": "uint8",
        "internalType": "enum KeyRole"
      },
      {
        "name": "key",
        "type": "bytes",
        "internalType": "bytes"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ],
    "stateMutability": "pure"
  },
  {
    "type": "function",
    "name": "registerAndCommit",
    "inputs": [
      {
        "name": "request",
        "type": "tuple",
        "internalType": "struct InitialRegistration",
        "components": [
          {
            "name": "eoa",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "activePQKey",
            "type": "bytes",
            "internalType": "bytes"
          },
          {
            "name": "recoveryPQKey",
            "type": "bytes",
            "internalType": "bytes"
          },
          {
            "name": "commitTarget",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "commitPayloadHash",
            "type": "bytes32",
            "internalType": "bytes32"
          },
          {
            "name": "operationNonce",
            "type": "bytes32",
            "internalType": "bytes32"
          },
          {
            "name": "expiry",
            "type": "uint256",
            "internalType": "uint256"
          }
        ]
      },
      {
        "name": "eoaSignature",
        "type": "bytes",
        "internalType": "bytes"
      },
      {
        "name": "activeProof",
        "type": "bytes",
        "internalType": "bytes"
      },
      {
        "name": "recoveryProof",
        "type": "bytes",
        "internalType": "bytes"
      },
      {
        "name": "commitData",
        "type": "bytes",
        "internalType": "bytes"
      }
    ],
    "outputs": [],
    "stateMutability": "payable"
  },
  {
    "type": "function",
    "name": "registrationDigest",
    "inputs": [
      {
        "name": "request",
        "type": "tuple",
        "internalType": "struct InitialRegistration",
        "components": [
          {
            "name": "eoa",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "activePQKey",
            "type": "bytes",
            "internalType": "bytes"
          },
          {
            "name": "recoveryPQKey",
            "type": "bytes",
            "internalType": "bytes"
          },
          {
            "name": "commitTarget",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "commitPayloadHash",
            "type": "bytes32",
            "internalType": "bytes32"
          },
          {
            "name": "operationNonce",
            "type": "bytes32",
            "internalType": "bytes32"
          },
          {
            "name": "expiry",
            "type": "uint256",
            "internalType": "uint256"
          }
        ]
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "registryNonceKey",
    "inputs": [
      {
        "name": "eoa",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "role",
        "type": "uint8",
        "internalType": "enum KeyRole"
      },
      {
        "name": "version",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "nonce",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "event",
    "name": "ActiveKeyRotated",
    "inputs": [
      {
        "name": "eoa",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "activeKeyVersion",
        "type": "uint256",
        "indexed": true,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "IdentityRecovered",
    "inputs": [
      {
        "name": "eoa",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "activeKeyVersion",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "recoveryKeyVersion",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "IdentityRegistered",
    "inputs": [
      {
        "name": "eoa",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "activeKeyVersion",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "recoveryKeyVersion",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "IdentityRevoked",
    "inputs": [
      {
        "name": "eoa",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "authorizingRole",
        "type": "uint8",
        "indexed": true,
        "internalType": "enum KeyRole"
      },
      {
        "name": "authorizingKeyVersion",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "RecoveryKeyRotated",
    "inputs": [
      {
        "name": "eoa",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "recoveryKeyVersion",
        "type": "uint256",
        "indexed": true,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "RegistryNonceConsumed",
    "inputs": [
      {
        "name": "nonceKey",
        "type": "bytes32",
        "indexed": true,
        "internalType": "bytes32"
      },
      {
        "name": "eoa",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "operationNonce",
        "type": "bytes32",
        "indexed": true,
        "internalType": "bytes32"
      }
    ],
    "anonymous": false
  },
  {
    "type": "error",
    "name": "AlreadyRegistered",
    "inputs": []
  },
  {
    "type": "error",
    "name": "CommitCallbackFailed",
    "inputs": []
  },
  {
    "type": "error",
    "name": "IdentityNotActive",
    "inputs": []
  },
  {
    "type": "error",
    "name": "IdentityNotRegistered",
    "inputs": []
  },
  {
    "type": "error",
    "name": "InvalidEOAAuthorization",
    "inputs": []
  },
  {
    "type": "error",
    "name": "InvalidKey",
    "inputs": []
  },
  {
    "type": "error",
    "name": "InvalidOperationShape",
    "inputs": []
  },
  {
    "type": "error",
    "name": "InvalidPQAuthorization",
    "inputs": []
  },
  {
    "type": "error",
    "name": "InvalidVerifier",
    "inputs": []
  },
  {
    "type": "error",
    "name": "InvalidVersion",
    "inputs": []
  },
  {
    "type": "error",
    "name": "RegistryNonceAlreadyConsumed",
    "inputs": [
      {
        "name": "nonceKey",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ]
  },
  {
    "type": "error",
    "name": "RequestExpired",
    "inputs": []
  }
] as const
