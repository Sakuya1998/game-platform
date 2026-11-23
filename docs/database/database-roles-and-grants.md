# Database roles and grants

- **Status:** Draft for review (2026-11-23). The grant matrix in section 3 is a **proposal**: the design fixes the principles (separate roles, least privilege, no superuser) but not the per-table privileges.
- **Elaborates:** [ADR-0002](../adr/ADR-0002-game-isolation.md), [ADR-0006](../adr/ADR-0006-postgresql-schema-design.md)
- **Source:** section 5.4 of the [technical design](../game-platform-technical-design.md)

Nothing in this document has been applied to a database. T03 delivers the migration that creates the roles and grants, and the tests that connect as each role.

## 1. Why this matters

Application-level RBAC decides what an administrator may do. If `gm-api` connects with an account that can write every table, a bug or a compromise in `gm-api` bypasses all of it. Database privileges are the layer that still holds when application code is wrong.

## 2. Roles

| Role | Login | Used by | Purpose |
|---|---|---|---|
| `game_platform_owner` | No | Nobody at runtime | Owns schemas, tables, functions |
| `game_migrator` | Yes | The migration job only | Member of the owner role; runs DDL |
| `game_api_runtime` | Yes | `game-api` | Player-plane data access |
| `gm_api_runtime` | Yes | `gm-api` | GM-plane data access |
| `game_worker_runtime` | Yes | `game-worker` | Jobs, batch execution, aggregation |
| `internal_api_runtime` | Yes | `internal-api` | Reserved; not created until the service is deployed |

Rules for every runtime role: not a superuser, not an owner, no `CREATEDB`, no `CREATEROLE`, no `BYPASSRLS`, no DDL, a connection limit, and credentials that only its own process receives.

## 3. Grant matrix (proposal)

Legend: **R** = `SELECT`; **I** = `INSERT`; **U** = `UPDATE`; **D** = `DELETE`; **—** = no privilege, including no `USAGE` on the schema when the whole schema is "—".

| Schema.table | `game_api_runtime` | `gm_api_runtime` | `game_worker_runtime` |
|---|---|---|---|
| **platform**.games, game_platform_apps, game_settings, game_environments | R | R I U | R |
| **auth**.player_identities | R I U | R | R |
| auth.player_sessions | R I U | R U (revoke on ban) | R D (expired) |
| auth.login_records | I | R | R D (retention) |
| **player**.players | R I U | R U (status) | R |
| player.player_profiles | R I U | R | R |
| player.player_saves | R I U | R U (restore) | R |
| player.player_save_snapshots | — | R I | R I D (retention) |
| player.player_bans | R | R I U | R |
| **game**.game_configs, config_versions | R | R I U | R |
| game.config_releases, config_release_items | R | R I | R |
| **gameplay**.game_runs | R I U | R | R U (expire) |
| gameplay.run_settlements | R I | R | R |
| gameplay.run_events | R I | R | R I |
| **economy**.currency_definitions, item_definitions | R | R I U | R |
| economy.wallets, player_items | R I U | R I U | R I U |
| economy.wallet_transactions, item_transactions | R I | R I | R I |
| **ads**.ad_placements | R | R I U | R |
| ads.ad_sessions | R I U | R | R U (expire) |
| ads.ad_reward_claims | R I | R | R |
| ads.ad_daily_limits | R I U | R | R D (retention) |
| **operation**.announcements | R | R I U | R |
| operation.mail_messages | R | R I U | R U (status) |
| operation.mail_attachments | R | R I | R |
| operation.player_mail | R U (read, claim, delete flag) | R | R I D (expired) |
| operation.activities | R | R I U | R U (end) |
| operation.activity_claims | R I | R | R |
| operation.reward_jobs | — | R I U | R U |
| **ranking**.leaderboards | R | R I U | R |
| ranking.leaderboard_entries | R I U | R | R I U D |
| ranking.leaderboard_snapshots | R | R | R I |
| **admin**.* | — | R I U | — |
| **audit**.admin_audit_logs | — | R I | — |
| audit.service_audit_logs | — | R | — |
| **analytics**.game_events | I | R | R D (retention) |
| analytics.daily_player_stats, daily_game_stats | — | R | R I U |
| **system**.idempotency_keys | R I U | R I U | R D (expired) |
| system.outbox_events | I | I | R U D |
| system.background_jobs | I | R I U (cancel, retry) | R U D |
| system.service_identities, service_credentials, service_game_grants | — | — | — |

Points that are deliberate:

- `game_api_runtime` has no access to the `admin` and `audit` schemas at all.
- Nobody has `UPDATE` or `DELETE` on the ledgers or the audit logs. Nobody has `TRUNCATE` on anything.
- `gm_api_runtime` cannot write runs, settlements, ad claims or activity claims: a GM changes assets through adjustments, which are ledger rows.
- `game_worker_runtime` cannot read administrator credentials or write GM audit rows.
- The service identity tables are managed by migrations and operations until `internal-api` exists.

The matrix was derived from the API contracts and job catalogue, not from running code. Statement forms such as `RETURNING` and `ON CONFLICT` can require `SELECT` in addition to `INSERT`; where a repository statement needs a privilege the matrix lacks, T03 changes the matrix in this document and the migration together.

## 4. The wallet write path

`UPDATE` on `economy.wallets` is the one privilege in the matrix that is broader than the rule it serves: any of the three roles could change a balance without writing a ledger row. Two ways to close it, in order of effort:

| Option | How | Cost |
|---|---|---|
| A. Repository discipline plus reconciliation | Only the economy repository issues the statement; the reconciliation job in [economy-design.md](../architecture/economy-design.md) detects any balance that does not match its ledger | No extra database objects; detection, not prevention |
| B. `SECURITY DEFINER` function | Revoke `UPDATE` on `wallets` and `player_items` from all runtime roles; grant `EXECUTE` on a function owned by the owner role that locks, validates, inserts the ledger row and updates the balance | Prevention in the database; business logic partly in PL/pgSQL; the function needs a pinned `search_path` and its own tests |

ADR-0006 says this is evaluated before broad write privileges are given. Option A is enough to start development; the choice between A and B is made before production and recorded in ADR-0007.

## 5. Sketch of the migration

```sql
-- Roles (passwords come from the secret store, never from a migration file)
CREATE ROLE game_platform_owner NOLOGIN;
CREATE ROLE game_migrator       LOGIN IN ROLE game_platform_owner;
CREATE ROLE game_api_runtime    LOGIN CONNECTION LIMIT 100;
CREATE ROLE gm_api_runtime      LOGIN CONNECTION LIMIT 20;
CREATE ROLE game_worker_runtime LOGIN CONNECTION LIMIT 20;

-- Nothing is reachable by default
REVOKE ALL ON DATABASE game_platform FROM PUBLIC;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT CONNECT ON DATABASE game_platform
    TO game_migrator, game_api_runtime, gm_api_runtime, game_worker_runtime;

-- Per schema: USAGE only where the role has at least one table privilege
GRANT USAGE ON SCHEMA economy TO game_api_runtime, gm_api_runtime, game_worker_runtime;

-- Per table: exactly the matrix
GRANT SELECT, INSERT, UPDATE ON economy.wallets, economy.player_items
    TO game_api_runtime, gm_api_runtime, game_worker_runtime;
GRANT SELECT, INSERT ON economy.wallet_transactions, economy.item_transactions
    TO game_api_runtime, gm_api_runtime, game_worker_runtime;

-- admin schema: gm-api only
GRANT USAGE ON SCHEMA admin TO gm_api_runtime;
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA admin TO gm_api_runtime;
```

The connection limits are placeholders to be sized against the pool configuration. `ALTER DEFAULT PRIVILEGES` is not used to grant anything to runtime roles: a new table gets no runtime access until a migration grants it on purpose.

## 6. Connection pooling

- Each process has its own pool and its own role. Pools are not shared between entries.
- If RLS is enabled, the game scope is set with `SET LOCAL` inside the transaction so it cannot leak through a pooled connection ([game-isolation.md](../architecture/game-isolation.md)).
- With a transaction-mode pooler (for example PgBouncer), session-level settings and advisory locks are not available; the design does not depend on either.

## 7. Verification

These tests connect with the real login roles, never as the owner.

| As | Statement | Expected |
|---|---|---|
| `game_api_runtime` | `SELECT * FROM admin.admin_users` | Permission denied |
| `game_api_runtime` | `SELECT * FROM audit.admin_audit_logs` | Permission denied |
| any runtime role | `UPDATE economy.wallet_transactions SET amount = 1` | Permission denied |
| any runtime role | `DELETE FROM audit.admin_audit_logs` | Permission denied |
| owner (to test the trigger) | `UPDATE economy.wallet_transactions ...` | Exception from `system.reject_mutation()` |
| `gm_api_runtime` | `INSERT INTO gameplay.run_settlements ...` | Permission denied |
| `game_worker_runtime` | `SELECT * FROM admin.admin_mfa` | Permission denied |
| any runtime role | `CREATE TABLE economy.x ()` | Permission denied |
| any runtime role | `TRUNCATE economy.wallets` | Permission denied |

A second check lists every privilege held by each runtime role from `information_schema.role_table_grants` and compares it with the matrix, so drift is caught in CI.

## 8. Operations

- Runtime credentials are rotated on a schedule; rotation is rehearsed.
- Human access to production goes through a separate, audited, read-only role by default. Nobody uses a runtime role or the migrator by hand.
- The migrator's credentials exist only in the deployment pipeline.
