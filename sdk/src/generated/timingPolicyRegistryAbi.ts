/** AUTO-GENERATED from out/TimingPolicyRegistry.sol/TimingPolicyRegistry.json. */
export const timingPolicyRegistryAbi = [
  {
    "type": "constructor",
    "inputs": [
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
    "name": "acceptOwnership",
    "inputs": [],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "finalClaimDelay",
    "inputs": [
      {
        "name": "policyId",
        "type": "bytes32",
        "internalType": "bytes32"
      },
      {
        "name": "fromChainId",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "toChainId",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "delay",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "isRegistered",
    "inputs": [
      {
        "name": "policyId",
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
    "name": "registerPolicy",
    "inputs": [
      {
        "name": "expectedPolicyId",
        "type": "bytes32",
        "internalType": "bytes32"
      },
      {
        "name": "policy",
        "type": "tuple",
        "internalType": "struct TimingPolicy",
        "components": [
          {
            "name": "policyVersion",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "mode",
            "type": "uint8",
            "internalType": "enum WrapperMode"
          },
          {
            "name": "partyChainId",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "counterpartyChainId",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "partyToCounterpartyDelay",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "counterpartyToPartyDelay",
            "type": "uint256",
            "internalType": "uint256"
          }
        ]
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
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
    "name": "resolvePolicy",
    "inputs": [
      {
        "name": "policyId",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ],
    "outputs": [
      {
        "name": "policy",
        "type": "tuple",
        "internalType": "struct TimingPolicy",
        "components": [
          {
            "name": "policyVersion",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "mode",
            "type": "uint8",
            "internalType": "enum WrapperMode"
          },
          {
            "name": "partyChainId",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "counterpartyChainId",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "partyToCounterpartyDelay",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "counterpartyToPartyDelay",
            "type": "uint256",
            "internalType": "uint256"
          }
        ]
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "resolvePolicyForRoute",
    "inputs": [
      {
        "name": "policyId",
        "type": "bytes32",
        "internalType": "bytes32"
      },
      {
        "name": "expectedMode",
        "type": "uint8",
        "internalType": "enum WrapperMode"
      },
      {
        "name": "partyChainId",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "counterpartyChainId",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "policy",
        "type": "tuple",
        "internalType": "struct TimingPolicy",
        "components": [
          {
            "name": "policyVersion",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "mode",
            "type": "uint8",
            "internalType": "enum WrapperMode"
          },
          {
            "name": "partyChainId",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "counterpartyChainId",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "partyToCounterpartyDelay",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "counterpartyToPartyDelay",
            "type": "uint256",
            "internalType": "uint256"
          }
        ]
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
    "name": "TimingPolicyRegistered",
    "inputs": [
      {
        "name": "policyId",
        "type": "bytes32",
        "indexed": true,
        "internalType": "bytes32"
      },
      {
        "name": "policyVersion",
        "type": "uint256",
        "indexed": true,
        "internalType": "uint256"
      },
      {
        "name": "mode",
        "type": "uint8",
        "indexed": false,
        "internalType": "enum WrapperMode"
      },
      {
        "name": "partyChainId",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "counterpartyChainId",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "partyToCounterpartyDelay",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "counterpartyToPartyDelay",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "error",
    "name": "InvalidTimingPolicy",
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
    "name": "TimingPolicyAlreadyRegistered",
    "inputs": [
      {
        "name": "policyId",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ]
  },
  {
    "type": "error",
    "name": "TimingPolicyIdMismatch",
    "inputs": [
      {
        "name": "expected",
        "type": "bytes32",
        "internalType": "bytes32"
      },
      {
        "name": "actual",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ]
  },
  {
    "type": "error",
    "name": "TimingPolicyNotRegistered",
    "inputs": [
      {
        "name": "policyId",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ]
  },
  {
    "type": "error",
    "name": "TimingPolicyRouteMismatch",
    "inputs": [
      {
        "name": "policyId",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ]
  }
] as const
