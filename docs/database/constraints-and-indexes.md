# Constraints and indexes

- **Status:** Draft for review (2026-11-23)
- **Elaborates:** [ADR-0002](../adr/ADR-0002-game-isolation.md), [ADR-0006](../adr/ADR-0006-postgresql-schema-design.md), [ADR-0007](../adr/ADR-0007-economy-transaction-model.md)
- **Source:** [schema.sql](schema.sql)

This is a catalogue of the constraints that carry business rules and of the indexes with the query each one serves. It was written by reading `schema.sql`; the DDL has not been executed, so nothing here has been confirmed by a query plan. Items marked **(proposal)** need confirmation.

## 1. Unique constraints that enforce a business rule

| Table | Constraint | Rule it enforces |
|---|---|---|
| `platform.games` | `UNIQUE (code)` | One game per code |
| `platform.game_platform_apps` | `UNIQUE (platform, app_id)` | A platform app belongs to exactly one game, so login can resolve the game |
| `platform.game_environments` | `UNIQUE (game_id, environment)` | One row per environment |
| `auth.player_identities` | `UNIQUE (game_id, platform, app_id, openid)` | One player per external identity per game; makes concurrent first logins safe |
| `auth.player_sessions` | `UNIQUE (refresh_token_hash)` | A refresh token maps to one session |
| `player.player_save_snapshots` | `UNIQUE (game_id, player_id, save_version)` | One snapshot per save version |
| `game.game_configs` | `UNIQUE (game_id, config_key)` | One config per key |
| `game.config_versions` | `UNIQUE (game_id, config_id, version)` | Version numbers are not reused |
| `game.config_release_items` | `PRIMARY KEY (game_id, release_id, config_id)` | A release names one version per config |
| `gameplay.run_settlements` | `UNIQUE (game_id, run_id)` | A run is settled at most once |
| `economy.wallets` | `PRIMARY KEY (game_id, player_id, currency_code)` | One wallet per player and currency |
| `economy.wallet_transactions` | `UNIQUE (game_id, player_id, currency_code, source_type, source_id, transaction_type)` | One business source changes one balance once |
| `economy.player_items` | `PRIMARY KEY (game_id, player_id, item_id)` | One inventory row per player and item |
| `economy.item_transactions` | `UNIQUE (game_id, player_id, item_id, source_type, source_id, transaction_type)` | Same rule for items |
| `ads.ad_placements` | `UNIQUE (game_id, placement_code)` | One placement per code |
| `ads.ad_reward_claims` | `UNIQUE (game_id, session_id)` | An ad session is claimed at most once |
| `ads.ad_daily_limits` | `PRIMARY KEY (game_id, player_id, placement_id, limit_date)` | One counter per player, placement and day |
| `operation.mail_attachments` | `UNIQUE (game_id, mail_id, reward_type, reward_id)` | An asset appears once per mail |
| `operation.player_mail` | `UNIQUE (game_id, mail_id, player_id)` | A mail is delivered to a player once |
| `operation.activities` | `UNIQUE (game_id, activity_code)` | One activity per code |
| `operation.activity_claims` | `UNIQUE (game_id, activity_id, player_id, reward_id)` | A reward of an activity is claimed once per player |
| `ranking.leaderboards` | `UNIQUE (game_id, board_code)` | One board per code |
| `ranking.leaderboard_entries` | `PRIMARY KEY (game_id, board_id, period_key, player_id)` | One score per player per period |
| `ranking.leaderboard_snapshots` | `UNIQUE (game_id, board_id, period_key)` | One snapshot per period |
| `admin.admin_users` | `UNIQUE (username)`, `UNIQUE (email)` | Login names are unique |
| `admin.admin_user_roles` | Partial unique indexes per scope type | The same role is assigned once per game, and once at platform level |
| `analytics.game_events` | `UNIQUE (game_id, event_id)` | Event upload is idempotent |
| `system.idempotency_keys` | `PRIMARY KEY (scope, idempotency_key)` | One stored outcome per key and scope |
| `system.background_jobs` | Partial unique index on `(job_type, dedupe_key)` | The same scheduled job is not enqueued twice |

## 2. Composite foreign keys

Every reference between game-owned tables includes `game_id`, so a child cannot point at a parent in another game. The stronger variants below also pin a second column.

| Child | References | Extra guarantee |
|---|---|---|
| `auth.player_identities (game_id, platform, app_id)` | `platform.game_platform_apps` | An identity can only exist for an app registered to that game |
| `auth.player_sessions (game_id, player_id, rotated_from)` | `auth.player_sessions (game_id, player_id, id)` | A rotation chain stays with one player |
| `game.config_release_items (game_id, config_id, version_id)` | `game.config_versions (game_id, config_id, id)` | A release item's version belongs to the config it names |
| `gameplay.run_settlements (game_id, run_id, player_id)` | `gameplay.game_runs (game_id, id, player_id)` | A settlement belongs to the run's own player |
| `ads.ad_reward_claims (game_id, session_id, player_id)` | `ads.ad_sessions (game_id, id, player_id)` | A claim belongs to the session's own player |
| `economy.wallet_transactions (game_id, player_id, currency_code)` | `economy.wallets` | A ledger row always has a wallet |
| `economy.item_transactions (game_id, player_id, item_id)` | `economy.player_items` | A ledger row always has an inventory row |
| `economy.wallets (game_id, currency_code)` | `economy.currency_definitions` | A wallet exists only for a defined currency |
| `economy.player_items (game_id, item_id)` | `economy.item_definitions` | Inventory exists only for a defined item |

Foreign keys with a nullable column (`login_records.player_id`, `game_events.player_id`, `reward_jobs.mail_id`, `config_releases.rollback_of_release_id`) use PostgreSQL's default `MATCH SIMPLE`: the reference is checked only when every column is non-null.

## 3. Check constraints

| Kind | Examples |
|---|---|
| Non-negative assets | `wallets.balance >= 0`, `player_items.quantity >= 0`, `balance_after >= 0`, `quantity_after >= 0` |
| Positive amounts | `wallet_transactions.amount > 0`, `item_transactions.quantity > 0`, `mail_attachments.quantity > 0` |
| Positive versions | `save_version > 0`, `schema_version > 0`, `config_versions.version > 0` |
| Time windows | `end_at > start_at` on activities and announcements; `game_runs.expires_at > started_at`; ban `expires_at > starts_at` |
| Explicit scope | `admin_user_roles`: platform scope has no game, game scope has one. `announcements`: global has no game, game scope has one |
| Payload present | `config_versions`: inline `content` or `object_key` |
| Credential shape | `service_credentials`: HMAC needs `access_key_id` and `secret_ref`; mTLS needs `credential_hash` |
| Rollback link | `config_releases`: a `rollback` release names the release it undoes |
| Explicit limits | `ad_placements.daily_limit > 0`, `session_ttl_seconds > 0` |
| Status vocabularies | Every `status`, `direction`, `result`, `actor_type` column lists its allowed values |
| Format | `games.code` matches `^[a-z][a-z0-9_-]{1,62}$` |

## 4. Append-only tables

`economy.wallet_transactions`, `economy.item_transactions`, `audit.admin_audit_logs` and `audit.service_audit_logs` have a `BEFORE UPDATE OR DELETE` trigger calling `system.reject_mutation()`. Runtime roles also get only `INSERT` and `SELECT` on them. The trigger does not stop `TRUNCATE` or a role that can disable triggers, which is why table ownership stays with a `NOLOGIN` role.

## 5. Indexes and the queries they serve

Primary keys and unique constraints create indexes; they are listed in section 1. The explicit indexes are:

| Index | Columns | Serves |
|---|---|---|
| `players_game_created_idx` | `(game_id, created_at DESC)` | GM player list, newest first |
| `player_profiles_nickname_idx` | `(game_id, nickname)` | GM search by exact nickname or prefix |
| `player_bans_player_idx` | `(game_id, player_id, starts_at DESC)` | Ban history of a player |
| `player_bans_active_idx` | `(game_id, player_id) WHERE revoked_at IS NULL` | Is this player currently banned |
| `player_identities_player_idx` | `(game_id, player_id)` | Identities of a player |
| `player_sessions_player_idx` | `(game_id, player_id)` | Revoke all sessions of a player |
| `player_sessions_expiry_idx` | `(expires_at) WHERE revoked_at IS NULL` | Cleanup of expired sessions |
| `login_records_player_idx` | `(game_id, player_id, created_at DESC)` | Login history of a player |
| `login_records_time_idx` | `(game_id, created_at DESC)` | Login success rate over time |
| `config_releases_game_idx` | `(game_id, release_no DESC)` | Latest releases of a game |
| `config_release_items_config_idx` | `(game_id, config_id)` | Release history of one config |
| `game_runs_player_idx` | `(game_id, player_id, started_at DESC)` | Recent runs of a player; rapid-clear checks |
| `run_settlements_player_idx` | `(game_id, player_id, settled_at DESC)` | Daily reward caps per player |
| `run_events_run_idx` | `(game_id, run_id, created_at)` | Events of a run |
| `wallet_transactions_player_idx` | `(game_id, player_id, created_at DESC)` | Player ledger pages |
| `wallet_transactions_source_idx` | `(game_id, source_type, source_id)` | Everything a business event paid |
| `item_transactions_player_idx`, `item_transactions_source_idx` | Same shapes | Same for items |
| `ad_sessions_player_idx` | `(game_id, player_id, created_at DESC)` | Recent ad sessions of a player |
| `announcements_game_window_idx` | `(game_id, start_at, end_at) WHERE status = 'published'` | Announcements visible now |
| `player_mail_inbox_idx` | `(game_id, player_id, created_at DESC) WHERE deleted_at IS NULL` | Player inbox |
| `reward_jobs_game_idx` | `(game_id, created_at DESC)` | Batch jobs of a game |
| `leaderboard_entries_rank_idx` | `(game_id, board_id, period_key, score DESC, updated_at)` | Top N of a board; ties broken by earlier update |
| `admin_sessions_admin_idx`, `admin_sessions_expiry_idx` | By administrator; by expiry | Session list and cleanup |
| `admin_audit_logs_game_time_idx`, `..._actor_time_idx`, `..._target_idx` | By game and time; by operator and time; by target | The three audit query shapes |
| `service_audit_logs_service_time_idx`, `..._game_time_idx` | By service and time; by game and time | Service audit queries |
| `game_events_type_time_idx` | `(game_id, event_type, occurred_at DESC)` | Event aggregation |
| `idempotency_keys_expiry_idx` | `(expires_at)` | Cleanup |
| `outbox_pending_idx` | `(next_attempt_at, occurred_at) WHERE published_at IS NULL` | Outbox polling |
| `background_jobs_claim_idx` | `(priority DESC, run_at) WHERE status IN ('pending','retrying')` | Job claim |
| `background_jobs_lease_idx` | `(lease_expires_at) WHERE status = 'running'` | Reclaim of expired leases |
| `service_credentials_service_idx` | `(service_id)` | Credentials of a service |

## 6. Known gaps

These are queries in the API contracts that the baseline indexes do not serve well. Each is to be confirmed with `EXPLAIN` on realistic data before an index is added.

| Query | Gap | Option |
|---|---|---|
| `GET /gm/v1/games/{game_id}/transactions` filtered by `currency` or `transaction_type` without a player | Only player and source indexes exist | `(game_id, created_at DESC)`, possibly with the filter column leading |
| GM player search by nickname substring | B-tree serves prefix only | `pg_trgm` GIN index, if substring search is required |
| GM player search by `openid` across apps | Unique index leads with `platform, app_id` | `(game_id, openid)` |
| Player's own rank on a large board | Counting rows above a score is a range scan | Redis sorted set as the read model, which the design already allows |
| Ad sessions to expire | No index on `expires_at` | Partial index on `(expires_at) WHERE status = 'created'` |
| Runs to expire | No index on `expires_at` | Partial index on `(expires_at) WHERE status = 'started'` |
| Unread mail count in bootstrap | Inbox index does not cover `read_at` | Partial index or a counter, after measuring |

## 7. How this is verified

T03 adds integration tests that try to violate each rule in sections 1 to 4 and expect the database to refuse: duplicate settlement, duplicate claim, cross-game reference, negative balance, ledger update and delete. Index choices are verified in T22 under load.
