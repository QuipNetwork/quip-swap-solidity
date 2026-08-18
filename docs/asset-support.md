# Asset compatibility

The prototype admits non-native assets only when their exact `(assetType, target)`
pair is enabled in `AssetSupportRegistry`. Enabling a contract is an assertion
that its behavior is compatible with the custody accounting below; interface
conformance alone is not sufficient.

Supported tokens must:

- return ABI-valid, stable `balanceOf` results during collection and release;
- move the exact signed ERC-20 or ERC-1155 amount without fees, reflection, or
  other balance changes;
- report the actual ERC-721 owner before and after transfer; and
- preserve these properties for as long as an escrow may remain open.

Rebasing, elastic-supply, reflection, fee-on-transfer, balance-mutating hook,
and otherwise nonstandard assets are unsupported. Upgradeable token contracts
must be reassessed after an implementation change. The wrappers reject observed
balance or ownership mismatches and atomically roll back the protocol state,
reserve accounting, asset transfers, and commit-authorization nonce consumption.
Delisting blocks new commits but intentionally does not block settlement of
assets already held in escrow.

ERC-721 and ERC-1155 safe-transfer callbacks are supported. Wrapper entry points
are reentrancy guarded, so a token contract or recipient callback cannot perform
a nested commit, claim, or reclaim.
