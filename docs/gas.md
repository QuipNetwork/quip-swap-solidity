# Gas checkpoint

The canonical regression record is [`.gas-snapshot`](../.gas-snapshot). It was
regenerated after the resumable same-chain migration with Foundry's default
snapshot settings. Its SHA-256 is
`9204d5fe64d9c1475857d79b4bfb13ea3bd10978e3d6f540c4819e84960664ab`.

A focused `forge test --gas-report` over `DeployedWrapperGuardsTest` reported:

| Current same-chain call | Average | Median | Observations |
| --- | ---: | ---: | ---: |
| `selectClaim` | 43,311 | 44,261 | 16 |
| `selectReclaim` | 49,070 | 51,600 | 12 |
| `executeSettlement` | 134,513 | 177,481 | 35 |
| HTLC `releaseBatch` | 87,633 | 96,276 | 24 |

These are prototype test-distribution measurements, not upper bounds. Reverted
and adversarial calls are included, assets have different costs, and PQ
signature verification is outside settlement. The legacy same-chain path used
one atomic payout transaction; the current path adds a bounded selection
transaction and one or more retryable execution transactions. Its benefit is
liveness and bounded per-call work, not lower total gas.

Refresh with `make snapshot` and the focused command documented above whenever
settlement code or compiler settings change.
