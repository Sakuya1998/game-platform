# Internal API guide

- **Status:** Draft for review (2026-11-23). **The service is reserved and not deployed in V1.**
- **Contract:** [`api/openapi/internal-api.yaml`](../../api/openapi/internal-api.yaml) is the source of truth.
- **Related:** [ADR-0008](../adr/ADR-0008-internal-api-and-worker.md), [async-job-design.md](../architecture/async-job-design.md), [authentication-and-authorization.md](../architecture/authentication-and-authorization.md)

Items marked **(proposal)** are not stated in the design document or an ADR and need confirmation.

## 1. What it is and is not

| It is | It is not |
|---|---|
| The entry for machine-to-machine calls into platform business logic | A second GM API |
| A contract kept ready so it can be enabled without changing `gamecore` | A third copy of business logic |
| Reachable from the private network only | The way `game-worker` talks to `gamecore` in V1 |
| | The place for third-party platform callbacks |

In V1, `game-worker` is part of the same Go module and calls `gamecore` in-process. Routing those calls through HTTP would add a network hop and a failure mode for no gain.

## 2. When to deploy it

Deploy `internal-api` when one of these becomes true:

- A worker or scheduler is built outside this module or in another language.
- Another internal system (data pipeline, operations tooling, a second backend) needs to trigger platform operations.
- Job execution must be isolated in a different network zone from the database.

Until then V1 keeps three things: the directory `services/internal-api`, the `internal/security/serviceauth` abstraction, and the contract.

## 3. Operations in the contract

| Group | Operation | Permission code | Purpose |
|---|---|---|---|
| Jobs | `POST /internal/v1/jobs/{job_id}/claim` | `job.execute` | Take a lease on a pending job |
| Jobs | `POST /internal/v1/jobs/{job_id}/heartbeat` | `job.execute` | Extend the lease |
| Jobs | `POST /internal/v1/jobs/{job_id}/complete` | `job.execute` | Mark success |
| Jobs | `POST /internal/v1/jobs/{job_id}/fail` | `job.execute` | Report failure; the server chooses retry or fail |
| Mail | `POST /internal/v1/mail-deliveries/execute` | `mail.deliver` | Deliver one batch of a mail |
| Rewards | `POST /internal/v1/reward-jobs/execute` | `reward.execute` | Grant one batch of a reward job |
| Analytics | `POST /internal/v1/events/batch` | `event.write` | Write events from a trusted producer |
| Config | `POST /internal/v1/config-releases/notify` | `config.notify` | Request cache and CDN refresh for a release |
| Maintenance | `POST /internal/v1/maintenance/tasks` | `maintenance.run` | Enqueue an allowlisted maintenance task |

The permission codes are service permissions stored in `system.service_game_grants`. They are a separate vocabulary from the GM permission codes in `admin.permissions`; the names were chosen for this contract and are a **proposal**.

Two properties keep this from turning into a GM API:

- A caller never supplies the reward. `reward-jobs/execute` takes a reward job ID and player IDs; what is granted was fixed by the operator who created the job.
- `maintenance/tasks` accepts only the listed task types.

The contract takes a job ID for `claim`. A polling worker also needs a way to ask for "the next job of types I handle"; that operation is not in the design table and is an open point for the day the service is built.

## 4. Requirements when deployed

| Requirement | Mechanism |
|---|---|
| Private network only | Listener on the internal network; no route from the public edge; firewall or security group rules |
| Independent service identity | `system.service_identities` |
| Authentication | HMAC AK/SK signature (`X-Access-Key`, `X-Signature`) or mTLS |
| Replay protection | `X-Timestamp` within the allowed skew and a single-use `X-Nonce` |
| Authorization per service | Operation permission code checked against the caller's grants |
| Game scope | The request `game_id` must match a row in `system.service_game_grants` |
| Idempotency | `Idempotency-Key` on every mutation |
| Audit | One `audit.service_audit_logs` row per call, including denied ones |
| Rate limiting | Per service identity |

The private network is defence in depth. It does not replace authentication.

### HMAC signing (proposal)

The contract says the request is signed with HMAC-SHA256 over method, path, query, timestamp, nonce and body hash. The exact canonical string is fixed when the service is first built. A workable form:

```text
string_to_sign = METHOD + "\n" + PATH + "\n" + CANONICAL_QUERY + "\n"
               + X-Timestamp + "\n" + X-Nonce + "\n" + hex(sha256(body))
X-Signature    = hex(hmac_sha256(secret, string_to_sign))
```

Allowed clock skew: 5 minutes. Nonces are remembered for the skew window in Redis; if Redis is unavailable, requests are rejected rather than accepted unchecked.

The secret is read from the secret manager through `service_credentials.secret_ref`. It cannot be stored as a one-way hash, because the server must recompute the signature.

## 5. Actor

A verified call becomes an `Actor` with `Type = "service"`, `ID` = the service identity, `Service` = its code and `GameID` = the granted game. `gamecore` treats it like any other caller: the same services, the same checks, the same ledger and audit columns.

## 6. Enabling checklist

- [ ] Re-read and re-lint the contract; it may have drifted while unused.
- [ ] Add the "next job" operation if a polling worker needs it.
- [ ] Fix the canonical signing string and publish a client helper.
- [ ] Create the `internal_api_runtime` database role and its grants.
- [ ] Create service identities, credentials and game grants through a reviewed process.
- [ ] Confirm from outside the private network that no `/internal/` route answers.
- [ ] Add tests for a bad signature, a stale timestamp, a replayed nonce, a missing grant and a wrong game.
- [ ] Add dashboards and alerts for denied calls.
- [ ] Record the decision in an amendment to ADR-0008.

## 7. Third-party callbacks

Calls from WeChat or ad platforms are not internal calls. They arrive from the public internet, use the platform's own signature scheme, and live under `/platform-callbacks/v1`. See [service-boundaries.md](../architecture/service-boundaries.md#5-third-party-callbacks).
