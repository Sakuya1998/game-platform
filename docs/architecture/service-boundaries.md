# Service boundaries

- **Status:** Draft for review (2026-11-23)
- **Elaborates:** [ADR-0001](../adr/ADR-0001-modular-monolith.md), [ADR-0005](../adr/ADR-0005-api-service-boundaries.md), [ADR-0008](../adr/ADR-0008-internal-api-and-worker.md)
- **Source:** sections 2.2, 2.3, 6.3, 6.4 and 8.3 of the [technical design](../game-platform-technical-design.md)

Where this document and an ADR disagree, the ADR wins. Items marked **(proposal)** are not stated in the design document or an ADR and need confirmation.

## 1. The four entries

| Entry | Caller | Authentication | May do | Must never do |
|---|---|---|---|---|
| `game-api` | Game client | Player token | Act on the token's own player in the token's own game | Accept an arbitrary `player_id` or `game_id`; expose any GM operation |
| `gm-api` | `gm-web` | Admin session after MFA, RBAC with game scope | Read and operate on players, economy, config and operations inside the administrator's scope | Accept a player token; process a batch inside the request; set a balance directly |
| `game-worker` | None (pulls jobs) | Runs as `system` actor | Execute jobs and outbox events through `gamecore` | Hold GM permissions; call `gamecore` over HTTP |
| `internal-api` | Trusted services | Service identity (HMAC AK/SK or mTLS) | Reserved contract: job control, batch execution, internal events, maintenance | Become a second GM API; be reachable from the public internet |

Splitting `game-api` and `gm-api` is a security decision, not a scaling one. A URL prefix cannot express the difference between "a player may read their own wallet" and "an operator may debit any wallet in game X".

## 2. What is shared and what is not

| Shared (one copy in `internal/gamecore`) | Per entry (never shared) |
|---|---|
| Domain model and invariants | Handlers |
| Application services and transaction boundaries | Routers |
| Repository interfaces and implementations | Authentication middleware |
| | Request and response DTOs |
| | Rate-limit policy, CORS, body limits |
| | Process configuration, image, health checks |

A player-facing DTO and a GM-facing DTO of the same entity are allowed to differ and are defined twice on purpose.

## 3. Import rules

| Package | May import | Must not import |
|---|---|---|
| `internal/gamecore/domain` | Standard library, `internal/shared` | Everything else in the module |
| `internal/gamecore/application` | `domain`, `repository` interfaces, `internal/shared` | `transport`, `security`, Gin |
| `internal/gamecore/repository` | `domain`, `internal/infrastructure/postgres` | `transport`, Gin |
| `internal/transport/http/game` | `gamecore/application`, `security/playerauth` | `transport/http/gm`, `transport/http/internal`, `security/adminauth` |
| `internal/transport/http/gm` | `gamecore/application`, `security/adminauth` | `transport/http/game`, `transport/http/internal`, `security/playerauth` |
| `internal/transport/http/internal` | `gamecore/application`, `security/serviceauth` | The other two transport packages |
| `services/game-worker` | `gamecore/application`, `internal/infrastructure` | Any `transport` package |

**(proposal)** Enforce these rules in CI with an import-boundary linter (for example `depguard` in golangci-lint or `go-arch-lint`), so a violation fails the build instead of relying on review.

## 4. The Actor contract

Every application-service method takes an `Actor` as its first business argument.

```go
type Actor struct {
    Type    string // player / admin / service / system
    ID      string
    GameID  string
    Roles   []string
    Service string
}
```

- The entry builds the `Actor` after authentication and authorization. No field is copied from a request body, query string or header supplied by the client.
- `gamecore` re-checks what only it can know: that the target row belongs to `actor.GameID`, and, for a player actor, that the target player is the actor.
- Ledger rows, audit rows and job rows record `actor_type` and `actor_id`.

| Entry | `Type` | `ID` | `GameID` |
|---|---|---|---|
| `game-api` | `player` | Player ID from the token | Game ID from the token |
| `gm-api` | `admin` | Administrator ID from the session | Path `game_id`, after the scope check |
| `game-worker` | `system` | Worker instance name | From the job row |
| `internal-api` | `service` | Service identity ID | Request `game_id`, after the grant check |

## 5. Third-party callbacks

Calls that a platform makes to us are a separate surface: `/platform-callbacks/v1/<platform>/...`. They come from the public internet, carry no player token and no internal credential, and are authenticated with the platform's own scheme.

### 5.1 What they are for

| Scenario | Trigger | What the server does | Needed in V1 |
|---|---|---|---|
| Rewarded-ad server-side verification | WeChat's ad server calls the developer server when a player qualifies for the reward. WeChat documents this as an optional verification mode. | Verify the request, match it to the `ad_session`, mark the session as server-verified so the claim no longer depends on the client flag alone | Decision needed; it directly reduces ad-reward fraud |
| WeChat message push: customer-service messages | A player opens the customer-service chat or sends a message | Receive the message or event; optionally reply or forward to a support tool | Only if in-game customer service is used |
| WeChat message push: subscription-message events | A player accepts or rejects a subscription; a send succeeds or fails | Record the result so reminders are sent only to players who opted in | Only if subscription messages are used |
| WeChat message push: asynchronous content-safety results | The server submitted an image or audio for checking | Receive the verdict and block or allow the content | Only if players can upload media |
| Virtual-payment delivery and payment events | A player pays for coins or an item | Verify, deduplicate, grant through the economy service, answer within the platform's timeout | No. Payments are out of V1 scope |
| Callbacks of other platforms | Douyin, Alipay, native ad networks | Same pattern through that platform's adapter | No |

The field list, signature algorithm and retry behaviour of the ad verification callback were not retrieved when this document was written. Read the current WeChat page before designing the endpoint: <https://developers.weixin.qq.com/minigame/dev/guide/security/antiadcheat.html>.

### 5.2 Rules

- Verify with the platform's own signature, token or encryption scheme. Internal AK/SK rules never apply.
- Check the timestamp and reject stale requests where the platform provides one.
- Deduplicate by the platform's message or transaction ID through a unique key. Platforms retry.
- Resolve `game_id` from the receiving app (`app_id` in the URL or payload), never from a free parameter.
- Do the work in one transaction through `gamecore`, then return the exact success response the platform expects. Anything slow becomes a background job.
- Apply an IP policy where the platform publishes its address ranges.
- Log the event type and outcome; never log tokens, keys or message bodies that contain personal data.

### 5.3 Where it runs: open decision

| Option | For | Against |
|---|---|---|
| **A. Route group in `game-api`** (assumed by ADR-0005) | No extra process; already public; shares the player-side rate-limit and WAF setup | A callback outage or flood shares capacity with player traffic |
| B. Separate `callback-api` process | Independent scaling and failure domain | A fourth deployed service for very little traffic in V1 |
| C. Not built in V1 | Nothing to operate | Ad rewards rely on the client flag plus limits only |

Nothing has to be built until the first callback is actually needed. If rewarded-ad server-side verification is adopted for V1, option A is the smallest change.

## 6. Checklist for adding an endpoint

1. Which entry does the caller belong to? If the answer is "both players and operators", it is two endpoints.
2. Add the operation to that entry's OpenAPI file first.
3. Name the permission code (GM) or the ownership rule (player).
4. State idempotency: `Idempotency-Key`, or a natural unique key, or read-only.
5. State the transaction boundary and whether an audit row or an outbox event is written in it.
6. Put the rule in `gamecore`; the handler only parses, calls and maps the result.

## 7. Things that look convenient and are not allowed

- A shared handler or middleware "because the logic is the same".
- A `player_id` query parameter on a `game-api` route.
- `gm-api` calling `game-api`, or the worker calling either, over HTTP.
- A GM endpoint that loops over players inside the request.
- An internal endpoint that only wraps a function the caller could reach in-process.
