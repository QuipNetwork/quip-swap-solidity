# Quip Swap

This branch contains the current multi-contract protocol prototype:

- asset-support registry;
- direct-user and broker PQ identity registration;
- the direct authorization gateway and QuipWallet authorization boundary;
- separate cross-chain and same-chain wrappers; and
- the trusted-client workflow in the TypeScript SDK.

The previous Omnibus implementation remains only for comparison and regression
testing. It is not the current integration or deployment surface.

## Build and test

    forge build
    forge test
    forge fmt --check
    make sdk-generate
    make sdk-typecheck
    make sdk-test
    make sdk-build

## SDK surfaces

The package root exports the current protocol types, hashing, ABIs, transaction
helpers, event helpers, and trusted workflow. For example:

    import {createProtocolClient, crossChainWrapperAbi} from '@quip.network/quip-swap-sdk'

The old Omnibus SDK is explicitly isolated:

    import {createOmnibusClient} from '@quip.network/quip-swap-sdk/legacy'

Current protocol deployment scripts are deferred to the deployment-prototype
step. Existing Omnibus scripts are legacy utilities and must not deploy the
current protocol.

## Asset support

Native assets need no configuration. Token contracts must be enabled in the
shared AssetSupportRegistry for their exact asset type before a new commit.
Approval asserts standard exact balance or ownership behavior. Delisting blocks
future commits only and does not affect claims or reclaims of existing escrow.
