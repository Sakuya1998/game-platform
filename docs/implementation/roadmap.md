# Implementation roadmap

The sequence below assumes a small team and a first production release for WeChat Mini Games. Calendar estimates are planning ranges, not commitments.

## Phase 0 — Architecture and engineering baseline (1 week)

- [ ] Review ADRs; resolve production open questions.
- [ ] Create one Go module, lint/test conventions, config loading, structured logging, request IDs.
- [ ] Create independent Gin entrypoints for game-api and gm-api.
- [ ] Establish shared gamecore package boundaries and dependency direction.
- [ ] Add CI for Go tests, formatting, static analysis, OpenAPI lint, and migration validation.

**Gate:** both binaries build independently; neither imports the other's transport package.

## Phase 1 — Database and platform registry (1 week)

- [ ] Convert schema.sql into ordered, immutable migrations.
- [ ] Create least-privilege migration/runtime database roles.
- [ ] Seed a game and its WeChat app mapping.
- [ ] Add repository integration tests for game-scoped composite foreign keys.
- [ ] Add readiness/liveness and graceful shutdown.

**Gate:** cross-game foreign-key tests reject invalid references; runtime roles are not owners/superusers.

## Phase 2 — Player authentication and profile (1–2 weeks)

- [ ] Implement WeChat code exchange adapter and secret-manager integration.
- [ ] Resolve game/app from trusted app mapping.
- [ ] Implement game-scoped identity mapping and player provisioning.
- [ ] Issue platform access/refresh tokens; hash and rotate refresh tokens.
- [ ] Implement logout/revocation, rate limits, and login abuse telemetry.

**Gate:** same WeChat identity in two games produces two independent player IDs; secrets never appear in logs/responses.

## Phase 3 — Config, bootstrap, and save (1–2 weeks)

- [ ] Implement config draft/version/validation/release/rollback.
- [ ] Store large config objects in S3/OSS with checksum and immutable keys.
- [ ] Implement bootstrap and ETag/If-Match save concurrency.
- [ ] Add save schema migration and snapshot/restore.

**Gate:** stale save writes return 412; published config is immutable and rollback is auditable.

## Phase 4 — Gameplay settlement and economy (2 weeks)

- [ ] Implement run creation, expiry, one-time settlement.
- [ ] Define game-specific server validation and reward caps.
- [ ] Implement wallet/item ledger services with row locking or conditional updates.
- [ ] Add idempotency for settlement and all grants/spends.
- [ ] Ensure audit and outbox writes are in the same transaction as mutations.

**Gate:** concurrent duplicate settlement/grant tests result in exactly one durable grant; balances never become negative.

## Phase 5 — Ads and player operations (1 week)

- [ ] Implement ad placement/session/claim policy and daily limits.
- [ ] Document that client completion callback is not trusted proof.
- [ ] Implement mail, claim, activity, and leaderboard read paths.
- [ ] Add abuse controls and operational dashboards.

**Gate:** replayed ad claims and duplicate mail/activity claims cannot duplicate rewards.

## Phase 6 — GM security and core workflows (2 weeks)

- [ ] Implement independent GM authentication and MFA.
- [ ] Implement permission-code RBAC with game scope and deny-by-default middleware.
- [ ] Implement player search/status, wallet adjustment, config release, mail creation.
- [ ] Add immutable audit trail and reason/ticket requirements.
- [ ] Add optional dual-approval workflow for high-risk operations.

**Gate:** tests prove GM cannot operate outside assigned game scope; every privileged mutation has an audit row.

## Phase 7 — GM Web, analytics, and internal worker (1–2 weeks)

- [ ] Build Vue 3 + TypeScript + Element Plus console.
- [ ] Generate typed client from gm-api OpenAPI.
- [ ] Add operational metrics and basic DAU/retention/settlement/ad reports.
- [ ] Only if asynchronous jobs require a process boundary, implement worker and enable internal API routes with workload identity.

**Gate:** GM Web uses gm-api only; internal API is inaccessible from public ingress and rejects unauthorized workloads.

## Phase 8 — Production readiness (1 week)

- [ ] Threat model and security review.
- [ ] Load test login, bootstrap, save, settlement, GM search, and ledger writes.
- [ ] Verify backup restore/PITR and object-store recovery.
- [ ] Validate alerts, dashboards, log redaction, and on-call runbooks.
- [ ] Test deploy rollback and database expand/contract migrations.
- [ ] Verify WAF/rate limits, TLS, CORS, secrets, and GM network restrictions.

**Release gate:** all critical security/integrity tests pass; RPO/RTO and retention decisions are documented.

## Cross-cutting engineering rules

1. One task/PR should change one bounded concern and include tests.
2. ADRs are changed explicitly; implementation work must not silently rewrite decisions.
3. Every API mutation documents authorization, idempotency, transaction boundary, and audit behavior.
4. Every table is reviewed for game scope, unique constraints, indexes, retention, and PII classification.
5. OpenAPI is linted in CI and generated clients are not hand-edited.
6. No message broker or Kubernetes is introduced without a measured requirement and an ADR.
