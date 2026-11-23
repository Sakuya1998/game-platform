# Economy design

- **Status:** Draft for review (2026-11-23)
- **Elaborates:** [ADR-0007](../adr/ADR-0007-economy-transaction-model.md)
- **Source:** sections 4.6, 5.2 F and 6.2 of the [technical design](../game-platform-technical-design.md); tables in [schema.sql](../database/schema.sql)

Where this document and the ADR disagree, the ADR wins. Items marked **(proposal)** are not stated in the design document or an ADR and need confirmation.

## 1. Model

```text
economy.currency_definitions ── economy.wallets ── economy.wallet_transactions (append-only)
economy.item_definitions     ── economy.player_items ── economy.item_transactions (append-only)
```

- A wallet row holds the current balance of one currency for one player. It is a projection of the ledger.
- A ledger row is an immutable fact: who changed what, by how much, why, and from which business source.
- Amounts are `bigint` in minor units. There is no floating point anywhere.
- Balances and quantities cannot go below zero (`CHECK (balance >= 0)`, `CHECK (quantity >= 0)`).

## 2. The service

All asset changes go through one application service in `gamecore`, whichever entry calls it.

```go
type EconomyService interface {
    Grant(ctx context.Context, actor Actor, req GrantRequest) error
    Spend(ctx context.Context, actor Actor, req SpendRequest) error
    GetWallet(ctx context.Context, actor Actor, playerID string) (*Wallet, error)
}
```

A request names the player, the asset, a positive amount, and the business source: `transaction_type`, `source_type`, `source_id`. Callers that already hold a transaction (settlement, mail claim) pass it in, so the grant commits with their own rows.

## 3. One change, step by step

```sql
BEGIN;

-- 1. Make sure the wallet row exists (first grant of a currency).
INSERT INTO economy.wallets (game_id, player_id, currency_code)
VALUES ($1, $2, $3)
ON CONFLICT DO NOTHING;

-- 2. Lock it.
SELECT balance FROM economy.wallets
WHERE game_id = $1 AND player_id = $2 AND currency_code = $3
FOR UPDATE;

-- 3. Validate in the application: currency active, amount > 0,
--    debit does not exceed balance, credit does not exceed max_balance.

-- 4. Write the ledger row. The unique key is the idempotency guarantee.
INSERT INTO economy.wallet_transactions
    (game_id, player_id, currency_code, direction, amount, balance_after,
     transaction_type, source_type, source_id, idempotency_key,
     actor_type, actor_id, reason)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13);

-- 5. Update the projection.
UPDATE economy.wallets
SET balance = $6, version = version + 1, updated_at = now()
WHERE game_id = $1 AND player_id = $2 AND currency_code = $3;

COMMIT;
```

If step 4 violates the unique key, the change was already applied: the service rolls back and returns the earlier result. It does not treat this as an error to show the player.

## 4. Idempotency

Two mechanisms, with different jobs:

| Mechanism | Scope | Protects against |
|---|---|---|
| `Idempotency-Key` header and `system.idempotency_keys` | One HTTP request | A client or proxy retrying the same request; returns the stored response |
| Ledger unique key `(game_id, player_id, currency_code, source_type, source_id, transaction_type)` | One business event | The same event being paid twice through any path, including a different request, a job retry or a bug |

The second one is the final guarantee. A Redis lock is never part of it.

### 4.1 Source catalogue (proposal)

Each row is one way an asset can change. `source_id` must be stable for the business event, so a retry produces the same key.

| `transaction_type` | `source_type` | `source_id` | Direction |
|---|---|---|---|
| `run_cost` | `game_run` | Run ID | Debit |
| `run_reward` | `game_run` | Run ID | Credit |
| `ad_reward` | `ad_session` | Ad session ID | Credit |
| `mail_claim` | `player_mail` | Player mail ID | Credit |
| `activity_reward` | `activity_claim` | `<activity_id>:<reward_id>` | Credit |
| `batch_reward` | `reward_job` | Reward job ID | Credit |
| `gm_adjustment` | `admin_adjustment` | The request's `Idempotency-Key` | Either |
| `correction` | `wallet_transaction` | ID of the ledger row being compensated | Either |

New types are added to this table before they are used in code.

## 5. Several assets in one event

A settlement or a mail can grant several currencies and items. They are applied in one transaction, one ledger row per asset.

**(proposal)** To avoid deadlocks between concurrent transactions for the same player, always lock in a fixed order: wallets by `currency_code` ascending, then items by `item_id` ascending.

## 6. Limits

| Limit | Where | Behaviour when reached |
|---|---|---|
| Insufficient balance | Step 3, plus the `CHECK` | `409 INSUFFICIENT_BALANCE`; nothing is written |
| `currency_definitions.max_balance` | Step 3 | **(proposal)** Reject the grant, so no silent truncation; a game that prefers clamping must say so in its currency setting |
| `item_definitions.max_quantity` | Same | Same |
| Disabled currency or item | Step 3 | Reject |
| Per-source caps (run, ad, activity) | The calling service, before `Grant` | The caller decides the amount; the economy service enforces only global limits |

## 7. Items

Items follow the same pattern with `player_items` and `item_transactions`. `item_id` is the designer-facing code, unique per game. Non-stackable items are modelled as quantity 0 or 1 with `stackable = false`; V1 has no per-instance item attributes.

## 8. GM adjustments

- Endpoint: `POST /gm/v1/games/{game_id}/players/{player_id}/wallet-adjustments`.
- Body: `currency`, signed `amount`, `reason` (mandatory), `ticket_id` (optional).
- A positive amount needs `economy.grant`; a negative amount needs `economy.deduct`.
- The ledger row and an `audit.admin_audit_logs` row with before and after balance are written in the same transaction.
- A GM never sends a target balance. There is no API that sets one.
- Corrections are new compensating rows; ledger rows are never edited or deleted (enforced by trigger and by privileges).

The GM API in the design covers wallet adjustments only. Item adjustments by a GM have no endpoint yet; add one with the same shape when needed.

## 9. Batch grants

Mass rewards are executed by `game-worker`, one `Grant` per player with `source_type = 'reward_job'` and `source_id` = the reward job ID. A retried job re-attempts players already paid; the unique key turns those attempts into no-ops. See [async-job-design.md](async-job-design.md).

## 10. Reconciliation (proposal)

A scheduled worker job compares, per wallet, the balance with the signed sum of its ledger rows, and the `balance_after` of the latest row with the balance. Any difference raises an alert and is investigated; the job never "fixes" a balance on its own. The same check runs for items.

## 11. Metrics

Grant success and failure counts by `transaction_type`, duplicate attempts caught by the unique key, insufficient-balance rejections, GM adjustment count and volume, wallet lock wait time, reconciliation differences.

## 12. Out of scope

Payments, paid currency, refunds and chargebacks. They need their own ADR before any payment integration, including the delivery callback described in [service-boundaries.md](service-boundaries.md#5-third-party-callbacks).
