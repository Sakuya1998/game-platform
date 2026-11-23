# ADR-0007 — Economy transaction model

- **Status:** Accepted
- **Date:** 2026-11-23
- **Supersedes:** the economy invariants of ADR-004 in `docs/architecture/decisions.md` v1.0
- **Related:** [ADR-0004](ADR-0004-data-authority-model.md), [ADR-0006](ADR-0006-postgresql-schema-design.md)

## Context

Gold, diamonds, energy, other per-game currencies and item stock are the assets most worth attacking and the most damaging to get wrong. Rewards arrive from many sources — run settlement, ads, mail, activities, GM adjustments, batch jobs — and every one of them can be retried or replayed.

## Decision

**Balance plus immutable ledger.**

```text
wallets       └── wallet_transactions
player_items  └── item_transactions
```

- Every change to a balance or a quantity writes a ledger row in the same database transaction. No code path updates a balance without a ledger row.
- The transaction locks the wallet row (`SELECT … FOR UPDATE`) or uses an equivalent conditional update, checks idempotency, validates rules and limits, updates the balance, and inserts the ledger row.
- Amounts are integers in minor units. No floating point.
- A debit cannot produce a negative balance. V1 enforces this for every currency with `CHECK (balance >= 0)`; a currency that must go negative requires an amendment to this ADR.

**Idempotency.**

- Every grant and spend is idempotent. The same business source cannot grant twice.
- The final guarantee is a PostgreSQL unique key on the ledger, not a Redis lock: one `(source_type, source_id, transaction_type)` can change a given player's balance of a given currency once.
- Request-level replay is handled by `Idempotency-Key` and `system.idempotency_keys`.

**Single write path.** All asset changes go through the economy application service in `gamecore`, whichever entry they come from. Each call carries the `Actor`, and the ledger records actor type and ID.

**GM adjustments.**

- A GM never sets a balance. The API accepts a signed adjustment with a currency, an amount, a mandatory reason and a ticket reference, under an `Idempotency-Key`:
  `POST /gm/v1/games/{game_id}/players/{player_id}/wallet-adjustments`.
- Each adjustment writes a ledger row and a separate `audit.admin_audit_logs` row in the same transaction.
- Credits and debits are separate permissions (`economy.grant`, `economy.deduct`). Dual approval above a threshold is reserved.

**Batch grants.** Mass rewards and mail attachments are executed by `game-worker` through the same service, one idempotent grant per player, never inside a GM HTTP request (ADR-0009).

## Consequences

- Hot wallets serialize on a row lock; this is acceptable at mini-game write rates and is measured in load tests.
- The ledger grows without bound and needs a partitioning and retention plan once volume is known.
- Refunds and corrections are new compensating ledger rows, never edits.
- Payments are out of scope for V1. Paid currency, refunds and chargebacks need their own ADR before any payment integration.
