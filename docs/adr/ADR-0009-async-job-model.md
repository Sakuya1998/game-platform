# ADR-0009 — Asynchronous job model

- **Status:** Accepted
- **Date:** 2026-11-23
- **Supersedes:** the asynchronous-work part of ADR-008 in `docs/architecture/decisions.md` v1.0
- **Related:** [ADR-0007](ADR-0007-economy-transaction-model.md), [ADR-0008](ADR-0008-internal-api-and-worker.md)

## Context

Some work cannot run inside a synchronous HTTP request: batch mail delivery, batch reward grants, statistics, leaderboard rebuilds, expired-data cleanup, save snapshots, config cache refresh and retries of failed tasks. A GM request that tries to process hundreds of thousands of players will time out and leave partial state.

## Decision

**PostgreSQL is the job queue in V1.** No message broker.

```text
gm-api / game-api ── create job (same transaction as the business change) ──> PostgreSQL
                                                                              ├─ system.background_jobs
                                                                              └─ system.outbox_events
game-worker ── claim → execute → retry → complete ──> gamecore
```

- Jobs and outbox events are written in the same transaction as the business change that causes them.
- `game-worker` claims jobs with `SELECT … FOR UPDATE SKIP LOCKED`, takes a lease, and refreshes it with heartbeats.

**Job states:** `pending`, `running`, `succeeded`, `failed`, `retrying`, `cancelled`.

**Required capabilities.**

- Maximum retry count and backoff.
- Lease, worker heartbeat, and reclaim of jobs whose lease expired.
- Idempotent execution: a job can be run twice without duplicating its effect; reward steps rely on the ledger unique key (ADR-0007).
- Recorded failure reason and manual retry from GM.

**Rule for GM operations.** Mass mail, batch rewards and group compensation always create a job (`operation.reward_jobs` as the business record, `system.background_jobs` for execution) and return immediately with a job reference. They are never processed inside the GM request.

**When to add a broker.** A message queue is introduced only when measured throughput, latency or fan-out exceeds what PostgreSQL polling supports, and through a new ADR.

## Consequences

- Polling adds seconds of latency to asynchronous work; acceptable for the V1 job types.
- Job tables add write load and vacuum pressure to the primary database; finished jobs need a cleanup job and retention period.
- At-least-once execution is the delivery guarantee, so every job handler has to be idempotent by construction and is tested with forced duplicate execution.
