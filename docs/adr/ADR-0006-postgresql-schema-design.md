# ADR-0006 — PostgreSQL schema design

- **Status:** Accepted
- **Date:** 2026-11-23
- **Supersedes:** ADR-005 and the database-role part of ADR-006 in `docs/architecture/decisions.md` v1.0
- **Related:** [ADR-0002](ADR-0002-game-isolation.md), [ADR-0007](ADR-0007-economy-transaction-model.md), [schema.sql](../database/schema.sql), [erd.md](../database/erd.md)

## Context

All durable business data lives in PostgreSQL. The layout has to keep domains separable, make game isolation enforceable by constraints, and keep database privileges from undoing application-level RBAC.

## Decision

**One database, schemas by domain.** Database `game_platform`, with schemas `platform`, `auth`, `player`, `game`, `gameplay`, `economy`, `ads`, `operation`, `ranking`, `admin`, `audit`, `analytics`, `system`. The V1 table set is the 57 tables listed in section 5.2 of the technical design.

**Conventions.**

- UUID primary keys; `timestamptz` for all times; integers in minor units for money and quantities.
- Game-owned tables carry `game_id`, expose `UNIQUE (game_id, id)` where referenced, and are referenced through composite foreign keys.
- Uniqueness, non-negative balances and idempotency are enforced by database constraints as the final defence, in addition to application checks.
- Audit logs and ledgers are append-only: runtime roles get `INSERT`/`SELECT` only, and a trigger rejects `UPDATE`/`DELETE`.

**Data access.**

- Explicit SQL (sqlc or hand-written) for wallet grants and spends, ledgers, idempotency, leaderboard queries and complex statistics, where transaction and locking semantics must be visible.
- GORM is acceptable for administrative CRUD: administrators, game configuration, and optionally player profiles.
- No SQL in handlers.

**Roles and privileges.**

- Separate runtime roles for `game-api`, `gm-api` and `game-worker`; a separate migration role; no superuser and no table ownership for runtime roles.
- V1 isolation is built from distinct roles, least-privilege grants and controlled repositories.
- For high-value asset writes, controlled SQL functions, `SECURITY DEFINER` or a dedicated write path are evaluated before any API process is given broad table write privileges.
- RLS is considered for high-risk data as defence in depth and is tested with real login roles.

**Migrations.** Schema changes are ordered, forward-only migrations (golang-migrate or Atlas) under `/migrations`. An applied migration is never edited. `docs/database/schema.sql` is the reviewed baseline from which T03 derives the first migrations.

**Environments.** Development, staging and production use separate databases. Test and production never share player data.

## Consequences

- One database is a shared failure domain and a shared scaling limit; this is accepted for V1.
- Event volume in `analytics.game_events` will outgrow the primary first; partitioning, retention or a separate analytics store is decided when volume is measured.
- Granting privileges per role per table is ongoing maintenance and must be covered by tests that connect as each runtime role.
