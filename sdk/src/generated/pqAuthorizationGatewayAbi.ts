/** AUTO-GENERATED from out/PQAuthorizationGateway.sol/PQAuthorizationGateway.json. */
export const pqAuthorizationGatewayAbi = [
  {
    "type": "constructor",
    "inputs": [
      {
        "name": "registry",
        "type": "address",
        "internalType": "contract PQIdentityRegistry"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "REGISTRY",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "contract PQIdentityRegistry"
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
                "name": "timingPolicyId",
                "type": "bytes32",
                "internalType": "bytes32"
              },
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
    "name": "completeRegisteredCommit",
    "inputs": [
      {
        "name": "eoa",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "registeredPayloadHash",
        "type": "bytes32",
        "internalType": "bytes32"
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
    "type": "error",
    "name": "AuthorizationExpired",
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
    "name": "InvalidPQAuthorization",
    "inputs": []
  },
  {
    "type": "error",
    "name": "InvalidRegisteredSubmitter",
    "inputs": []
  },
  {
    "type": "error",
    "name": "InvalidRegistryCaller",
    "inputs": []
  },
  {
    "type": "error",
    "name": "InvalidTransportSubmitter",
    "inputs": []
  },
  {
    "type": "error",
    "name": "RegistrationPayloadMismatch",
    "inputs": []
  }
] as const
