# Commitment fees

The v1.1 wrappers preserve the v1 commitment-fee policy. Each wrapper has an
independent owner-configured native `commitmentFee`, capped at `0.01 ether` and
defaulting to zero. The charge applies once to every accepted local commit.

## Payment and custody

Immediately before submission, the SDK reads the target wrapper and reports:

- `nativeEscrow`: the selected side's native assets from signed terms;
- `commitmentFee`: the wrapper's current fee; and
- `totalValue`: their exact sum.

The caller sends exactly `totalValue`. The wrapper forwards only
`nativeEscrow` to the side HTLC and records the fee in `accruedFees`. Token
assets continue to come from the signed principal. Transaction gas is a
separate network cost and is never part of these values or protocol revenue.

## Live-fee consequences

The fee is deliberately not in `ProtocolTerms`, `CommitPayloadHash`, or the PQ
authorization, and there is no trade-level snapshot. The owner may change it
immediately, including between the two commits of one trade. A stale value
causes an exact-value revert; clients must refresh the quote and ask the
operator to retry rather than silently changing a confirmed transaction.

A completed same-chain trade has two accepted local commits and therefore pays
two fees to the same wrapper. A cross-chain trade pays each chain's independently
configured wrapper fee. This policy does not promise price stability.

## Accrual, refunds, and withdrawal

Rejected commits accrue nothing. Once a commit is accepted, its fee is
nonrefundable: it remains accrued after claim, reclaim, absent counterparty
participation, or incomplete settlement execution. Reclaim returns signed
escrow, not the fee.

Only the wrapper owner can withdraw, and `withdrawFees(to)` transfers exactly
the recorded `accruedFees`. It cannot sweep HTLC escrow or forced/unaccounted
native value. A failed transfer restores the accrued balance atomically.
