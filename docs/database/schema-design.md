# Schema design

- **Status:** Draft for review (2026-11-23)
- **Elaborates:** [ADR-0006](../adr/ADR-0006-postgresql-schema-design.md)
- **Source:** section 5 of the [technical design](../game-platform-technical-design.md); executable baseline in [schema.sql](schema.sql)

`schema.sql` is the source of truth for names and types. This document explains why the tables look the way they do. Items marked **(proposal)** are not stated in the design document or an ADR and need confirmation.

## 1. Layout

One database, `game_platform`, with 13 schemas and 57 tables. There is no database per game; games are separated by `game_id` ([game-isolation.md](../architecture/game-isolation.md)).

| Schema | Tables | Owns |
|---|---|---|
| `platform` | 4 | Games, platform apps, settings, environments |
| `auth` | 3 | External identities, player sessions, login records |
| `player` | 5 | Player subject, profile, save, snapshots, bans |
| `game` | 4 | Config definitions, versions, releases, release items |
| `gameplay` | 3 | Runs, settlements, run events |
| `economy` | 6 | Currency and item definitions, wallets, inventory, two ledgers |
| `ads` | 4 | Placements, sessions, claims, daily limits |
| `operation` | 7 | Announcements, mail, activities, batch reward jobs |
| `ranking` | 3 | Leaderboards, entries, snapshots |
| `admin` | 7 | Administrators, roles, permissions, sessions, MFA |
| `audit` | 2 | GM audit log, service audit log |
| `analytics` | 3 | Events, daily aggregates |
| `system` | 6 | Idempotency, outbox, jobs, service identities |

## 2. Conventions

| Topic | Rule |
|---|---|
| Primary keys | `uuid`, `gen_random_uuid()` default. Tables whose natural key is the identity use that key instead (`wallets`, `player_items`, `game_settings`, daily stats). |
| Game scope | Game-owned tables have `game_id uuid NOT NULL`. A referenced parent exposes `UNIQUE (game_id, id)`; children reference it with a composite foreign key. |
| Time | `timestamptz` everywhere, stored in UTC. `created_at` on every table, `updated_at` where rows change. |
| Money and counts | `bigint` in minor units. No `numeric`, no floating point. |
| Enumerations | `text` with a `CHECK` list, not PostgreSQL `ENUM`, so a value can be added with an ordinary migration. |
| Free-form data | `jsonb`, only where the structure belongs to a game or to a rule engine (section 4). |
| Secrets | Never stored. Columns hold references (`credential_ref`, `secret_ref`) or one-way hashes (`refresh_token_hash`). The one encrypted column is `admin_mfa.secret_encrypted`. |
| Deletion | Business rows are not hard-deleted. Status columns and `deleted_at` / `revoked_at` mark the end of life. Cleanup jobs delete only expired technical rows. |
| Naming | `snake_case`; tables plural; foreign keys named after the referenced entity (`player_id`, `board_id`); no reserved-word column names. |
| Actor columns | Where a row can be written by more than one kind of caller: `actor_type` / `created_by_type` in (`player`, `admin`, `service`, `system`) plus a text ID. |

## 3. Schema notes

### platform

`games.code` is a short stable slug for people and tooling; `games.id` is the key everything else references. A platform app belongs to exactly one game: `UNIQUE (platform, app_id)` is what lets login resolve the game without trusting the client. `game_platform_apps.credential_ref` points into the secret store.

`game_environments` describes a game's endpoints per environment. It does not partition player data; environments use separate databases.

### auth and player

`player.players` is the subject. Identities (`auth.player_identities`) attach external accounts to it; a player may have several inside one game. `unionid` is stored and has no constraint, because it must never join players across games.

Profile, save, snapshots and bans are separate tables so that each has its own write path and privileges:

| Table | Written by |
|---|---|
| `player_profiles` | The player |
| `player_saves` | The player (optimistic lock); GM restore |
| `player_save_snapshots` | Worker (scheduled); `gm-api` (before restore) |
| `player_bans` | `gm-api` only |

A ban is a row with its own life: start, optional expiry, revocation. `players.status = 'banned'` is the fast check; `player_bans` is the history and the reason.

`auth.login_records.player_id` is nullable because a login can fail before a player is known.

### game

```text
game_configs (key)
  └─ config_versions (immutable once validated; content inline or in object storage)
config_releases (immutable publication event, ordered by release_no)
  └─ config_release_items (which version of which config this release makes active)
```

A version is never overwritten. Publishing creates a release. Rolling back creates another release whose items point at older versions and whose `rollback_of_release_id` names the release being undone. The active version of a config is the item in the release with the highest `release_no` that contains that config.

`release_no` is an identity column because timestamps can tie and a release order must be total.

### gameplay

`game_runs.id` is generated by the server and is the handle the client settles against. The run stores what the server needs to judge the result later: level, difficulty, rule version and a server-side `run_context`.

`run_settlements` stores the client's claim (`result`) next to the server's decision (`validation_status`, `rewards`). `UNIQUE (game_id, run_id)` makes a second settlement impossible.

`run_events` holds notable events of a run, including risk signals.

### economy

See [economy-design.md](../architecture/economy-design.md). The points that shape the tables:

- `wallets` has a natural composite primary key; there is one row per player and currency.
- Ledger rows store a positive `amount` and a `direction`, plus `balance_after`, so each row can be checked on its own.
- Ledger rows reference the wallet or inventory row, which guarantees the projection exists.
- Both ledgers are append-only by trigger.

### ads

`ad_sessions` is the server's record that an ad view was started; `ad_reward_claims` is the decision. `ad_daily_limits` is a counter table keyed by player, placement and day, updated in the claim transaction so the limit holds under concurrency. `limit_date` uses the game's reset timezone, which is a game setting.

### operation

Mail is split into content (`mail_messages`), attachments (`mail_attachments`) and per-player delivery (`player_mail`). A mass mail is one content row and many delivery rows inserted by the worker.

`announcements` can be global (`scope = 'global'`, no game) or per game.

`activities.config` holds the tasks and reward table of an activity; `activity_claims` records each claimed reward once.

`reward_jobs` is the operator-facing record of a batch; its execution lives in `system.background_jobs`.

### ranking

PostgreSQL holds the scores. `period_key` is part of the entry key so that daily, weekly and season boards keep one row per player per period. Snapshots freeze a finished period.

### admin and audit

Administrators are platform-level and have no `game_id`. Scope lives on the role assignment (`admin_user_roles.scope_type`, `game_id`).

Both audit tables are append-only by trigger and by privilege. See [audit-policy.md](../security/audit-policy.md).

### analytics

`game_events` is raw client and server events, deduplicated by `(game_id, event_id)`. Daily tables hold aggregates produced by the worker. Nothing here is authoritative and nothing here grants assets.

### system

`idempotency_keys` stores request-level replays. `outbox_events` and `background_jobs` are described in [async-job-design.md](../architecture/async-job-design.md). The three `service_*` tables exist for the reserved internal API and are empty in V1.

## 4. Where JSONB is used

| Column | Why it is JSONB | Not allowed inside |
|---|---|---|
| `player_saves.save_data`, snapshots | Game-specific state the platform does not interpret | Balances, items, entitlements |
| `config_versions.content` | Game-defined configuration validated by JSON Schema | — |
| `game_runs.run_context`, `run_settlements.result`, `rewards` | Per-game rule snapshot and claim | — |
| `ad_placements.reward_rule`, `activities.config`, `leaderboards.ranking_rule` | Rule definitions that differ per game | — |
| `mail_messages.target_filter`, job and outbox `payload` | Variable shape per target or job type | Secrets |
| `*_audit_logs.before_data` / `after_data` | Redacted snapshots of arbitrary entities | Passwords, tokens, keys |
| `daily_*_stats.metrics` | Metric set grows over time | — |

Anything queried by value, constrained, or summed gets a real column.

## 5. Tables that will grow

| Table | Growth driver | Plan |
|---|---|---|
| `analytics.game_events` | Every client event | First candidate for time partitioning and short retention; move to a separate store when volume justifies it |
| `economy.wallet_transactions`, `item_transactions` | Every asset change | Partition by time; retention is a policy decision because it is the financial record |
| `auth.login_records` | Every login | Partition by time; retention by policy |
| `audit.admin_audit_logs`, `service_audit_logs` | Every GM mutation | Long retention; archive, never delete inside the retention period |
| `gameplay.game_runs`, `run_settlements`, `run_events` | Every run | Archive old runs |
| `operation.player_mail` | Mass mail × players | Delete expired and claimed mail after a retention period |
| `system.background_jobs`, `outbox_events`, `idempotency_keys` | Operations | Cleanup job |

Partitioning and retention are decided from measured volume, not up front (ADR-0006). Retention periods are an open question in [decisions.md](../architecture/decisions.md).

## 6. Changing the schema

- `schema.sql` is the reviewed baseline. T03 turns it into ordered migrations under `/migrations`; after that, the migrations are the source of truth and `schema.sql` is regenerated or retired. **(proposal: retire it once migrations exist, to avoid two sources.)**
- An applied migration is never edited.
- Changes follow expand and contract.
- Every new table is reviewed for game scope, unique constraints, indexes, retention and personal-data classification.
