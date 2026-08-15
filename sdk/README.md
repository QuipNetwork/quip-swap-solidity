# Quip Swap SDK

The package root is the current protocol integration surface. It exports:

- protocol terms, state enums, hashing, and validation;
- generated ABIs for every current contract;
- createProtocolClient for commits, claims, reclaims, registration, asset
  support, and timing-policy operations;
- address-scoped protocol event and receipt decoding; and
- TrustedCrossChainWorkflow for trusted-client coordination.

    import {
      createProtocolClient,
      decodeProtocolEvents,
      crossChainWrapperAbi,
    } from '@quip.network/quip-swap-sdk'

Applications supply existing Viem public and wallet clients plus explicit,
verified contract addresses. The SDK does not guess deployments or hold keys.

The previous Omnibus API is retained only through the explicit compatibility
entry point:

    import {createOmnibusClient} from '@quip.network/quip-swap-sdk/legacy'

New integrations must not import the legacy entry point.
