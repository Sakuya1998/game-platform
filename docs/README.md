# Architecture documentation

Baseline v2.0 (2026-11-23).

## Overview

| Document | Purpose |
|---|---|
| [Game Platform 技术设计与实施方案](game-platform-technical-design.md) | End-to-end design: architecture, modules, database, APIs, GM platform, worker, deployment, roadmap |
| [Architecture overview and ADR index](architecture/decisions.md) | Component responsibilities, changes from baseline 1.0, open questions |
| [Implementation roadmap](implementation/roadmap.md) | Phases P0–P8, gates, Codex tasks T00–T22, V1 scope |

## Decisions (Accepted)

| ADR | Decision |
|---|---|
| [ADR-0001](adr/ADR-0001-modular-monolith.md) | Modular monolith: one Go module, shared `gamecore`, independent entrypoints |
| [ADR-0002](adr/ADR-0002-game-isolation.md) | `game_id` as the isolation key |
| [ADR-0003](adr/ADR-0003-player-account-model.md) | Per-game accounts, WeChat login, tokens |
| [ADR-0004](adr/ADR-0004-data-authority-model.md) | Server authority, client-run combat with server settlement |
| [ADR-0005](adr/ADR-0005-api-service-boundaries.md) | Four entries, three security planes, API conventions |
| [ADR-0006](adr/ADR-0006-postgresql-schema-design.md) | Schemas, constraints, roles, migrations |
| [ADR-0007](adr/ADR-0007-economy-transaction-model.md) | Balance plus ledger, idempotency, GM adjustments |
| [ADR-0008](adr/ADR-0008-internal-api-and-worker.md) | Worker calls `gamecore` directly; internal API reserved |
| [ADR-0009](adr/ADR-0009-async-job-model.md) | PostgreSQL-backed jobs and outbox |

## Topic documents (Draft for review)

These elaborate the ADRs. Where a topic document and an ADR disagree, the ADR wins. Detail that goes beyond the design document or an ADR is marked **(proposal)** inside each file and needs confirmation.

### Architecture

| Document | Covers |
|---|---|
| [System architecture](architecture/system-architecture.md) | Components, layering, key request flows, technology stack |
| [Service boundaries](architecture/service-boundaries.md) | The four entries, import rules, the Actor contract, third-party callbacks |
| [Game isolation](architecture/game-isolation.md) | Isolation layers, scoped and unscoped tables, RLS, isolation tests |
| [Authentication and authorization](architecture/authentication-and-authorization.md) | Player, GM and service planes, tokens, RBAC evaluation, secrets |
| [Data authority model](architecture/data-authority-model.md) | Who owns which data, settlement checks, ad reward trust levels |
| [Economy design](architecture/economy-design.md) | Wallets, items, ledgers, idempotency, GM adjustments, reconciliation |
| [Async job design](architecture/async-job-design.md) | Job states, claiming, leases, retries, outbox, job catalogue |
| [Deployment architecture](architecture/deployment-architecture.md) | Topology, configuration, database roles, migrations, environments |

### Database

| Document | Covers |
|---|---|
| [PostgreSQL DDL](database/schema.sql) | Baseline schema: 57 tables in 13 schemas |
| [ERD](database/erd.md) | Entity relationships, key rules, deviations from the design document |
| [Schema design](database/schema-design.md) | Conventions, notes per schema, JSONB use, tables that grow |
| [Constraints and indexes](database/constraints-and-indexes.md) | Business rules enforced by constraints, index catalogue, known gaps |
| [Database roles and grants](database/database-roles-and-grants.md) | Roles, grant matrix, wallet write path, verification |

### API

| Document | Covers |
|---|---|
| [Game API contract](../api/openapi/game-api.yaml) and [guide](api/game-api.md) | Player-facing API (`/api/v1`) |
| [GM API contract](../api/openapi/gm-api.yaml) and [guide](api/gm-api.md) | Operator API (`/gm/v1`) |
| [Internal API contract](../api/openapi/internal-api.yaml) and [guide](api/internal-api.md) | Service-to-service API (`/internal/v1`); reserved, not deployed in V1 |

### Security

| Document | Covers |
|---|---|
| [Threat model](security/threat-model.md) | Assets, actors, trust boundaries, threats and mitigations, accepted risks |
| [RBAC matrix](security/rbac-matrix.md) | Permission catalogue, role matrix, scope rules |
| [Audit policy](security/audit-policy.md) | What is audited, record content, redaction, integrity, retention |

## Baseline

- First client platform: WeChat Mini Games. Other platforms are reached through a platform adapter.
- Each game has an independent player account namespace; `game_id` is the isolation key.
- `game-api` and `gm-api` are independently deployed Go + Gin processes with separate security planes.
- `game-worker` is a separate process for asynchronous work.
- All three call the same in-process `gamecore` packages. No entry calls another over HTTP.
- `internal-api` is reserved: it has a contract and a service-auth abstraction but is not deployed in V1.
- V1 includes the complete GM platform: administrators, RBAC, player and economy management, config centre, mail, activities, audit and basic operations data.
- PostgreSQL is the authoritative store. Redis is cache, rate limiting and leaderboard read acceleration. S3/OSS + CDN hold config payloads and assets.
- No message broker, Kubernetes, payments or real-time combat server in V1.

## Housekeeping

`api/openapi/player-api.yaml` is superseded by `game-api.yaml`. The file is a comment-only stub and should be removed with `git rm api/openapi/player-api.yaml`.

`docs/runbooks/` from the repository layout does not exist yet; the backup and restore runbook is a T20 deliverable.

## Status and change control

These documents define the design baseline, not an implemented system. No application code exists in this repository. The DDL has not been executed against PostgreSQL, the OpenAPI documents have not been run through a linter, and the Mermaid diagrams have not been rendered.

Decisions marked **Accepted** are the baseline. Changing service boundaries, identity isolation, data authority or authorization requires amending the relevant ADR and review before implementation. Topic documents are drafts until reviewed; their **(proposal)** items are listed as open questions in [decisions.md](architecture/decisions.md).

DDL and OpenAPI are versioned artifacts. Apply schema changes through forward-only migrations; do not edit an applied migration in place.
