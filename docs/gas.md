# Gas checkpoint

The canonical regression record is [`.gas-snapshot`](../.gas-snapshot). This
checkpoint was regenerated for the final-claim-window admission change on top
of source revision `dff98fc48c73378e318349aa779aa1a4b2ed30c9`, using Forge 1.7.1
and the repository's default Foundry profile (Solidity 0.8.33, Prague, 10,000 optimizer runs, with the
configured dependency-specific via-IR compilation restriction). All 675 tests
passed. The snapshot SHA-256 is
`bcb6677000cb9e9e1719685e7f167f0b1ac9ecae41b9bb293e338fff4164c577`.

The focused gas report used
`forge test --gas-report --match-contract DeployedWrapperGuardsTest`:

| Current same-chain call | Average | Median | Observations |
| --- | ---: | ---: | ---: |
| `selectClaim` | 43,475 | 44,284 | 17 |
| `selectReclaim` | 49,028 | 51,557 | 12 |
| `executeSettlement` | 134,964 | 173,943 | 37 |
| HTLC `releaseBatch` | 85,610 | 96,276 | 26 |

These are prototype test-distribution measurements, not upper bounds. Reverted
and adversarial calls are included, assets have different costs, and PQ
signature verification is outside settlement. The legacy same-chain path used
one atomic payout transaction; the current path adds a bounded selection
transaction and one or more retryable execution transactions. Its benefit is
liveness and bounded per-call work, not lower total gas.

Refresh from the repository root whenever contracts, tests, or compiler settings
change:

```sh
make snapshot
forge snapshot --check
forge test --gas-report --match-contract DeployedWrapperGuardsTest
sha256sum .gas-snapshot
```

Update this page's source revision, toolchain, test count, checksum, and focused
measurements together with the snapshot.
