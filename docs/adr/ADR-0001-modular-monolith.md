# ADR-0001 — Modular monolith with independently deployed entrypoints

- **Status:** Accepted
- **Date:** 2026-11-23
- **Supersedes:** ADR-001 in `docs/architecture/decisions.md` v1.0
- **Related:** [ADR-0005](ADR-0005-api-service-boundaries.md), [ADR-0008](ADR-0008-internal-api-and-worker.md)

## Context

The platform serves several small games from one backend. The first release targets WeChat Mini Games with a small team. Player traffic and GM operations have different attack surfaces, release cadences and scaling needs, but they act on the same business rules and the same data. Splitting domains into networked microservices now would add distributed transactions, service discovery and operational cost without a measured need.

## Decision

- Build one Go module at the repository root (monorepo, no `go.work`).
- All business rules live once, in the shared `internal/gamecore` packages (domain, application services, repositories).
- Ship several process entrypoints from that module, each with its own image, configuration and lifecycle:

  | Entrypoint | Audience | V1 deployment |
  |---|---|---|
  | `game-api` | Player clients | Deployed |
  | `gm-api` | GM Web | Deployed |
  | `game-worker` | Background jobs | Deployed when asynchronous work exists (it does in V1: batch mail and rewards) |
  | `internal-api` | Trusted services | Reserved; not deployed |

- Entrypoints call `gamecore` in-process. No entrypoint calls another entrypoint over HTTP.
- Handlers, routers, authentication middleware and DTOs are per entrypoint and are not shared. Domain, application services and repositories are shared.
- No Kafka, RocketMQ, service registry, microservice gateway or distributed transactions in V1.
- Start on Docker Compose; keep images and configuration portable to Kubernetes.

## Consequences

- A domain change can require rebuilding and redeploying every entrypoint.
- `gamecore` must not import Gin or any transport type; transport concerns stay in `internal/transport/http/*`.
- Every application-service call carries an explicit `Actor` (see ADR-0005), because the same service is reachable from different security planes.
- A domain is split into its own service only when independent scaling, ownership or isolation is demonstrated, and only through a new ADR.
