# 游戏平台

多游戏后端平台。首个版本面向微信小游戏，同时保留扩展其他平台适配器的能力。

技术栈：Go + Gin、PostgreSQL、Redis、Vue 3（GM 管理后台）、Cocos Creator（游戏客户端）。架构采用模块化单体，共用 `gamecore`，并独立部署 `game-api`、`gm-api` 和 `game-worker` 入口。

本仓库目前仅包含设计基线，尚无应用代码。

请参阅[文档索引](docs/README.md)，了解技术设计、ADR、PostgreSQL 结构、ERD、OpenAPI 契约和实施路线图。
