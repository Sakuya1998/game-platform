# Game Platform

A multi-game backend platform. The first release targets WeChat Mini Games and keeps platform adapters extensible.

Stack: Go + Gin, PostgreSQL, Redis, Vue 3 (GM Web), Cocos Creator (game client). Architecture: a modular monolith with independently deployed entrypoints (`game-api`, `gm-api`, `game-worker`) over one shared `gamecore`.

This repository currently holds the design baseline only; no application code exists yet.

See the [documentation index](docs/README.md) for the technical design, ADRs, PostgreSQL schema, ERD, OpenAPI contracts and the implementation roadmap.
