# ADR-0002 — Game isolation by `game_id`

- **Status:** Accepted
- **Date:** 2026-11-23
- **Supersedes:** the isolation parts of ADR-003 and ADR-005 in `docs/architecture/decisions.md` v1.0
- **Related:** [ADR-0003](ADR-0003-player-account-model.md), [ADR-0006](ADR-0006-postgresql-schema-design.md)

## Context

Several games share one database and one codebase. A missing `WHERE game_id = ?` must not be enough to leak or corrupt another game's data, and a client must not be able to switch games by sending a different identifier.

## Decision

- `game_id` (a platform-issued UUID) is the isolation key. A WeChat AppID is configuration of a game, never its identity.
- One PostgreSQL database for all games in V1; no database per game.
- Every game-owned table carries `game_id`. Important tables have `UNIQUE (game_id, id)`, and references between game-owned tables use composite foreign keys that include `game_id`.
- Repositories take `game_id` explicitly on every query. There is no repository method that reads game-owned data without a game scope.
- The game scope always comes from an authenticated context, never from a free client parameter:

  | Entry | Source of `game_id` |
  |---|---|
  | `game-api` | Player token claims; at login, resolved server-side from `(platform, app_id)` |
  | `gm-api` | URL path, accepted only after RBAC confirms the administrator's scope for that game |
  | `internal-api` | Request field, accepted only after the service identity's `service_game_grants` are checked |
  | `game-worker` | The job row |

- `game-api`, `gm-api` and `game-worker` connect with different database roles; migrations use a fourth role; no runtime role is an owner or a superuser.
- PostgreSQL RLS is evaluated as defence in depth for high-risk tables. It supplements application authorization and never replaces it.

## Consequences

- Composite keys make some foreign keys wider and require `game_id` in child tables that could otherwise omit it.
- Cross-game features (shared accounts, shared inventory) are not possible without a new ADR.
- Isolation is a tested property: cross-game foreign-key rejection and cross-game access attempts are part of the integration and security test suites (T03, T21).
