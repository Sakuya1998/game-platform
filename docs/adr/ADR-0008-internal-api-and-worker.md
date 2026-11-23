# ADR-0008 — Internal API and worker

- **Status:** Accepted
- **Date:** 2026-11-23
- **Supersedes:** ADR-002 in `docs/architecture/decisions.md` v1.0
- **Related:** [ADR-0001](ADR-0001-modular-monolith.md), [ADR-0005](ADR-0005-api-service-boundaries.md), [ADR-0009](ADR-0009-async-job-model.md)

## Context

V1 needs background execution for batch mail, batch rewards, statistics and cleanup. It does not yet need machine-to-machine HTTP calls. The earlier baseline treated the worker as a future component that would reach the platform through a private internal API; that would make a process in the same module call its own business core over HTTP.

## Decision

**A worker is not an internal API.** The worker is a process that executes tasks. The internal API is an entry for service calls.

**`game-worker` in V1.**

- `game-worker` is a separate process built from the same Go module. It calls `gamecore` application services directly, in-process, and reaches PostgreSQL through the same repositories.
- It runs as a `system` actor, has its own database role, and holds no GM privileges.
- It is deployed as soon as asynchronous work exists. A worker must not route its calls to `gamecore` through HTTP.

**`internal-api` is reserved.**

- V1 keeps the directory `services/internal-api`, the service-auth abstraction in `internal/security/serviceauth`, and the contract `api/openapi/internal-api.yaml`. No third HTTP service is deployed.
- It is deployed only when independent workers or other systems need HTTP access to platform business logic. It then calls the same `gamecore` services; it is not a third copy of business logic and must not become another GM API.
- Reserved contract (`/internal/v1`): job claim / heartbeat / complete / fail, mail-delivery execution, reward-job execution, internal event batch, config-release notification, controlled maintenance tasks.

**Requirements once deployed.**

- Private network access control.
- Independent service identity (`system.service_identities`, `service_credentials`).
- HMAC AK/SK signature or mTLS; timestamp + nonce replay protection.
- Authorization per service identity, with `game_id` scope from `system.service_game_grants`.
- Request idempotency, call audit in `audit.service_audit_logs`, rate limiting.

**Prepared in V1 regardless.** The `Actor` type includes `service` and `system`, and the service identity tables exist, so enabling the internal API later does not change `gamecore` signatures.

**Third-party callbacks are not internal API.** See ADR-0005.

## Consequences

- No third service to operate in V1, and no network hop between worker and business logic.
- Worker and API releases are coupled through the shared module; a job payload change must stay compatible with jobs already queued.
- The internal contract can drift while unused. It is linted in CI with the other two and reviewed again before first deployment.
