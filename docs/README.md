# 架构文档

基线版本 v2.0（2026-11-23），实施决策于 2026-11-24 补充。

## 概览

| 文档 | 内容 |
|---|---|
| [游戏平台技术设计与实施方案](game-platform-technical-design.md) | 端到端设计：架构、模块、数据库、API、GM 平台、Worker、部署与路线图 |
| [架构概览与 ADR 索引](architecture/decisions.md) | 组件职责、相较 v1.0 基线的变化、V1 决策与发布门禁 |
| [实施路线图](implementation/roadmap.md) | P0–P8 阶段、阶段门禁、Codex 任务 T00–T22、V1 范围 |

## 已接受的决策

| ADR | 决策 |
|---|---|
| [ADR-0001](adr/ADR-0001-modular-monolith.md) | 模块化单体：单一 Go 模块，共用 `gamecore`，入口独立部署 |
| [ADR-0002](adr/ADR-0002-game-isolation.md) | 以 `game_id` 作为隔离键 |
| [ADR-0003](adr/ADR-0003-player-account-model.md) | 每款游戏使用独立账号、微信登录与令牌 |
| [ADR-0004](adr/ADR-0004-data-authority-model.md) | 服务端权威；客户端运行战斗，由服务端结算 |
| [ADR-0005](adr/ADR-0005-api-service-boundaries.md) | 四个入口、三个安全平面及 API 约定 |
| [ADR-0006](adr/ADR-0006-postgresql-schema-design.md) | Schema、约束、角色与迁移 |
| [ADR-0007](adr/ADR-0007-economy-transaction-model.md) | 余额与流水、幂等性及 GM 调账 |
| [ADR-0008](adr/ADR-0008-internal-api-and-worker.md) | Worker 直接调用 `gamecore`；内部 API 预留 |
| [ADR-0009](adr/ADR-0009-async-job-model.md) | 基于 PostgreSQL 的任务与 Outbox |
| [ADR-0010](adr/ADR-0010-v1-decision-baseline.md) | 2026-11-24 确认的 V1 实施决策与发布门禁 |

## 主题文档（评审草案）

这些文档对 ADR 作进一步说明。若主题文档与 ADR 冲突，以 ADR 为准。超出设计文档或 ADR 的内容会在文中标注为 **（提案）**，尚待确认。

### 架构

| 文档 | 内容 |
|---|---|
| [系统架构](architecture/system-architecture.md) | 组件、分层、关键请求流程与技术栈 |
| [服务边界](architecture/service-boundaries.md) | 四个入口、导入规则、Actor 契约与第三方回调 |
| [游戏隔离](architecture/game-isolation.md) | 隔离层级、有/无游戏范围的表、RLS 与隔离测试 |
| [认证与授权](architecture/authentication-and-authorization.md) | 玩家、GM 与服务安全平面、令牌、RBAC 评估与密钥 |
| [数据权威模型](architecture/data-authority-model.md) | 数据归属、结算校验与广告奖励信任级别 |
| [经济系统设计](architecture/economy-design.md) | 钱包、道具、流水、幂等性、GM 调账与对账 |
| [异步任务设计](architecture/async-job-design.md) | 任务状态、领取、租约、重试、Outbox 与任务目录 |
| [部署架构](architecture/deployment-architecture.md) | 拓扑、配置、数据库角色、迁移与环境 |

### 数据库

| 文档 | 内容 |
|---|---|
| [PostgreSQL DDL](database/schema.sql) | 基线结构：13 个 Schema、57 张表 |
| [ERD](database/erd.md) | 实体关系、关键规则及与设计文档的差异 |
| [Schema 设计](database/schema-design.md) | 约定、各 Schema 说明、JSONB 使用及大表 |
| [约束与索引](database/constraints-and-indexes.md) | 由约束保证的业务规则、索引目录与已知缺口 |
| [数据库角色与授权](database/database-roles-and-grants.md) | 角色、授权矩阵、钱包写入路径与验证 |

### API

| 文档 | 内容 |
|---|---|
| [游戏 API 契约](../api/openapi/game-api.yaml) 与[指南](api/game-api.md) | 面向玩家的 API（`/api/v1`） |
| [GM API 契约](../api/openapi/gm-api.yaml) 与[指南](api/gm-api.md) | 面向运营人员的 API（`/gm/v1`） |
| [内部 API 契约](../api/openapi/internal-api.yaml) 与[指南](api/internal-api.md) | 服务间 API（`/internal/v1`）；V1 预留、不部署 |

### 安全

| 文档 | 内容 |
|---|---|
| [威胁模型](security/threat-model.md) | 资产、攻击者、信任边界、威胁缓解与已接受风险 |
| [RBAC 矩阵](security/rbac-matrix.md) | 权限目录、角色矩阵与范围规则 |
| [审计策略](security/audit-policy.md) | 审计范围、记录内容、脱敏、完整性与保留期 |

## 基线

- 首个客户端平台为微信小游戏；其他平台通过平台适配器接入。
- 每款游戏拥有独立的玩家账号命名空间，以 `game_id` 作为隔离键。
- `game-api` 和 `gm-api` 是独立部署的 Go + Gin 进程，各自具有独立的安全平面。
- `game-worker` 是用于异步任务的独立进程。
- 三个进程均调用同一进程内的 `gamecore` 包；入口之间不通过 HTTP 相互调用。
- `internal-api` 仅作预留：保留契约和服务认证抽象，V1 不部署。
- V1 包含完整的 GM 平台：管理员、RBAC、玩家与经济管理、配置中心、邮件、活动、审计和基础运营数据。
- PostgreSQL 是权威数据存储。Redis 用于缓存、限流和排行榜读取加速；S3/OSS + CDN 用于存放配置负载和资源。
- V1 不包含消息代理、Kubernetes、支付或实时战斗服务器。

## 文档维护

玩家端契约使用 `api/openapi/game-api.yaml`。

仓库布局中提及的 `docs/runbooks/` 目录目前不存在；备份与恢复手册属于 T20 交付项。

## 状态与变更管理

这些文档定义的是设计基线，而非已实现的系统。本仓库没有应用代码。DDL 尚未在 PostgreSQL 中执行，OpenAPI 文档尚未通过 lint，Mermaid 图也尚未渲染。

标记为 **已接受** 的决策构成基线。变更服务边界、身份隔离、数据权威或授权机制，必须修订相应 ADR，并在实施前完成评审。主题文档中的 **（提案）** 在对应实施阶段评审。已确认的 V1 决策及发布门禁见 [ADR-0010](adr/ADR-0010-v1-decision-baseline.md)。

DDL 与 OpenAPI 均为版本化交付物。Schema 变更应通过只向前的迁移实施；不得原地修改已应用的迁移。
