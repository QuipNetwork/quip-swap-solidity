# Asset compatibility

Non-native assets require their exact `(assetType, target)` pair in
`AssetSupportRegistry`. Approval is an assertion of behavior, not merely
interface conformance.

Supported assets must:

- return ABI-valid, stable balance or ownership data;
- move the exact signed amount without fees, reflection, or rebasing;
- report the actual ERC-721 owner before and after transfer;
- support the required safe-transfer receiver behavior; and
- preserve those properties for the maximum escrow lifetime.

Unsupported examples include fee-on-transfer, rebasing, elastic-supply,
reflection, balance-mutating hooks, dishonest balance/ownership reporting, and
unreviewed proxy upgrades. A target must not be approved under an incompatible
asset type.

The wrappers and dedicated HTLCs check exact native value, fungible balance
deltas, and ERC-721 ownership. A failure rolls back protocol state, HTLC
creation/funding or release, prior atomic payouts, and authorization nonce
consumption. Reentrancy guards cover commit, claim, and reclaim entry points.

## Governance and operations

- Review implementation code and proxy controls before allowlisting.
- Reassess and, when necessary, delist after any implementation change.
- Recheck support immediately before every commit.
- Warn users when support changes after terms are accepted. Delisting the
  second side can force an already-funded first leg to wait for reclaim.
- Define owner transfer, emergency, monitoring, and ownership-renunciation
  policy before deployment.
- Establish a conservative maximum asset count even though the contracts do
  not currently enforce one.

Delisting blocks new commits but does not block claim or reclaim of assets
already held by a dedicated HTLC. It does not guarantee that a changed token
will remain transferable.

## Destinations

Contract recipients must support the applicable native/token receiver behavior.
Do not sign a local wrapper as `recipient` or `reclaimRecipient`; the prototype
does not yet reject this shape and settlement may fail or strand an ERC-721.
