/** AUTO-GENERATED from out/SwapHTLC.sol/SwapHTLC.json. */
export const swapHTLCAbi = [
  {
    "type": "constructor",
    "inputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "confirmFunding",
    "inputs": [
      {
        "name": "sideTerms_",
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
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "controller",
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
    "name": "funded",
    "inputs": [],
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
    "name": "initialize",
    "inputs": [
      {
        "name": "tradeId_",
        "type": "bytes32",
        "internalType": "bytes32"
      },
      {
        "name": "lock_",
        "type": "bytes32",
        "internalType": "bytes32"
      },
      {
        "name": "side_",
        "type": "uint8",
        "internalType": "enum SideTag"
      },
      {
        "name": "sideTerms_",
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
    ],
    "outputs": [],
    "stateMutability": "payable"
  },
  {
    "type": "function",
    "name": "lock",
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
    "name": "nextAssetIndex",
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
    "name": "payoutRecipient",
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
    "name": "release",
    "inputs": [
      {
        "name": "sideTerms_",
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
        "name": "recipient",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "releaseBatch",
    "inputs": [
      {
        "name": "sideTerms_",
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
        "name": "recipient",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "maxAssets",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "nextIndex",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "complete",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "released",
    "inputs": [],
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
    "name": "side",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint8",
        "internalType": "enum SideTag"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "sideTermsHash",
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
    "name": "tradeId",
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
    "type": "event",
    "name": "Funded",
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
    "type": "event",
    "name": "Initialized",
    "inputs": [
      {
        "name": "controller",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
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
        "indexed": false,
        "internalType": "enum SideTag"
      },
      {
        "name": "sideTermsHash",
        "type": "bytes32",
        "indexed": false,
        "internalType": "bytes32"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "Released",
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
        "name": "recipient",
        "type": "address",
        "indexed": false,
        "internalType": "address"
      }
    ],
    "anonymous": false
  },
  {
    "type": "error",
    "name": "AlreadyInitialized",
    "inputs": []
  },
  {
    "type": "error",
    "name": "AlreadyReleased",
    "inputs": []
  },
  {
    "type": "error",
    "name": "IncorrectNativeAmount",
    "inputs": []
  },
  {
    "type": "error",
    "name": "InsufficientAssetBalance",
    "inputs": []
  },
  {
    "type": "error",
    "name": "InvalidBatchSize",
    "inputs": []
  },
  {
    "type": "error",
    "name": "InvalidFundingState",
    "inputs": []
  },
  {
    "type": "error",
    "name": "InvalidRecipient",
    "inputs": []
  },
  {
    "type": "error",
    "name": "NotInitialized",
    "inputs": []
  },
  {
    "type": "error",
    "name": "PayoutRecipientMismatch",
    "inputs": []
  },
  {
    "type": "error",
    "name": "ReentrancyGuardReentrantCall",
    "inputs": []
  },
  {
    "type": "error",
    "name": "SideTermsMismatch",
    "inputs": []
  },
  {
    "type": "error",
    "name": "UnauthorizedController",
    "inputs": []
  },
  {
    "type": "error",
    "name": "UnexpectedAmountReceived",
    "inputs": []
  },
  {
    "type": "error",
    "name": "UnexpectedAmountReceived",
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
  }
] as const
