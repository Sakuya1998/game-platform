# ADR-0005 — API service boundaries and security planes

- **Status:** Accepted
- **Date:** 2026-11-23
- **Supersedes:** ADR-006 and ADR-007 in `docs/architecture/decisions.md` v1.0
- **Related:** [ADR-0001](ADR-0001-modular-monolith.md), [ADR-0008](ADR-0008-internal-api-and-worker.md)

## Context

Players, GM operators, background jobs and trusted services all reach the same business rules, with very different privileges. A player may touch only their own data; a GM may ban players and adjust wallets inside the games they are scoped to; a worker runs system tasks but must not hold GM privileges; a service authenticates as a machine. A URL prefix alone cannot carry these differences.

## Decision

**Four entries, three security planes.**

| Component | Audience | Authentication | V1 |
|---|---|---|---|
| `game-api` | Player clients | Player token | Deployed |
| `gm-api` | GM Web | Admin session, MFA, RBAC with game scope | Deployed |
| `internal-api` | Trusted services | Service identity (HMAC AK/SK or mTLS) | Reserved, not deployed |
| `game-worker` | — (no HTTP entry) | Runs as `system` actor | Deployed with asynchronous work |

- Player and GM planes use separate token issuers, audiences, signing keys and session stores. `game-api` exposes no GM route; `gm-api` accepts no player credential.
- Suggested hosts: `api.example.com` → `game-api`; `gm-api.example.com` → `gm-api`; `gm.example.com` → `gm-web`; `internal.example.com` → `internal-api` (private network only, when deployed); `cdn.example.com` → CDN.

**Explicit caller context.** Each entry authenticates and authorizes the request, then builds an `Actor` (`type`: player / admin / service / system, `id`, `game_id`, roles, service) and passes it to every application-service call. Actor fields are never copied from client input.

**GM authorization.** Deny by default. Authorization is evaluated as administrator + permission code + game scope, never by role name. High-risk operations (manual grants and deductions, batch rewards, bans, save restore, config publish, mass mail, permission changes) require a second confirmation and a reason, and are audited. V1 implements single-operator execution with mandatory reason and audit; dual approval for high amounts is a reserved enhancement.

**Player API rule.** `game-api` offers no endpoint that takes an arbitrary `player_id`. Player identity comes from the verified token.

**Contracts.**

- OpenAPI 3.1 is the single source of truth: `api/openapi/game-api.yaml`, `gm-api.yaml`, `internal-api.yaml`. The TypeScript SDK is generated from them.
- Prefixes: `/api/v1`, `/gm/v1`, `/internal/v1`.
- Response envelope: `{ "code", "message", "data", "request_id" }` with stable machine-readable codes.
- Write endpoints support `Idempotency-Key`; save updates use `If-Match`; collections use cursor pagination; every request carries a `request_id`.

**Third-party callbacks are a separate surface.** Callbacks from WeChat or ad platforms arrive from the public internet under `/platform-callbacks/v1/...` and are verified with each platform's own signature, timestamp, deduplication and IP policy. They never use internal AK/SK rules.

## Consequences

- Two API images are built, configured and monitored separately from the first release.
- DTOs are duplicated where player and GM views of the same entity differ; this is intended.
- Open point: the process that hosts `/platform-callbacks/v1` is not fixed by the design. The default assumption is a dedicated route group in `game-api` with no player-token middleware; confirm before the first callback is implemented.
