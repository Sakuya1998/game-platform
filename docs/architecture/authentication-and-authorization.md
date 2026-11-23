# Authentication and authorization

- **Status:** Draft for review (2026-11-23)
- **Elaborates:** [ADR-0003](../adr/ADR-0003-player-account-model.md), [ADR-0005](../adr/ADR-0005-api-service-boundaries.md), [ADR-0008](../adr/ADR-0008-internal-api-and-worker.md)
- **Source:** sections 4.2, 6, 7.2, 7.3 and 11.1 of the [technical design](../game-platform-technical-design.md)

Where this document and an ADR disagree, the ADR wins. Items marked **(proposal)** are not stated in the design document or an ADR and need confirmation.

## 1. Three security planes

| Plane | Entry | Principal | Credential | Store |
|---|---|---|---|---|
| Player | `game-api` | Player in one game | Platform access token and refresh token | `auth.player_sessions` |
| GM | `gm-api` | Administrator | Password, MFA, access token and refresh token | `admin.admin_sessions`, `admin.admin_mfa` |
| Service | `internal-api` (reserved) | Service identity | HMAC AK/SK or mTLS certificate | `system.service_credentials` |

The planes share nothing: different issuers, audiences, signing keys, session tables and middleware packages (`playerauth`, `adminauth`, `serviceauth`). A token of one plane fails signature or audience validation on another.

`game-worker` has no inbound credential. It runs as a `system` actor and is constrained by its database role.

## 2. Player plane

### 2.1 Login

1. Client: `wx.login()` returns a temporary code.
2. Client: `POST /api/v1/auth/wechat/login` with `app_id` and `code`.
3. Server: resolve the platform app and its game; reject unknown or disabled apps and disabled games.
4. Server: call `jscode2session` with the app secret read from the secret store.
5. Server: find the identity by `(game_id, platform, app_id, openid)`; if absent, create player and identity in one transaction. A concurrent duplicate hits the unique key and the loser re-reads.
6. Server: check for an active ban; a banned player gets `403 AUTH_FORBIDDEN`.
7. Server: create a session, store the refresh token hash, write a login record, return both tokens.

### 2.2 Tokens

| Token | Lifetime (initial) | Content | Storage |
|---|---|---|---|
| Access | 1 hour | `sub` = player ID, `game_id`, `sid` = session ID, `iss`, `aud`, `exp`, `iat` | Not stored; verified by signature |
| Refresh | 30 days | Opaque random value | SHA-256 hash in `auth.player_sessions.refresh_token_hash` |

Lifetimes are adjustable after security review.

### 2.3 Refresh, logout, revocation

- Refresh rotates: the presented token is consumed, a new session row is created with `rotated_from` pointing at the old one, and the old row is revoked.
- **(proposal)** Reuse detection: presenting a refresh token whose row is already rotated or revoked revokes the whole chain for that player, because it means the token was copied.
- Logout revokes the current session.
- A ban revokes all of the player's sessions.

An access token stays cryptographically valid until it expires, up to one hour after a ban or logout. **(proposal)** Close that window with a short-lived Redis denylist keyed by session ID (TTL = remaining access-token lifetime), checked by `playerauth`. If Redis is unavailable the check falls back to the database for asset-changing routes.

### 2.4 Player authorization

There is no permission model for players. The rule is ownership: every operation acts on `actor.ID` inside `actor.GameID`. `game-api` has no route parameter that names another player.

## 3. GM plane

### 3.1 Login with MFA

1. `POST /gm/v1/auth/login` with username and password. On success the response carries a short-lived, single-use `challenge_token`, never an access token.
2. `POST /gm/v1/auth/mfa/verify` with the challenge token and a TOTP or recovery code. On success the server creates an `admin.admin_sessions` row with `mfa_verified_at` and returns tokens.
3. An administrator without enrolled MFA is sent through enrollment before any token is issued. **(proposal)** MFA is mandatory for every administrator in production.

| Control | Rule |
|---|---|
| Password storage | Argon2id or bcrypt hash in `admin.admin_users.password_hash` **(proposal: Argon2id)** |
| Lockout | `failed_login_count` and `locked_until` on the user row; lock after repeated failures **(proposal: 5 failures, 15 minutes)** |
| MFA secret | Encrypted with a KMS-managed key in `admin.admin_mfa.secret_encrypted` |
| Access token | 15–30 minutes |
| Refresh token | Lifetime set by security policy; hashed, rotated, revocable |
| Network | VPN, Zero Trust or IP allowlist in front of `gm-api` where feasible |

### 3.2 RBAC evaluation

Authorization is evaluated per request as **administrator + permission code + game scope**. Role names are never compared in code.

```text
allow(admin, permission, game_id) =
    exists assignment a of admin where
        permission in permissions(a.role)
        and ( a.scope_type = 'platform'
              or (a.scope_type = 'game' and a.game_id = game_id) )
```

- Default is deny. An operation without a declared permission code is not routable.
- For platform-level operations (create game, manage administrators, change role permissions) `game_id` is absent and only a `platform` assignment satisfies the check.
- List endpoints filter results to the games the administrator is scoped to instead of failing.
- A denied request returns `403 AUTH_FORBIDDEN` without revealing whether the target exists.
- Permission checks read the database or a cache with a short TTL **(proposal: 60 seconds)**, so a revoked role takes effect quickly.

The permission catalogue and the role matrix are in [rbac-matrix.md](../security/rbac-matrix.md).

### 3.3 High-risk operations

Manual grants and deductions, batch rewards, bans, save restore, config publish, mass mail and permission changes require:

- a second confirmation in `gm-web`,
- a mandatory `reason` (and `ticket_id` where available),
- an `Idempotency-Key`,
- an audit row written in the same transaction as the change.

V1 is single-operator. Dual approval above an amount threshold is a reserved enhancement and needs a threshold decision first.

## 4. Service plane (reserved)

Not deployed in V1; the tables and the `serviceauth` abstraction exist so it can be enabled without changing `gamecore`.

| Step | HMAC AK/SK | mTLS |
|---|---|---|
| Identify | `X-Access-Key` selects a `service_credentials` row | Client certificate fingerprint matches `credential_hash` |
| Authenticate | Recompute the HMAC-SHA256 signature over method, path, query, timestamp, nonce and body hash with the secret read from the secret manager | TLS handshake |
| Replay protection | `X-Timestamp` within the allowed skew; `X-Nonce` not seen before inside that window | Idempotency key |
| Authorize | Service has the operation's permission code for the request's `game_id` in `system.service_game_grants` | Same |
| Record | Row in `audit.service_audit_logs` | Same |

## 5. Third-party callers

WeChat and ad-platform callbacks are authenticated with the platform's own signature scheme. They get no token of any plane. See [service-boundaries.md](service-boundaries.md#5-third-party-callbacks).

## 6. From credential to Actor

```text
request ─ authenticate (plane middleware) ─ authorize (ownership / RBAC / grant) ─ build Actor ─ gamecore
```

The `Actor` is the only way identity reaches `gamecore`. Its fields come from verified credentials and server-side lookups, never from the request body.

## 7. Secrets

| Secret | Location | Never |
|---|---|---|
| WeChat AppSecret | Secret store; the database holds `credential_ref` | In the database, logs, responses or the repository |
| WeChat `session_key` | Server memory during login; persisted only if a feature needs it, encrypted | Returned to the client or logged |
| Token signing keys | Secret store, one key set per plane, rotated with overlap | Shared between planes |
| Refresh tokens | Hash only | Plaintext at rest |
| MFA secrets | Encrypted column | Plaintext at rest |
| Service secrets | Secret store, referenced by `secret_ref` | In the database |

Logs never contain AppSecret, refresh tokens, full `Authorization` headers or `session_key`.

## 8. Rate limits

Separate limits per route group: player login and refresh, save, settlement, ad claim, GM login and MFA verification. Limits are keyed by player or administrator where authenticated and by IP plus app ID where not. Concrete numbers are set during load testing (T22).
