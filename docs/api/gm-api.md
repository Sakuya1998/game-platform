# GM API 指南

- **状态：** 评审草案（2026-11-23）
- **契约：** [`api/openapi/gm-api.yaml`](../../api/openapi/gm-api.yaml) 是事实来源。本指南解释 YAML 无法表达的行为；若两者不一致，应修正本指南。
- **相关：** [ADR-0005](../adr/ADR-0005-api-service-boundaries.md)、[RBAC 矩阵](../security/rbac-matrix.md)、[审计策略](../security/audit-policy.md)

标记为**（提案）**的内容未在设计文档或 ADR 中说明，尚待确认。

## 1. 基本信息

| 项目 | 值 |
|---|---|
| 服务入口 | `gm-api` |
| 基础 URL | `https://gm-api.example.com/gm/v1` |
| 调用方 | 仅 `gm-web` |
| 认证 | 完成 MFA 后签发的管理员 access token |
| 授权 | 权限代码 + 游戏范围，默认拒绝 |
| 格式 | 与游戏 API 使用相同的响应信封、字段风格和错误码 |

GM 安全平面与玩家安全平面相互隔离。玩家令牌在此处会被拒绝；管理员令牌在 `game-api` 也会被拒绝。

## 2. 登录

1. 使用用户名和密码调用 `POST /auth/login`，返回 `challenge_token`。此步骤不会签发 access token。
2. 使用 challenge token 和验证码调用 `POST /auth/mfa/verify`，返回 access token 和 refresh token。
3. 调用 `POST /auth/refresh` 轮换 refresh token。

首次登录需要注册 MFA 的管理员先用登录挑战请求 `POST /auth/mfa/enrollment`，再用注册令牌及验证码请求 `POST /auth/mfa/enrollment/confirm`。确认后才签发会话。调用 `POST /auth/logout` 撤销当前会话。刷新会话最长 7 天，轮换不延长此上限。

## 3. 业务变更操作的通用规则

| 规则 | 说明 |
|---|---|
| 权限 | 必须对路径中的 `game_id`（或平台级范围）拥有该操作的 `x-required-permission` 权限 |
| 范围 | 管理员无权访问的 `game_id` 返回 `403 AUTH_FORBIDDEN`，且不泄露该游戏是否存在 |
| 幂等性 | 必须携带 `Idempotency-Key`；重复请求返回已存储结果 |
| 原因 | 高风险操作必须提供 `reason`；`ticket_id` 可选 |
| 审计 | 与变更在同一事务中写入一条 `audit.admin_audit_logs` 记录 |
| 批量操作 | 涉及大量玩家时返回 `202` 和任务引用 |

## 4. 操作

“Audit”列出写入审计日志的 `action`；“风险”表示 `gm-web` 需要二次确认。

### 游戏

| 操作 | 权限 | 范围 | 审计 | 风险 |
|---|---|---|---|---|
| `GET /games` | `game.read` | 仅限管理员获授权的游戏 | — | — |
| `POST /games` | `game.manage` | 平台 | `game.manage` | — |

请求中的 `credential_ref` 是密钥库引用。该 API 绝不接收或返回 AppSecret 本身。

### 玩家

| 操作 | 权限 | 审计 | 风险 |
|---|---|---|---|
| `GET /games/{game_id}/players` | `player.read` | — | — |
| `GET /games/{game_id}/players/{player_id}` | `player.read` | — | — |
| `POST .../players/{player_id}/ban` | `player.ban` | `player.ban` | 是 |
| `POST .../players/{player_id}/unban` | `player.unban` | `player.unban` | — |
| `POST .../players/{player_id}/save/restore` | `player.save.restore` | `player.save.restore` | 是 |

封禁操作会在同一事务中插入 `player_bans` 记录、更新玩家状态并撤销玩家会话。恢复存档时先对当前存档创建快照，再替换存档并递增 `save_version`。恢复操作不会修改钱包或道具。

### 经济系统

| 操作 | 权限 | 审计 | 风险 |
|---|---|---|---|
| `GET .../players/{player_id}/wallets` | `economy.read` | — | — |
| `POST .../players/{player_id}/wallet-adjustments` | 正数需 `economy.grant`；负数需 `economy.deduct` | `economy.grant` 或 `economy.deduct` | 是 |
| `GET /games/{game_id}/transactions` | `economy.read` | — | — |

调账传入变更量（`amount`），绝不传入目标余额。流水和审计记录（含变更前后余额）需一并提交。若扣款会导致余额为负，返回 `409 INSUFFICIENT_BALANCE`。

`POST .../players/{player_id}/item-adjustments` 使用 `item_id` 和带符号的 `amount`，按方向检查发放或扣除权限。`POST /games/{game_id}/reward-jobs` 需要 `economy.grant`，返回 `202` 和后台任务 ID。两项操作均须二次确认，提供原因并记录同事务审计。

### 配置

| 操作 | 权限 | 审计 | 风险 |
|---|---|---|---|
| `GET /games/{game_id}/configs` | `config.read` | — | — |
| `POST /games/{game_id}/configs` | `config.edit` | `config.edit` | — |
| `POST .../configs/{config_id}/versions` | `config.edit` | `config.edit` | — |
| `POST .../configs/{config_id}/validate` | `config.edit` | `config.edit` | — |
| `POST .../configs/{config_id}/publish` | `config.publish` | `config.publish` | 是 |
| `POST .../configs/{config_id}/rollback` | `config.publish` | `config.publish` | 是 |

生命周期为：草稿、校验、发布、启用、回滚。只有 `validated` 版本可以发布。发布和回滚都会创建新版本，不覆盖旧版本。发布时还会写入 Outbox 事件，以触发缓存和 CDN 刷新。

列表和创建版本操作沿用契约 1.0。设计表格未列出它们，但若没有创建版本的方式，配置生命周期就无法完成。

### 邮件、活动、公告与排行榜

| 操作 | 权限 | 审计 | 风险 |
|---|---|---|---|
| `POST /games/{game_id}/mails` | `mail.create` | `mail.create` | — |
| `POST .../mails/{mail_id}/send` | `mail.send` | `mail.send` | 是 |
| `POST /games/{game_id}/activities` | `activity.manage` | `activity.manage` | — |
| `POST /games/{game_id}/announcements` | `announcement.manage` | `announcement.manage` | — |
| `GET /games/{game_id}/leaderboards` | `ranking.read` | — | — |

`send` 会创建奖励任务和后台任务，并返回 `202`。邮件投递由 `game-worker` 执行，并对每位玩家保证幂等。

活动和公告支持分页列表、草稿编辑、发布及停用。创建与重建排行榜需要 `ranking.manage`，重建返回 `202`。通过 `/games/{game_id}/jobs` 分页查询 GM 发起的任务，使用 `background_job_id` 读取单个任务。取消和重试使用 `/jobs/{job_id}/cancel` 与 `/jobs/{job_id}/retry`，需要 `job.manage`、原因和二次确认。取消仅接受 `pending` 或 `retrying`，重试仅接受 `failed`，并保留已完成步骤的幂等键。

### 管理员、角色、审计与分析

| 操作 | 权限 | 范围 | 审计 | 风险 |
|---|---|---|---|---|
| `GET /admins` | `admin.read` | 平台 | — | — |
| `POST /admins` | `admin.manage` | 平台 | `admin.manage` | 是 |
| `GET /roles` | `admin.read` | 平台 | — | — |
| `PUT /roles/{role_id}/permissions` | `rbac.manage` | 平台 | `rbac.manage` | 是 |
| `GET /audit-logs` | `audit.read` | 限定管理员获授权的游戏；平台记录需平台级权限 | — | — |
| `GET /analytics/overview` | `analytics.read` | `game_id` 查询参数 | — | — |

系统绝不返回密码。新管理员在首次登录时设置密码并注册 MFA。

## 5. `gm-web` 必须实现的行为

- 对所有标记为“风险”的操作进行二次确认。
- 每次用户操作生成一个 `Idempotency-Key`；请求重试时复用该键。
- 隐藏管理员无权使用的菜单项，但仍需处理服务端返回的 `403`；授权以服务端判断为准。
- 批量操作显示任务引用并轮询任务状态，不要等待原始请求完成。
- 使用从 OpenAPI 文件生成的 TypeScript 客户端；不要手写请求类型。

## 6. 本 API 永不提供的能力

- 直接设置钱包余额的端点。
- 在请求内执行批处理的端点。
- 直接访问数据库或执行任意查询。
- 允许使用玩家令牌访问的路由。
