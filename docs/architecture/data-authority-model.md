# Data authority model

- **Status:** Draft for review (2026-11-23)
- **Elaborates:** [ADR-0004](../adr/ADR-0004-data-authority-model.md)
- **Source:** sections 1.3, 4.3, 4.5, 4.7 and 5.2 of the [technical design](../game-platform-technical-design.md)

Where this document and the ADR disagree, the ADR wins. Items marked **(proposal)** are not stated in the design document or an ADR and need confirmation.

## 1. Principle

Combat runs on the client. Everything the client computes can be forged. The server therefore owns every piece of data whose forgery would cost money, progress or fairness, and treats client input as a claim to be checked.

## 2. Authority matrix

| Data | Authority | Who may write | What the client can influence |
|---|---|---|---|
| Player identity, status, bans | Server | Login flow; GM ban and unban | Nothing |
| Profile (nickname, avatar) | Server stores, player edits | Player, within validation | Its own nickname and avatar |
| Save (`player_saves.save_data`) | Client-authored, server-stored | Player, with optimistic lock; GM restore | Everything inside the save; nothing outside it |
| Currency balances | Server | Economy service only | Nothing directly |
| Item quantities | Server | Economy service only | Nothing directly |
| Wallet and item ledgers | Server, append-only | Economy service only | Nothing |
| Permanent unlocks and entitlements | Server | Server-side rules | Nothing directly |
| Run existence, level, rule version | Server | `POST /runs` | Which level it asks to play |
| Run result | Client claim | Player submits, server validates | Score, win flag, duration, within what the server accepts |
| Rewards of a run, ad, mail, activity | Server | Server computes from rules | Nothing; a client-sent reward is ignored |
| Ad completion | Client claim, or WeChat server-side verification if adopted | Player submits; platform callback | Only the claim |
| Config content | Server (GM publishes) | GM | Nothing |
| Leaderboard scores | Server | Server, from accepted settlements or validated submissions | Indirectly through accepted results |
| Analytics events | Client-reported, not authoritative | Player | Everything; never used to grant assets |

## 3. Saves

- A save holds non-critical game state as JSONB with `schema_version` and `save_version`.
- `PUT /api/v1/player/save` requires `If-Match` with the current `save_version`. A mismatch returns `412 SAVE_VERSION_CONFLICT`; the client reloads and decides how to merge.
- Balances, items and entitlements are never read from a save. If a save contains a field named like an asset, the server ignores it.
- Snapshots (`player_save_snapshots`) are taken on a schedule and before every GM restore. A restore replaces the save and increments `save_version`; it never touches wallets or items.
- **(proposal)** Enforce a maximum save size per game (setting `save.max_bytes`, default 256 KB) and reject larger writes with `413`.

## 4. Run settlement

The server cannot prove from `score`, `is_win` or `reward` that combat happened. It can bound the damage.

| Check | Rule |
|---|---|
| Ownership | The run belongs to the token's player and game |
| State | Status is `started`; a settled, expired or rejected run cannot be settled |
| Time | Not past `expires_at`; **(proposal)** not faster than a per-level minimum duration from config |
| Single settlement | `UNIQUE (game_id, run_id)` on `run_settlements` |
| Idempotent replay | Same `Idempotency-Key` returns the stored result |
| Costs | Entry costs (for example energy) are charged by the server, at creation or settlement, through the economy service |
| Reward | Computed by the server from the rule version recorded on the run; capped per run and per day |
| Plausibility | Score and progress within configured bounds for the level |
| Risk signals | Abnormal scores and rapid repeated clears are recorded as `run_events` and can set `validation_status = 'review'` |

`validation_status` is `accepted`, `rejected` or `review`. Only `accepted` grants rewards. V1 uses these lightweight checks. Server-side replay verification is considered for high-value modes and is not built in V1.

## 5. Ad rewards

Three levels of trust, weakest first:

| Level | Evidence | Status |
|---|---|---|
| 1 | Client reports `isEnded` in `onClose` | Baseline of the design |
| 2 | Level 1 plus server-side session, expiry, daily limit, single claim, device and behaviour signals | V1 design |
| 3 | WeChat's ad server calls the developer server when the reward condition is met (optional "服务端验证") | Not in the design; decision needed |

Level 2 flow:

1. `POST /api/v1/ads/sessions` creates an `ad_session` with an expiry after checking the placement and the remaining daily count.
2. The client shows the ad.
3. `POST /api/v1/ads/sessions/{session_id}/claim` checks player, game, placement, expiry, daily limit and that the session was not claimed, then grants through the economy service.

Level 3 would add: the platform callback marks the session as server-verified, and the claim requires that mark. WeChat documents this mode at <https://developers.weixin.qq.com/minigame/dev/guide/security/antiadcheat.html>. Its request fields and signature scheme have not been reviewed for this document, and the current schema has no column for the verified state; adopting it needs a schema migration and a callback endpoint (see [service-boundaries.md](service-boundaries.md#5-third-party-callbacks)).

Without level 3 the platform cannot promise that ad-reward cheating is fully prevented, so reward value per ad and per day stays low enough for the limits to protect.

## 6. Storage authority

| Store | Role | If it is lost |
|---|---|---|
| PostgreSQL | Authoritative for all business data, including leaderboards and jobs | Restore from backup and point-in-time recovery |
| Redis | Cache, rate-limit counters, leaderboard read acceleration, short-lived denylist | Rebuild from PostgreSQL; rate limits reset; no ownership or balance changes |
| S3 / OSS | Config payloads, assets, save backups | Config payloads are re-uploadable from `config_versions` when stored inline; otherwise restore from bucket versioning |
| CDN | Delivery only | Refill from origin |

Rules:

- A write is complete when PostgreSQL commits, not when Redis is updated.
- Redis locks never replace a database transaction or a unique constraint.
- Leaderboard reads may come from a Redis sorted set; the set is rebuilt from `leaderboard_entries` by a worker job.
- **(proposal)** Cache invalidation after a config release is driven by an outbox event, so a failed refresh is retried instead of lost.

## 7. What the client must be built to expect

- Any balance shown is a display copy; the next `bootstrap` or reward response overrides it.
- A reward response lists what the server granted, which may be less than the client predicted.
- Settlement and claim calls can be retried with the same `Idempotency-Key`.
- A save write can be refused with a version conflict.
