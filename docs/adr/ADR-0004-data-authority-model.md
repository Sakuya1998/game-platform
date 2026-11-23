# ADR-0004 — Data authority model

- **Status:** Accepted
- **Date:** 2026-11-23
- **Supersedes:** ADR-004 and the storage parts of ADR-005 in `docs/architecture/decisions.md` v1.0
- **Related:** [ADR-0007](ADR-0007-economy-transaction-model.md)

## Context

Combat runs on the client to avoid the cost of real-time servers. Anything computed on the client can be forged, so the platform has to state exactly which data the client may influence and which it may not.

## Decision

**The server is authoritative for key data.** Currency balances, items, permanent unlocks and every reward-claim result are decided by the server. The client never submits a balance or a reward amount.

**Client-run combat, server-side settlement.**

1. `POST /runs` — the server creates the run, generates its ID, and records level, difficulty and rule version.
2. The client plays the run locally.
3. `POST /runs/{id}/settlement` — the server validates ownership, state, expiry, costs, reward caps and idempotency, then writes the settlement, the asset changes and the ledger rows in one transaction.

- A run can be settled once; duplicates are rejected by a unique constraint.
- Client-reported `score`, `is_win` and `reward` are untrusted inputs. The server cannot prove from them that the combat happened.
- The first game uses lightweight validation and conservative reward caps. Server-side replay verification is considered for high-value modes. Abnormal scores and rapid repeated clears feed risk control. No combat server is built in V1.

**Saves are not assets.**

- `player_saves` holds non-critical game state as versioned JSONB with optimistic locking (`If-Match` on `save_version`).
- Currency, items and paid entitlements live in dedicated tables. A client cannot change authoritative assets by submitting a save.
- Profile, permanent progress, current save and save history are managed separately; the platform does not put all game data into one JSONB document.

**Ad rewards.** The WeChat client callback `onClose({ isEnded: true })` shows only that the client observed completion. The server creates an ad session, enforces expiry, ownership, placement, daily limits and single claim, and records abnormal behaviour. Without a verifiable server-side callback from the ad platform, cheating cannot be fully prevented, and reward values are sized with that in mind.

**Storage authority.**

- PostgreSQL is the authoritative store for all business data, including leaderboards.
- Redis holds cache, rate limits and leaderboard read acceleration. Losing Redis must not change ownership or balances. Redis locks never replace database transactions and unique constraints.
- S3/OSS + CDN hold large config payloads and assets. PostgreSQL holds their metadata, checksums and release state.

## Consequences

- Anti-cheat is bounded, not complete; product design has to keep the value of client-earned rewards within what the caps can protect.
- Every reward path goes through the economy service (ADR-0007), which adds a transaction to each claim.
- Multi-device play can produce `SAVE_VERSION_CONFLICT`; the client must handle a reload-and-merge path.
