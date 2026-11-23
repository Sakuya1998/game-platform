# Game API guide

- **Status:** Draft for review (2026-11-23)
- **Contract:** [`api/openapi/game-api.yaml`](../../api/openapi/game-api.yaml) is the source of truth. This guide explains behaviour the YAML cannot express. If they disagree, fix this guide.
- **Related:** [ADR-0005](../adr/ADR-0005-api-service-boundaries.md), [data-authority-model.md](../architecture/data-authority-model.md)

Items marked **(proposal)** are not stated in the design document or an ADR and need confirmation.

## 1. Basics

| Item | Value |
|---|---|
| Served by | `game-api` |
| Base URL | `https://api.example.com/api/v1` |
| Caller | The game client |
| Authentication | `Authorization: Bearer <access token>`, except the two auth routes marked public |
| Format | JSON, `snake_case` fields, UTF-8 |
| Amounts | Integers in minor units |
| Time | RFC 3339, UTC |

The player and the game always come from the token. No route accepts a `player_id` or a `game_id`. At login the game is resolved on the server from `app_id`.

## 2. Response envelope

```json
{ "code": "OK", "message": "success", "data": {}, "request_id": "uuid" }
```

Errors use the same shape with a stable `code`. Clients branch on `code`, never on `message`.

| `code` | HTTP status | Meaning | Client action |
|---|---|---|---|
| `AUTH_UNAUTHORIZED` | 401 | Missing, invalid or expired token | Refresh once, then log in again |
| `AUTH_FORBIDDEN` | 403 | Player banned | Show the ban notice; do not retry |
| `GAME_DISABLED` | 403 | Game or platform app disabled | Show maintenance notice |
| `PLAYER_NOT_FOUND` | 404 | Token refers to a missing player | Log in again |
| `RESOURCE_NOT_FOUND` | 404 | Target does not exist for this player | Do not retry |
| `SAVE_VERSION_CONFLICT` | 412 | Save changed elsewhere | Reload the save, merge, retry |
| `GAME_RUN_ALREADY_SETTLED` | 409 | Run was settled before | Treat as done; refresh balances |
| `INSUFFICIENT_BALANCE` | 409 | Not enough currency or items | Refresh balances |
| `IDEMPOTENCY_CONFLICT` | 409 | Same key, different request body | Client bug; generate a new key per logical action |
| `CONFIG_VERSION_INVALID` | 409 | Config version not usable | Reload the config index |
| `RATE_LIMITED` | 429 | Too many requests | Back off |
| `INTERNAL_ERROR` | 500 | Server fault | Retry with backoff; safe if the request carried an idempotency key |

The status mapping is a **proposal** consistent with the YAML; the design lists the codes only.

## 3. Headers

| Header | Direction | Use |
|---|---|---|
| `X-Request-ID` | Request, optional | Client-generated ID; echoed as `request_id`. The server generates one if absent. |
| `Idempotency-Key` | Request, required on the operations marked below | One key per logical action; reuse it when retrying that action |
| `If-Match` | Request, required on save update | Quoted `save_version` the client last read; `"0"` for the first save **(proposal)** |
| `If-None-Match` / `ETag` | Config reads | Skip the body when the config is unchanged |

## 4. Operations

"Idem." is how a repeat is made harmless. "Writes" names what the server changes in one transaction.

### Auth

| Operation | Auth | Idem. | Writes |
|---|---|---|---|
| `POST /auth/wechat/login` | Public | Unique identity key | Player and identity on first login; session; login record |
| `POST /auth/refresh` | Public (refresh token in body) | A consumed token is rejected | New session row; old one revoked |
| `POST /auth/logout` | Token | Naturally idempotent | Session revoked |

### Player, config, save

| Operation | Idem. | Writes |
|---|---|---|
| `GET /player/profile` | Read | — |
| `PATCH /player/profile` | Last write wins | Profile |
| `GET /player/bootstrap` | Read | — |
| `GET /configs` | Read, `ETag` | — |
| `GET /configs/{key}` | Read, `ETag` | — |
| `GET /player/save` | Read | — |
| `PUT /player/save` | `If-Match` | Save, `save_version + 1` |

`bootstrap` returns profile, server time, `save_version`, wallets, the config index and the unread mail count, so a client needs one call after login.

Nickname and avatar are user-generated content. **(proposal)** Validate length and characters on the server and run the platform's text safety check before accepting a nickname.

### Gameplay

| Operation | Idem. | Writes |
|---|---|---|
| `POST /runs` | `Idempotency-Key` | Run; entry cost and its ledger row if the level has one |
| `POST /runs/{run_id}/settlement` | `Idempotency-Key`, plus one settlement per run | Settlement; run status; rewards and ledger rows |

The settlement body is the client's claim. The response lists the rewards the server granted and the resulting balances. A `validation_status` of `rejected` or `review` grants nothing.

### Economy and items

| Operation | Idem. | Writes |
|---|---|---|
| `GET /wallets` | Read | — |
| `GET /wallets/transactions` | Read, cursor | — |
| `GET /items` | Read | — |

There is no player-facing endpoint that grants or spends directly. Assets change only as a side effect of settlement, claims and run costs.

### Ads

| Operation | Idem. | Writes |
|---|---|---|
| `GET /ads/placements` | Read | — |
| `POST /ads/sessions` | `Idempotency-Key` | Ad session |
| `POST /ads/sessions/{session_id}/claim` | `Idempotency-Key`, plus one claim per session | Claim; daily counter; reward and ledger rows |

`client_completed` is the client's observation of `isEnded`. It is evidence, not proof. See the trust levels in [data-authority-model.md](../architecture/data-authority-model.md#5-ad-rewards).

### Mail, activities, leaderboards, events

| Operation | Idem. | Writes |
|---|---|---|
| `GET /mails` | Read, cursor | — |
| `POST /mails/{mail_id}/claim` | `Idempotency-Key`, plus `claimed_at` set once | `claimed_at`; attachments and ledger rows |
| `GET /activities` | Read | — |
| `POST /activities/{activity_id}/claim` | `Idempotency-Key`, plus one claim per reward | Claim; reward and ledger rows |
| `GET /leaderboards/{board_code}` | Read | — |
| `POST /events/batch` | `event_id` per event | Events |

`mail_id` in the claim path is the ID of the player's own mail entry, as returned by `GET /mails`.

The design writes the leaderboard route as `/leaderboards/{id}`. The contract uses `board_code`, because the client learns board codes from configuration and there is no endpoint that lists board IDs.

The contract has no endpoint to mark a mail as read or to delete one. `unread_mail_count` in `bootstrap` therefore needs either such an endpoint or a rule that listing marks mail as read. This is an open point.

## 5. Pagination

List operations take `cursor` and `limit` (1–100, default 20) and return `next_cursor`, which is `null` on the last page. Cursors are opaque; clients do not build or modify them.

## 6. Retry rules for the client

| Situation | Rule |
|---|---|
| Network error or timeout on a call with `Idempotency-Key` | Retry with the same key |
| `5xx` | Retry with backoff; same key where one applies |
| `401` | Refresh the token once, then repeat the call; if refresh fails, log in again |
| `409`, `412`, `403`, `404` | Do not retry blindly; handle by `code` |
| `429` | Back off |

A reward is never assumed from a request that was sent. The client shows what the response says.

## 7. Recommended startup sequence

1. `wx.login()`, then `POST /auth/wechat/login`.
2. `GET /player/bootstrap`.
3. For each entry in the config index whose checksum differs from the local copy, `GET /configs/{key}` or download its CDN URL.
4. `GET /player/save` if `save_version` is greater than the local one.

## 8. What this API will never offer

- A route that takes another player's ID.
- A route that sets a balance, grants an item, or accepts a reward amount from the client.
- A GM operation.
