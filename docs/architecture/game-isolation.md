# Game isolation

- **Status:** Draft for review (2026-11-23)
- **Elaborates:** [ADR-0002](../adr/ADR-0002-game-isolation.md)
- **Source:** sections 4.1, 5.4 and 11.1 of the [technical design](../game-platform-technical-design.md)

Where this document and the ADR disagree, the ADR wins. Items marked **(proposal)** are not stated in the design document or an ADR and need confirmation.

## 1. Goal

Several games share one database and one codebase. A defect in one query, or a forged request, must not be enough to read or change another game's data. Isolation is therefore built in layers, and no single layer is trusted alone.

## 2. Layers

| # | Layer | Mechanism | What it stops |
|---|---|---|---|
| 1 | Identity resolution | At login the server maps `(platform, app_id)` to one game. `platform.game_platform_apps` has `UNIQUE (platform, app_id)`. | A client choosing its game |
| 2 | Token | The player token carries `game_id`; the GM path `game_id` is checked against the administrator's scope; a service `game_id` is checked against `system.service_game_grants` | A valid caller acting in a game it has no right to |
| 3 | Application service | `gamecore` compares the target row's `game_id` with `actor.GameID` | A handler passing the wrong scope |
| 4 | Repository | Every method on game-owned data takes `game_id`; SQL always filters on it | A forgotten `WHERE` |
| 5 | Database constraints | `UNIQUE (game_id, id)` on parents, composite foreign keys on children | A row in game A pointing at a row in game B |
| 6 | Database roles | Separate runtime roles per entry with least privilege | A compromised process reading tables it never needs |
| 7 | Row-level security | Optional, for high-risk tables | A query that bypasses layers 3 and 4 |

## 3. Which tables are game-scoped

| Scope | Tables |
|---|---|
| Game-owned, `game_id NOT NULL` | Everything in `auth`, `player`, `game`, `gameplay`, `economy`, `ads`, `ranking`; `operation` except global announcements; `analytics`; `platform` child tables; `system.service_game_grants` |
| Platform-level, no `game_id` | `platform.games`; `admin.admin_users`, `roles`, `permissions`, `role_permissions`, `admin_sessions`, `admin_mfa`; `system.idempotency_keys`, `service_identities`, `service_credentials` |
| Either, `game_id` nullable | `operation.announcements` (`scope = 'global'`), `admin.admin_user_roles` (`scope_type = 'platform'`), `audit.admin_audit_logs`, `audit.service_audit_logs`, `system.outbox_events`, `system.background_jobs` |

A nullable `game_id` always has an explicit discriminator or a documented meaning. `NULL` never means "all games" by accident: platform-wide administrator scope is the row value `scope_type = 'platform'`.

## 4. Repository rules

- A repository method that touches game-owned data has `gameID` as a parameter. There is no "by ID only" lookup for such data.
- Queries on player-owned data filter on `(game_id, player_id)`.
- Joins between game-owned tables include `game_id` in the join condition, which also lets PostgreSQL use the composite indexes.
- Cursor pagination tokens are opaque and encode the `game_id` they were issued for; a token replayed in another game is rejected. **(proposal)**

## 5. Outside the database

| Resource | Rule |
|---|---|
| Redis keys | Prefix with environment and game: `{env}:{game_id}:...`. Rate-limit keys for unauthenticated routes use the resolved game or the app ID. **(proposal)** |
| Object storage | Config payloads under `configs/{game_id}/{config_key}/{version}-{checksum}`; one bucket per environment. **(proposal)** |
| CDN | Public config and asset paths contain the game code or ID; nothing private is served from a public path |
| Logs and metrics | Every request log line has `game_id`; metrics carry a `game` label so one game's traffic can be read alone |
| Background jobs | A job row carries `game_id`; the worker builds its `system` actor from the job, not from configuration |

## 6. Row-level security

RLS is defence in depth and is not required for V1 launch.

If it is enabled for a table:

1. The application sets the scope inside the transaction: `SET LOCAL app.game_id = '<uuid>'`.
2. The policy compares `game_id` with `current_setting('app.game_id')::uuid`.
3. `SET LOCAL` is used so the setting cannot leak to the next user of a pooled connection.
4. Runtime roles are not owners and do not have `BYPASSRLS`; otherwise the policy does nothing.
5. Policies are tested by connecting as the real login role.

First candidates if adopted: `economy.wallets`, `economy.wallet_transactions`, `player.player_saves`, `auth.player_identities`. **(proposal)**

`gm-api` legitimately works across the games an administrator is scoped to, so its RLS scope is set per request to the path `game_id` after the RBAC check, never to "all".

## 7. Environments are a different axis

Development, staging and production are separated by database, Redis instance, bucket and WeChat app, not by `game_id`. Production data is not copied to other environments unless it has been anonymized.

## 8. Tests that prove isolation

| Test | Expected result |
|---|---|
| Insert a wallet for a player of game A with `game_id` of game B | Foreign-key violation |
| Insert a settlement whose run belongs to another player or game | Foreign-key violation |
| Player token of game A calls any `game-api` route and tampers with IDs in the body | Only game A data is read or changed; foreign IDs return `RESOURCE_NOT_FOUND` |
| Administrator scoped to game A calls `/gm/v1/games/{B}/...` | `403 AUTH_FORBIDDEN`, and nothing about game B is disclosed |
| Same WeChat OpenID logs in through two games' apps | Two different `player_id` values |
| Worker runs a job of game A that references a player of game B | The job step fails; nothing is written |
| Connect as `game_api_runtime` and select from `admin.admin_users` | Permission denied |

These belong to T03 (constraints, roles) and T21 (request-level tests).
