/** AUTO-GENERATED from out/QuipWallet.sol/QuipWallet.json. */
export const quipWalletAbi = [
  {
    "type": "constructor",
    "inputs": [
      {
        "name": "owner",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "registry",
        "type": "address",
        "internalType": "contract DirectAuthorization"
      },
      {
        "name": "initialPQKey",
        "type": "bytes",
        "internalType": "bytes"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "receive",
    "stateMutability": "payable"
  },
  {
    "type": "function",
    "name": "OWNER",
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
    "name": "REGISTRY",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "contract DirectAuthorization"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "activeKeyHash",
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
    "name": "authorizeCommit",
    "inputs": [
      {
        "name": "request",
        "type": "tuple",
        "internalType": "struct CommitAuthorizationRequest",
        "components": [
          {
            "name": "receiver",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "terms",
            "type": "tuple",
            "internalType": "struct ProtocolTerms",
            "components": [
              {
                "name": "partySide",
                "type": "tuple",
                "internalType": "struct SideTerms",
                "components": [
                  {
                    "name": "chainId",
                    "type": "uint256",
                    "internalType": "uint256"
                  },
                  {
                    "name": "assets",
                    "type": "tuple[]",
                    "internalType": "struct Asset[]",
                    "components": [
                      {
                        "name": "assetType",
                        "type": "uint8",
                        "internalType": "enum AssetType"
                      },
                      {
                        "name": "target",
                        "type": "address",
                        "internalType": "address"
                      },
                      {
                        "name": "id",
                        "type": "uint256",
                        "internalType": "uint256"
                      },
                      {
                        "name": "amount",
                        "type": "uint256",
                        "internalType": "uint256"
                      }
                    ]
                  },
                  {
                    "name": "principal",
                    "type": "address",
                    "internalType": "address"
                  },
                  {
                    "name": "authorizationMode",
                    "type": "uint8",
                    "internalType": "enum AuthorizationMode"
                  },
                  {
                    "name": "principalKeyVersion",
                    "type": "uint256",
                    "internalType": "uint256"
                  },
                  {
                    "name": "reclaimRecipient",
                    "type": "address",
                    "internalType": "address"
                  },
                  {
                    "name": "recipient",
                    "type": "address",
                    "internalType": "address"
                  },
                  {
                    "name": "commitmentDeadline",
                    "type": "uint256",
                    "internalType": "uint256"
                  },
                  {
                    "name": "claimDeadline",
                    "type": "uint256",
                    "internalType": "uint256"
                  },
                  {
                    "name": "reclaimRelease",
                    "type": "uint256",
                    "internalType": "uint256"
                  },
                  {
                    "name": "commitLock",
                    "type": "bytes32",
                    "internalType": "bytes32"
                  },
                  {
                    "name": "delegationPolicy",
                    "type": "uint8",
                    "internalType": "enum DelegationPolicy"
                  },
                  {
                    "name": "delegate",
                    "type": "address",
                    "internalType": "address"
                  },
                  {
                    "name": "delegateKeyVersion",
                    "type": "uint256",
                    "internalType": "uint256"
                  },
                  {
                    "name": "sideNonce",
                    "type": "bytes32",
                    "internalType": "bytes32"
                  }
                ]
              },
              {
                "name": "counterpartySide",
                "type": "tuple",
                "internalType": "struct SideTerms",
                "components": [
                  {
                    "name": "chainId",
                    "type": "uint256",
                    "internalType": "uint256"
                  },
                  {
                    "name": "assets",
                    "type": "tuple[]",
                    "internalType": "struct Asset[]",
                    "components": [
                      {
                        "name": "assetType",
                        "type": "uint8",
                        "internalType": "enum AssetType"
                      },
                      {
                        "name": "target",
                        "type": "address",
                        "internalType": "address"
                      },
                      {
                        "name": "id",
                        "type": "uint256",
                        "internalType": "uint256"
                      },
                      {
                        "name": "amount",
                        "type": "uint256",
                        "internalType": "uint256"
                      }
                    ]
                  },
                  {
                    "name": "principal",
                    "type": "address",
                    "internalType": "address"
                  },
                  {
                    "name": "authorizationMode",
                    "type": "uint8",
                    "internalType": "enum AuthorizationMode"
                  },
                  {
                    "name": "principalKeyVersion",
                    "type": "uint256",
                    "internalType": "uint256"
                  },
                  {
                    "name": "reclaimRecipient",
                    "type": "address",
                    "internalType": "address"
                  },
                  {
                    "name": "recipient",
                    "type": "address",
                    "internalType": "address"
                  },
                  {
                    "name": "commitmentDeadline",
                    "type": "uint256",
                    "internalType": "uint256"
                  },
                  {
                    "name": "claimDeadline",
                    "type": "uint256",
                    "internalType": "uint256"
                  },
                  {
                    "name": "reclaimRelease",
                    "type": "uint256",
                    "internalType": "uint256"
                  },
                  {
                    "name": "commitLock",
                    "type": "bytes32",
                    "internalType": "bytes32"
                  },
                  {
                    "name": "delegationPolicy",
                    "type": "uint8",
                    "internalType": "enum DelegationPolicy"
                  },
                  {
                    "name": "delegate",
                    "type": "address",
                    "internalType": "address"
                  },
                  {
                    "name": "delegateKeyVersion",
                    "type": "uint256",
                    "internalType": "uint256"
                  },
                  {
                    "name": "sideNonce",
                    "type": "bytes32",
                    "internalType": "bytes32"
                  }
                ]
              }
            ]
          },
          {
            "name": "party",
            "type": "bool",
            "internalType": "bool"
          },
          {
            "name": "lock",
            "type": "bytes32",
            "internalType": "bytes32"
          },
          {
            "name": "actionNonce",
            "type": "bytes32",
            "internalType": "bytes32"
          },
          {
            "name": "bobCommitSecret",
            "type": "bytes32",
            "internalType": "bytes32"
          },
          {
            "name": "expiry",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "commitData",
            "type": "bytes",
            "internalType": "bytes"
          }
        ]
      },
      {
        "name": "signature",
        "type": "bytes",
        "internalType": "bytes"
      }
    ],
    "outputs": [],
    "stateMutability": "payable"
  },
  {
    "type": "function",
    "name": "consumedRotationNonces",
    "inputs": [
      {
        "name": "",
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
    "name": "execute",
    "inputs": [
      {
        "name": "target",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "value",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "data",
        "type": "bytes",
        "internalType": "bytes"
      }
    ],
    "outputs": [
      {
        "name": "result",
        "type": "bytes",
        "internalType": "bytes"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "rotateActiveKey",
    "inputs": [
      {
        "name": "newPQKey",
        "type": "bytes",
        "internalType": "bytes"
      },
      {
        "name": "rotationNonce",
        "type": "bytes32",
        "internalType": "bytes32"
      },
      {
        "name": "expiry",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "currentKeySignature",
        "type": "bytes",
        "internalType": "bytes"
      },
      {
        "name": "newKeyProof",
        "type": "bytes",
        "internalType": "bytes"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "rotationDigest",
    "inputs": [
      {
        "name": "newPQKey",
        "type": "bytes",
        "internalType": "bytes"
      },
      {
        "name": "nonce",
        "type": "bytes32",
        "internalType": "bytes32"
      },
      {
        "name": "expiry",
        "type": "uint256",
        "internalType": "uint256"
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
    "name": "walletKeyEpoch",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "error",
    "name": "AuthorizationExpired",
    "inputs": []
  },
  {
    "type": "error",
    "name": "ExecutionFailed",
    "inputs": []
  },
  {
    "type": "error",
    "name": "InvalidAuthorizationMode",
    "inputs": []
  },
  {
    "type": "error",
    "name": "InvalidChain",
    "inputs": []
  },
  {
    "type": "error",
    "name": "InvalidKey",
    "inputs": []
  },
  {
    "type": "error",
    "name": "InvalidPQAuthorization",
    "inputs": []
  },
  {
    "type": "error",
    "name": "InvalidTransportSubmitter",
    "inputs": []
  },
  {
    "type": "error",
    "name": "InvalidWalletPrincipal",
    "inputs": []
  },
  {
    "type": "error",
    "name": "NotOwner",
    "inputs": []
  },
  {
    "type": "error",
    "name": "RotationNonceAlreadyConsumed",
    "inputs": []
  }
] as const
