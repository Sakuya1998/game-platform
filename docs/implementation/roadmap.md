# Implementation roadmap

Baseline v2.0 (2026-11-23). Source: sections 12 and 13 of the [technical design](../game-platform-technical-design.md).

The first release targets WeChat Mini Games. The initial engineering estimate for V1 is 10–12 weeks in total; the actual duration depends on team size, client complexity and the depth of the operations features. Per-phase durations are not fixed in this baseline.

The gates below are carried over from baseline 1.0 and adapted to the new phase layout. They are acceptance conditions, not statements about work already done: no code exists in this repository yet.

## Phase 0 — Architecture and engineering baseline

- [ ] Freeze ADR decisions (the nine ADRs under `docs/adr/` are written and await review).
- [ ] Initialize the monorepo and the single Go module.
- [ ] Write `AGENTS.md`.
- [ ] Gin server baseline for `game-api` and `gm-api`.
- [ ] Initialize the Vue project for `gm-web`.
- [ ] Docker Compose.
- [ ] CI/CD: Go tests, formatting, static analysis, OpenAPI lint, migration validation.

**Gate:** `game-api`, `gm-api` and `game-worker` build independently; no entry imports another entry's transport package; `gamecore` does not import Gin.

## Phase 1 — Database and platform management

- [ ] PostgreSQL schemas.
- [ ] Convert `docs/database/schema.sql` into ordered, immutable migrations.
- [ ] Game management.
- [ ] Platform app configuration.
- [ ] Repository foundation.
- [ ] Database roles and privilege design: separate runtime roles for `game-api`, `gm-api`, `game-worker`, plus a migration role.

**Gate:** migrations apply to an empty database; cross-game foreign-key tests reject invalid references; runtime roles are neither owners nor superusers.

## Phase 2 — Player authentication and player module

- [ ] WeChat login.
- [ ] Player identity mapping.
- [ ] Access token and refresh token (hashed, rotated, revocable).
- [ ] Player profile.
- [ ] Player bans.

**Gate:** the same WeChat identity in two games yields two independent player IDs; a banned player cannot obtain or refresh tokens; secrets, codes and `session_key` appear in no log or response.

## Phase 3 — Configuration and saves

- [ ] Config versions.
- [ ] Config publishing and rollback.
- [ ] S3 / CDN storage for large config payloads.
- [ ] Save versions.
- [ ] Optimistic locking.
- [ ] Save snapshots.

**Gate:** a stale save write returns 412 `SAVE_VERSION_CONFLICT`; a published config version is immutable; rollback creates a new release and is audited.

## Phase 4 — Gameplay and economy

- [ ] Run management.
- [ ] Settlement validation.
- [ ] Wallets.
- [ ] Asset ledgers.
- [ ] Item inventory.
- [ ] Idempotency.

**Gate:** concurrent duplicate settlement and grant tests produce exactly one durable grant; balances never go negative; every balance change has a ledger row in the same transaction.

## Phase 5 — Ads and operations

- [ ] Ad sessions.
- [ ] Ad rewards.
- [ ] Mail.
- [ ] Announcements.
- [ ] Activities.
- [ ] Leaderboards.

**Gate:** replayed ad claims and duplicate mail or activity claims cannot duplicate rewards; daily ad limits hold under concurrency.

## Phase 6 — GM platform

- [ ] GM login and MFA.
- [ ] RBAC with permission codes and game scope.
- [ ] Player management.
- [ ] Economy management.
- [ ] Config management.
- [ ] Mail and activity management.
- [ ] Audit centre.

**Gate:** tests show a GM cannot act outside the assigned game scope or without the permission code; every privileged mutation has an audit row; `gm-web` talks to `gm-api` only.

## Phase 7 — Worker and analytics

- [ ] Outbox.
- [ ] Background jobs.
- [ ] `game-worker`.
- [ ] Batch mail and batch rewards.
- [ ] Event upload.
- [ ] Statistics jobs.

**Gate:** a job killed mid-run is reclaimed after its lease expires and completes without duplicating grants; mass mail and batch rewards never run inside a GM HTTP request.

## Phase 8 — Deployment and production acceptance

- [ ] Docker images.
- [ ] Independent service deployment.
- [ ] Backup and restore.
- [ ] Security testing.
- [ ] Load testing.
- [ ] WeChat Mini Game integration testing.

**Release gate:** all critical security and integrity tests pass; backup restore is rehearsed; `internal-api` is not reachable from any public ingress; the open questions in `docs/architecture/decisions.md` are answered and documented.

## Codex task breakdown

One task per Codex run. The phase column is a suggested mapping added in this roadmap; the design document defines the tasks and the phases separately.

| Task | Content | Acceptance artifact | Phase |
|---|---|---|---|
| T00 | Architecture ADRs | Architecture decision documents | P0 |
| T01 | Monorepo initialization | Directories, Go module, `AGENTS.md` | P0 |
| T02 | API server baseline | Two Gin servers: `game-api`, `gm-api` | P0 |
| T03 | PostgreSQL foundation | Schemas, migrations, database roles | P1 |
| T04 | Infrastructure | Redis, S3, configuration, logging | P0–P1 |
| T05 | Game Core foundation | Domain, application, repository | P1 |
| T06 | Platform management | Games, platform apps | P1 |
| T07 | Player authentication | WeChat login, identity mapping, tokens | P2 |
| T08 | Player management | Profile, ban, save | P2–P3 |
| T09 | Config centre | Config, version, release | P3 |
| T10 | Gameplay | Game runs, settlement | P4 |
| T11 | Economy | Wallet, transactions, items | P4 |
| T12 | Ads | Placement, session, claim | P5 |
| T13 | Operation | Mail, announcement, activity | P5 |
| T14 | Ranking | Leaderboard | P5 |
| T15 | GM auth / RBAC | Admin, role, permission, MFA | P6 |
| T16 | GM Web | Management console | P6 |
| T17 | Audit | GM and internal operation audit | P6 |
| T18 | Worker | Outbox, job, worker | P7 |
| T19 | API contracts | Three OpenAPI documents, SDK | P0 onward |
| T20 | Deployment | Compose, CI/CD, monitoring | P8 |
| T21 | Security | Permission, idempotency, isolation and audit tests | P8 |
| T22 | Acceptance | Integration, load testing, release acceptance | P8 |

`internal-api` in T02 means only the reserved directory, the service-auth abstraction and the OpenAPI contract. Deploying the service belongs to a later version and must not block `game-api` and `gm-api`.

## Requirements for every Codex task

Each task reports:

1. The goal completed in this run.
2. The list of changed files.
3. Database migration changes.
4. API / OpenAPI changes.
5. Permission and security impact.
6. Unit and integration tests.
7. The test commands actually run and their results.
8. Unfinished items.
9. Risks and follow-up dependencies.
10. A recommended Git commit message.

Not allowed:

- Changing an approved ADR without review.
- Replacing core business logic with a TODO.
- Deleting assertions to make tests pass.
- Fabricating test results.
- Merging the player API and the GM API into one security entry.
- Implementing business logic in handlers.
- Letting the client decide authoritative assets.
- Using a Redis lock in place of a database transaction and unique constraint.

## V1 scope

| Capability | V1 |
|---|---|
| Multi-game management | Required |
| WeChat login | Required |
| Per-game player accounts | Required |
| Player profile | Required |
| Saves with version control | Required |
| Config version management | Required |
| Runs and settlement | Required |
| Wallets and asset ledgers | Required |
| Item inventory | Required |
| Ad rewards | Required |
| GM platform | Required |
| RBAC | Required |
| Operation audit | Required |
| Mail and announcements | Required |
| Activity management | Required |
| Leaderboards | Basic version required |
| Worker | Enabled with asynchronous work |
| Internal API | Reserved, deployed on demand |
| Multi-platform adapter | Interface reserved |
| Payments | Not in scope |
| Real-time combat server | Not in scope |
| Kafka / RocketMQ | Not in scope |
| Kubernetes | Not in scope |
| Microservice split | Not in scope |
