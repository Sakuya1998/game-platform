# ADR-0003 — Player account model

- **Status:** Accepted
- **Date:** 2026-11-23
- **Supersedes:** ADR-003 in `docs/architecture/decisions.md` v1.0
- **Related:** [ADR-0002](ADR-0002-game-isolation.md), [ADR-0005](ADR-0005-api-service-boundaries.md)

## Context

The first platform is WeChat Mini Games; Douyin, Alipay and native Android/iOS may follow. The same WeChat user can play several games on the platform.

## Decision

**Accounts are per game.**

- The same WeChat user entering two games gets two different `player_id` values.
- External identity uniqueness is `UNIQUE (game_id, platform, app_id, openid)`.
- A player may have several external identities inside one game. `unionid` may be stored, but equal `unionid` values never merge players across games.

**WeChat login.**

1. The client calls `wx.login()` and sends the temporary code to `game-api`.
2. The server resolves the game from the platform app, calls `jscode2session` with that app's secret, and obtains the OpenID.
3. The server maps the identity to a player in that game, creating the player if none exists. Creation is idempotent under concurrent logins through the unique identity key.
4. The server issues its own access and refresh tokens. The client uses only platform tokens afterwards.

**Credential handling.**

- AppSecret is held only in the server-side secret store; the database stores a reference.
- WeChat `session_key` is never returned to the client.
- Refresh tokens are stored as hashes, rotated on use, and can be revoked. Logout, revocation and bans are supported.
- Login is rate limited. Failed WeChat logins are recorded with a diagnosable error code in `auth.login_records`, without the code, `session_key` or tokens.

**Initial token lifetimes** (adjustable after security review):

| Token | Initial value |
|---|---|
| Player access token | 1 hour |
| Player refresh token | 30 days |
| GM access token | 15–30 minutes |
| GM refresh token | Set by security policy; revocable |
| Service credential | Separate AK/SK or mTLS |

**Platform adapter.** Provider-specific login lives behind an adapter in `internal/platform/<provider>`. `gamecore` works with normalized identity records and does not depend on WeChat data structures.

## Consequences

- Adding a platform means adding an adapter and a `game_platform_apps` row, not a new player model.
- Cross-game account linking is out of scope and would need a new ADR.
- A player who reinstalls or changes devices keeps the account through the OpenID; there is no platform-level account recovery flow in V1.
