/** AUTO-GENERATED from out/SameChainWrapper.sol/SameChainWrapper.json. */
export const sameChainWrapperAbi = [
  {
    "type": "constructor",
    "inputs": [
      {
        "name": "directAuthorization",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "assetSupport",
        "type": "address",
        "internalType": "contract IAssetSupportRegistry"
      },
      {
        "name": "htlcImplementation",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "initialOwner",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "ASSET_SUPPORT",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "contract IAssetSupportRegistry"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "DIRECT_AUTHORIZATION",
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
    "name": "HTLC_IMPLEMENTATION",
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
    "name": "MAX_FEE",
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
    "type": "function",
    "name": "acceptOwnership",
    "inputs": [],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "accruedFees",
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
    "type": "function",
    "name": "claim",
    "inputs": [
      {
        "name": "",
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
        "name": "",
        "type": "bytes32",
        "internalType": "bytes32"
      },
      {
        "name": "",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ],
    "outputs": [],
    "stateMutability": "pure"
  },
  {
    "type": "function",
    "name": "commitmentFee",
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
    "type": "function",
    "name": "executeSettlement",
    "inputs": [
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
        "name": "lock",
        "type": "bytes32",
        "internalType": "bytes32"
      },
      {
        "name": "party",
        "type": "bool",
        "internalType": "bool"
      },
      {
        "name": "maxAssets",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "htlcOf",
    "inputs": [
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
      }
    ],
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
    "name": "onERC1155BatchReceived",
    "inputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "",
        "type": "uint256[]",
        "internalType": "uint256[]"
      },
      {
        "name": "",
        "type": "uint256[]",
        "internalType": "uint256[]"
      },
      {
        "name": "",
        "type": "bytes",
        "internalType": "bytes"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "bytes4",
        "internalType": "bytes4"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "onERC1155Received",
    "inputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "",
        "type": "bytes",
        "internalType": "bytes"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "bytes4",
        "internalType": "bytes4"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "onERC721Received",
    "inputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "",
        "type": "bytes",
        "internalType": "bytes"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "bytes4",
        "internalType": "bytes4"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "owner",
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
    "name": "pendingOwner",
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
    "name": "predictHTLC",
    "inputs": [
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
      }
    ],
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
    "name": "receiveAuthorizedCommit",
    "inputs": [
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
        "name": "bobCommitSecret",
        "type": "bytes32",
        "internalType": "bytes32"
      },
      {
        "name": "evidence",
        "type": "tuple",
        "internalType": "struct VerifiedCommitAuthorization",
        "components": [
          {
            "name": "payloadHash",
            "type": "bytes32",
            "internalType": "bytes32"
          },
          {
            "name": "wrapperCaller",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "authenticatedSubmitter",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "authenticatedSubmitterKeyVersion",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "expectedSourceState",
            "type": "uint8",
            "internalType": "enum ExpectedSourceState"
          },
          {
            "name": "actionNonce",
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
        "name": "",
        "type": "bytes",
        "internalType": "bytes"
      }
    ],
    "outputs": [],
    "stateMutability": "payable"
  },
  {
    "type": "function",
    "name": "reclaimBoth",
    "inputs": [
      {
        "name": "",
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
        "name": "",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ],
    "outputs": [],
    "stateMutability": "pure"
  },
  {
    "type": "function",
    "name": "reclaimParty",
    "inputs": [
      {
        "name": "",
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
        "name": "",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ],
    "outputs": [],
    "stateMutability": "pure"
  },
  {
    "type": "function",
    "name": "renounceOwnership",
    "inputs": [],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "reserved",
    "inputs": [
      {
        "name": "asset",
        "type": "tuple",
        "internalType": "struct Asset",
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
      }
    ],
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
    "type": "function",
    "name": "selectClaim",
    "inputs": [
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
        "name": "lock",
        "type": "bytes32",
        "internalType": "bytes32"
      },
      {
        "name": "secret",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "selectReclaim",
    "inputs": [
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
        "name": "lock",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "setCommitmentFee",
    "inputs": [
      {
        "name": "newFee",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "settlementProgress",
    "inputs": [
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
        "name": "lock",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ],
    "outputs": [
      {
        "name": "expectedSides",
        "type": "uint8",
        "internalType": "uint8"
      },
      {
        "name": "completedSides",
        "type": "uint8",
        "internalType": "uint8"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "state",
    "inputs": [
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
        "name": "lock",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint8",
        "internalType": "enum SameChainState"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "supportsInterface",
    "inputs": [
      {
        "name": "interfaceId",
        "type": "bytes4",
        "internalType": "bytes4"
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
    "name": "transferOwnership",
    "inputs": [
      {
        "name": "newOwner",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "withdrawFees",
    "inputs": [
      {
        "name": "to",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "event",
    "name": "ClaimSelected",
    "inputs": [
      {
        "name": "tradeId",
        "type": "bytes32",
        "indexed": true,
        "internalType": "bytes32"
      },
      {
        "name": "lock",
        "type": "bytes32",
        "indexed": true,
        "internalType": "bytes32"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "Claimed",
    "inputs": [
      {
        "name": "tradeId",
        "type": "bytes32",
        "indexed": true,
        "internalType": "bytes32"
      },
      {
        "name": "lock",
        "type": "bytes32",
        "indexed": true,
        "internalType": "bytes32"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "Committed",
    "inputs": [
      {
        "name": "tradeId",
        "type": "bytes32",
        "indexed": true,
        "internalType": "bytes32"
      },
      {
        "name": "lock",
        "type": "bytes32",
        "indexed": true,
        "internalType": "bytes32"
      },
      {
        "name": "side",
        "type": "uint8",
        "indexed": true,
        "internalType": "enum SideTag"
      },
      {
        "name": "principal",
        "type": "address",
        "indexed": false,
        "internalType": "address"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "FeeUpdated",
    "inputs": [
      {
        "name": "oldFee",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "newFee",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "FeesWithdrawn",
    "inputs": [
      {
        "name": "to",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "amount",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "HTLCCreated",
    "inputs": [
      {
        "name": "tradeId",
        "type": "bytes32",
        "indexed": true,
        "internalType": "bytes32"
      },
      {
        "name": "lock",
        "type": "bytes32",
        "indexed": true,
        "internalType": "bytes32"
      },
      {
        "name": "side",
        "type": "uint8",
        "indexed": true,
        "internalType": "enum SideTag"
      },
      {
        "name": "htlc",
        "type": "address",
        "indexed": false,
        "internalType": "address"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "OwnershipTransferStarted",
    "inputs": [
      {
        "name": "previousOwner",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "newOwner",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "OwnershipTransferred",
    "inputs": [
      {
        "name": "previousOwner",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "newOwner",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "ReclaimSelected",
    "inputs": [
      {
        "name": "tradeId",
        "type": "bytes32",
        "indexed": true,
        "internalType": "bytes32"
      },
      {
        "name": "lock",
        "type": "bytes32",
        "indexed": true,
        "internalType": "bytes32"
      },
      {
        "name": "expectedSides",
        "type": "uint8",
        "indexed": false,
        "internalType": "uint8"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "Reclaimed",
    "inputs": [
      {
        "name": "tradeId",
        "type": "bytes32",
        "indexed": true,
        "internalType": "bytes32"
      },
      {
        "name": "lock",
        "type": "bytes32",
        "indexed": true,
        "internalType": "bytes32"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "SettlementBatchExecuted",
    "inputs": [
      {
        "name": "tradeId",
        "type": "bytes32",
        "indexed": true,
        "internalType": "bytes32"
      },
      {
        "name": "lock",
        "type": "bytes32",
        "indexed": true,
        "internalType": "bytes32"
      },
      {
        "name": "side",
        "type": "uint8",
        "indexed": true,
        "internalType": "enum SideTag"
      },
      {
        "name": "nextAssetIndex",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "complete",
        "type": "bool",
        "indexed": false,
        "internalType": "bool"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "SideReleased",
    "inputs": [
      {
        "name": "tradeId",
        "type": "bytes32",
        "indexed": true,
        "internalType": "bytes32"
      },
      {
        "name": "lock",
        "type": "bytes32",
        "indexed": true,
        "internalType": "bytes32"
      },
      {
        "name": "side",
        "type": "uint8",
        "indexed": true,
        "internalType": "enum SideTag"
      }
    ],
    "anonymous": false
  },
  {
    "type": "error",
    "name": "AtomicSettlementDisabled",
    "inputs": []
  },
  {
    "type": "error",
    "name": "AuthorizationExpired",
    "inputs": []
  },
  {
    "type": "error",
    "name": "ClaimWindowClosed",
    "inputs": []
  },
  {
    "type": "error",
    "name": "CommitWindowClosed",
    "inputs": []
  },
  {
    "type": "error",
    "name": "FeeExceedsMax",
    "inputs": []
  },
  {
    "type": "error",
    "name": "HTLCAlreadyExists",
    "inputs": []
  },
  {
    "type": "error",
    "name": "IncorrectNativeAmount",
    "inputs": []
  },
  {
    "type": "error",
    "name": "InvalidAuthenticatedSubmitter",
    "inputs": []
  },
  {
    "type": "error",
    "name": "InvalidAuthenticatedSubmitterKeyVersion",
    "inputs": []
  },
  {
    "type": "error",
    "name": "InvalidAuthorizationCaller",
    "inputs": []
  },
  {
    "type": "error",
    "name": "InvalidAuthorizationPayload",
    "inputs": []
  },
  {
    "type": "error",
    "name": "InvalidBatchSize",
    "inputs": []
  },
  {
    "type": "error",
    "name": "InvalidBobCommitSecret",
    "inputs": []
  },
  {
    "type": "error",
    "name": "InvalidExpectedSourceState",
    "inputs": []
  },
  {
    "type": "error",
    "name": "InvalidFundingDestination",
    "inputs": []
  },
  {
    "type": "error",
    "name": "InvalidHTLCBinding",
    "inputs": []
  },
  {
    "type": "error",
    "name": "InvalidHTLCImplementation",
    "inputs": []
  },
  {
    "type": "error",
    "name": "InvalidLocalChain",
    "inputs": []
  },
  {
    "type": "error",
    "name": "InvalidLocalChain",
    "inputs": []
  },
  {
    "type": "error",
    "name": "InvalidSameChainState",
    "inputs": [
      {
        "name": "expected",
        "type": "uint8",
        "internalType": "enum SameChainState"
      },
      {
        "name": "actual",
        "type": "uint8",
        "internalType": "enum SameChainState"
      }
    ]
  },
  {
    "type": "error",
    "name": "InvalidSettlementMode",
    "inputs": []
  },
  {
    "type": "error",
    "name": "InvalidSettlementSecret",
    "inputs": []
  },
  {
    "type": "error",
    "name": "InvalidTerms",
    "inputs": []
  },
  {
    "type": "error",
    "name": "InvalidWrapperMode",
    "inputs": []
  },
  {
    "type": "error",
    "name": "MissingBobCommitSecret",
    "inputs": []
  },
  {
    "type": "error",
    "name": "MissingHTLC",
    "inputs": []
  },
  {
    "type": "error",
    "name": "OwnableInvalidOwner",
    "inputs": [
      {
        "name": "owner",
        "type": "address",
        "internalType": "address"
      }
    ]
  },
  {
    "type": "error",
    "name": "OwnableUnauthorizedAccount",
    "inputs": [
      {
        "name": "account",
        "type": "address",
        "internalType": "address"
      }
    ]
  },
  {
    "type": "error",
    "name": "ReclaimWindowClosed",
    "inputs": []
  },
  {
    "type": "error",
    "name": "ReentrancyGuardReentrantCall",
    "inputs": []
  },
  {
    "type": "error",
    "name": "SettlementIncomplete",
    "inputs": [
      {
        "name": "expectedSides",
        "type": "uint8",
        "internalType": "uint8"
      },
      {
        "name": "completedSides",
        "type": "uint8",
        "internalType": "uint8"
      }
    ]
  },
  {
    "type": "error",
    "name": "SettlementNotPending",
    "inputs": [
      {
        "name": "actual",
        "type": "uint8",
        "internalType": "enum SameChainState"
      }
    ]
  },
  {
    "type": "error",
    "name": "SettlementSideAlreadyComplete",
    "inputs": [
      {
        "name": "side",
        "type": "uint8",
        "internalType": "enum SideTag"
      }
    ]
  },
  {
    "type": "error",
    "name": "UnexpectedAmountReceived",
    "inputs": []
  },
  {
    "type": "error",
    "name": "UnexpectedBobCommitSecret",
    "inputs": []
  },
  {
    "type": "error",
    "name": "UnexpectedERC721Owner",
    "inputs": [
      {
        "name": "expected",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "actual",
        "type": "address",
        "internalType": "address"
      }
    ]
  },
  {
    "type": "error",
    "name": "UnexpectedSettlementSide",
    "inputs": [
      {
        "name": "side",
        "type": "uint8",
        "internalType": "enum SideTag"
      }
    ]
  },
  {
    "type": "error",
    "name": "UnsupportedAsset",
    "inputs": [
      {
        "name": "assetType",
        "type": "uint8",
        "internalType": "enum AssetType"
      },
      {
        "name": "target",
        "type": "address",
        "internalType": "address"
      }
    ]
  },
  {
    "type": "error",
    "name": "ZeroConfiguration",
    "inputs": []
  },
  {
    "type": "error",
    "name": "ZeroFeeRecipient",
    "inputs": []
  }
] as const
