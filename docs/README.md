# Architecture documentation

## Overview

| Document | Purpose |
|---|---|
| [Game Platform 技术设计与实施方案](game-platform-technical-design.md) | End-to-end architecture, domain boundaries, security, deployment, roadmap, and delivery plan |

## Normative documents

| Document | Purpose |
|---|---|
| [Architecture and ADRs](architecture/decisions.md) | System boundaries, decisions, security model, and consequences |
| [PostgreSQL DDL](database/schema.sql) | Initial relational schema and integrity constraints |
| [ERD](database/erd.md) | Mermaid entity relationship overview |
| [Player API](openapi/player-api.yaml) | Public game-client contract |
| [GM API](openapi/gm-api.yaml) | Privileged operator contract |
| [Internal API](openapi/internal-api.yaml) | Private service-to-service contract; reserved endpoints |
| [Implementation plan](implementation/roadmap.md) | Delivery phases, gates, and acceptance criteria |

## Baseline

- First client platform: WeChat Mini Games.
- Each game owns an independent player namespace and player account.
- Player API and GM API are independently deployed Go + Gin processes.
- Both APIs call the same in-process Go `gamecore` packages; neither API calls the other over HTTP.
- PostgreSQL is the authoritative store; Redis is a disposable cache/ephemeral coordination layer.
- Platform adapters isolate WeChat-specific login and advertising behavior.
- The internal API contract is private and is not a third public-facing service in the MVP.

## Status and change control

These documents define the proposed initial baseline, not proof of an implemented system. Decisions marked **Accepted** are the design baseline. Any change to service boundaries, identity isolation, data authority, or authorization requires an ADR amendment and review before implementation.

DDL and OpenAPI are versioned artifacts. Apply schema changes through forward-only migrations; do not edit an already-applied migration in place.
