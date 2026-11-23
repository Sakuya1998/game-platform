# GM API guide

- **Status:** Draft for review (2026-11-23)
- **Contract:** [`api/openapi/gm-api.yaml`](../../api/openapi/gm-api.yaml) is the source of truth. This guide explains behaviour the YAML cannot express. If they disagree, fix this guide.
- **Related:** [ADR-0005](../adr/ADR-0005-api-service-boundaries.md), [rbac-matrix.md](../security/rbac-matrix.md), [audit-policy.md](../security/audit-policy.md)

Items marked **(proposal)** are not stated in the design document or an ADR and need confirmation.

## 1. Basics

| Item | Value |
|---|---|
| Served by | `gm-api` |
| Base URL | `https://gm-api.example.com/gm/v1` |
| Caller | `gm-web` only |
| Authentication | Administrator access token issued after MFA |
| Authorization | Permission code + game scope, deny by default |
| Format | Same envelope, field style and error codes as the Game API |

The GM plane is separate from the player plane. A player token is rejected here; an administrator token is rejected by `game-api`.

## 2. Login

1. `POST /auth/login` with username and password returns a `challenge_token`. No access token is issued at this step.
2. `POST /auth/mfa/verify` with the challenge token and a code returns the access and refresh tokens.
3. `POST /auth/refresh` rotates the refresh token.

The contract has no logout endpoint and no MFA enrollment endpoints. Both are needed for a usable console and are an open point for T15.

## 3. How every mutation behaves

| Rule | Detail |
|---|---|
| Permission | The operation's `x-required-permission` must be held for the path `game_id`, or at platform scope |
| Scope | A `game_id` the administrator is not scoped to returns `403 AUTH_FORBIDDEN` without revealing whether it exists |
| Idempotency | `Idempotency-Key` is required; a repeat returns the stored result |
| Reason | High-risk operations require `reason`; `ticket_id` is optional |
| Audit | One `audit.admin_audit_logs` row in the same transaction as the change |
| Batches | Anything over many players returns `202` with a job reference |

## 4. Operations

"Audit" names the `action` written to the audit log. "Risk" marks operations that need a second confirmation in `gm-web`.

### Games

| Operation | Permission | Scope | Audit | Risk |
|---|---|---|---|---|
| `GET /games` | `game.read` | Filtered to the administrator's games | — | |
| `POST /games` | `game.manage` | Platform | `game.manage` | |

`credential_ref` in the request is a secret-store reference. The AppSecret itself is never sent to or returned by this API.

### Players

| Operation | Permission | Audit | Risk |
|---|---|---|---|
| `GET /games/{game_id}/players` | `player.read` | — | |
| `GET /games/{game_id}/players/{player_id}` | `player.read` | — | |
| `POST .../players/{player_id}/ban` | `player.ban` | `player.ban` | Yes |
| `POST .../players/{player_id}/unban` | `player.unban` | `player.unban` | |
| `POST .../players/{player_id}/save/restore` | `player.save.restore` | `player.save.restore` | Yes |

A ban inserts a `player_bans` row, sets the player's status and revokes the player's sessions in one transaction. A restore snapshots the current save first, then replaces it and increments `save_version`. Wallets and items are not touched by a restore.

### Economy

| Operation | Permission | Audit | Risk |
|---|---|---|---|
| `GET .../players/{player_id}/wallets` | `economy.read` | — | |
| `POST .../players/{player_id}/wallet-adjustments` | `economy.grant` for a positive amount, `economy.deduct` for a negative one | `economy.grant` or `economy.deduct` | Yes |
| `GET /games/{game_id}/transactions` | `economy.read` | — | |

An adjustment carries a change (`amount`), never a target balance. The ledger row and the audit row, with the balance before and after, commit together. A deduction below zero returns `409 INSUFFICIENT_BALANCE`.

There is no endpoint to adjust items or to start a batch reward that is not a mail. Both are named in the GM menu of the design and are an open point for T11 and T13.

### Config

| Operation | Permission | Audit | Risk |
|---|---|---|---|
| `GET /games/{game_id}/configs` | `config.read` | — | |
| `POST /games/{game_id}/configs` | `config.edit` | `config.edit` | |
| `POST .../configs/{config_id}/versions` | `config.edit` | `config.edit` | |
| `POST .../configs/{config_id}/validate` | `config.edit` | `config.edit` | |
| `POST .../configs/{config_id}/publish` | `config.publish` | `config.publish` | Yes |
| `POST .../configs/{config_id}/rollback` | `config.publish` | `config.publish` | Yes |

Lifecycle: draft, validate, publish, active, rollback. Only a `validated` version can be published. Publishing and rolling back both create a new release; nothing is overwritten. A release also writes an outbox event that triggers cache and CDN refresh.

The list and create-version operations are kept from contract 1.0. The design table does not list them, but the lifecycle cannot be completed without a way to add a version.

### Mail, activities, announcements, leaderboards

| Operation | Permission | Audit | Risk |
|---|---|---|---|
| `POST /games/{game_id}/mails` | `mail.create` | `mail.create` | |
| `POST .../mails/{mail_id}/send` | `mail.send` | `mail.send` | Yes |
| `POST /games/{game_id}/activities` | `activity.manage` | `activity.manage` | |
| `POST /games/{game_id}/announcements` | `announcement.manage` | `announcement.manage` | |
| `GET /games/{game_id}/leaderboards` | `ranking.read` | — | |

`send` creates a reward job and a background job and returns `202`. Delivery is done by `game-worker` and is idempotent per player.

The contract covers creation only. Listing, editing, publishing and disabling activities and announcements, listing mails and job progress, and leaderboard creation and rebuild are in the GM menu of the design but not in its API table. They are an open point for T13, T14 and T16.

### Administrators, roles, audit, analytics

| Operation | Permission | Scope | Audit | Risk |
|---|---|---|---|---|
| `GET /admins` | `admin.read` | Platform | — | |
| `POST /admins` | `admin.manage` | Platform | `admin.manage` | Yes |
| `GET /roles` | `admin.read` | Platform | — | |
| `PUT /roles/{role_id}/permissions` | `rbac.manage` | Platform | `rbac.manage` | Yes |
| `GET /audit-logs` | `audit.read` | Filtered to the administrator's games; platform entries need platform scope | — | |
| `GET /analytics/overview` | `analytics.read` | The `game_id` query parameter | — | |

No password is ever returned. A new administrator sets a password and enrolls MFA at first login.

## 5. Things `gm-web` must do

- Ask for a second confirmation on every operation marked "Risk".
- Generate one `Idempotency-Key` per user action and reuse it if the request is retried.
- Hide menu items the administrator has no permission for, and still expect `403` from the server: the server is the authority.
- Show the job reference for batch operations and poll its status instead of waiting on the request.
- Use the TypeScript client generated from the OpenAPI file; do not hand-write request types.

## 6. What this API will never offer

- An endpoint that sets a wallet balance.
- An endpoint that executes a batch inside the request.
- Direct database access or arbitrary queries.
- Any route reachable with a player token.
