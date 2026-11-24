# 游戏隔离

- **状态：** 评审草案（2026-11-23）
- **细化：** [ADR-0002](../adr/ADR-0002-game-isolation.md)
- **来源：** [技术设计](../game-platform-technical-design.md)第 4.1、5.4 和 11.1 节

若本文档与 ADR 冲突，以 ADR 为准。标记为**（提案）**的内容未在设计文档或 ADR 中说明，尚待确认。

## 1. 目标

多款游戏共用一套数据库和代码库。任何单个查询缺陷或伪造请求都不能导致读取或修改其他游戏的数据。因此，隔离分层实现，不单独依赖任何一层。

## 2. 隔离层

| # | 层级 | 机制 | 防范问题 |
|---:|---|---|---|
| 1 | 身份解析 | 登录时，服务端将 `(platform, app_id)` 映射到一款游戏。`platform.game_platform_apps` 上有 `UNIQUE (platform, app_id)`。 | 客户端自行选择游戏 |
| 2 | 令牌 | 玩家令牌携带 `game_id`；GM 路径中的 `game_id` 与管理员范围核对；服务的 `game_id` 与 `system.service_game_grants` 核对 | 已认证调用方访问无权访问的游戏 |
| 3 | 应用服务 | `gamecore` 将目标行的 `game_id` 与 `actor.GameID` 比较 | Handler 传入错误范围 |
| 4 | Repository | 所有操作游戏归属数据的方法都接收 `game_id`；SQL 查询始终按其过滤 | 遗漏 `WHERE` 条件 |
| 5 | 数据库约束 | 父表设置 `UNIQUE (game_id, id)`；子表使用复合外键 | 游戏 A 的记录指向游戏 B 的记录 |
| 6 | 数据库角色 | 每个入口使用独立且遵循最小权限原则的运行时角色 | 进程遭入侵后读取不需要的表 |
| 7 | 行级安全策略 | 可选，适用于高风险表 | 查询绕过第 3、4 层 |

## 3. 按游戏隔离的数据表

| 范围 | 数据表 |
|---|---|
| 游戏归属，`game_id NOT NULL` | `auth`、`player`、`game`、`gameplay`、`economy`、`ads`、`ranking` 中的全部表；除全局公告外的 `operation` 表；`analytics` 表；`platform` 子表；`system.service_game_grants` |
| 平台级，不含 `game_id` | `platform.games`；`admin.admin_users`、`roles`、`permissions`、`role_permissions`、`admin_sessions`、`admin_mfa`；`system.idempotency_keys`、`service_identities`、`service_credentials` |
| 两种范围，`game_id` 可为空 | `operation.announcements`（`scope = 'global'`）、`admin.admin_user_roles`（`scope_type = 'platform'`）、`audit.admin_audit_logs`、`audit.service_audit_logs`、`system.outbox_events`、`system.background_jobs` |

可空的 `game_id` 必须搭配明确的区分字段或有文档说明的含义。`NULL` 绝不意外表示“所有游戏”：平台级管理员范围由 `scope_type = 'platform'` 表示。

## 4. Repository 规则

- 访问游戏归属数据的 Repository 方法必须接收 `gameID` 参数，不得提供仅按 ID 查询此类数据的方法。
- 查询玩家归属数据时，按 `(game_id, player_id)` 过滤。
- 游戏归属表之间的联接条件必须包含 `game_id`，以便 PostgreSQL 使用复合索引。
- 游标分页令牌是不透明值，并编码其签发时的 `game_id`；在另一款游戏中重放令牌应被拒绝。**（提案）**

## 5. 数据库以外的隔离

| 资源 | 规则 |
|---|---|
| Redis 键 | 使用环境和游戏作为前缀：`{env}:{game_id}:...`。未认证路由的限流键使用已解析的游戏或 app ID。**（提案）** |
| 对象存储 | 配置负载路径为 `configs/{game_id}/{config_key}/{version}-{checksum}`；每个环境使用独立存储桶。**（提案）** |
| CDN | 公开配置和资源路径包含游戏代码或 ID；不得通过公开路径分发私有数据 |
| 日志和指标 | 每条请求日志都带有 `game_id`；指标使用 `game` 标签，以便单独查看某款游戏的流量 |
| 后台任务 | 任务记录携带 `game_id`；Worker 从任务而非配置中构造 `system` Actor |

## 6. 行级安全策略

V1 推迟 RLS，发布门禁验证应用授权、复合键、独立数据库角色和跨游戏隔离。以下为后续启用 RLS 时的设计。

若某张表启用 RLS：

1. 应用在事务内设置范围：`SET LOCAL app.game_id = '<uuid>'`。
2. 策略将 `game_id` 与 `current_setting('app.game_id')::uuid` 比较。
3. 使用 `SET LOCAL`，避免设置泄露给连接池的下一个使用者。
4. 运行时角色不得为表所有者，也不得拥有 `BYPASSRLS` 权限；否则策略不会生效。
5. 使用实际登录角色连接并测试策略。

若采用 RLS，首批候选表为 `economy.wallets`、`economy.wallet_transactions`、`player.player_saves`、`auth.player_identities`。**（提案）**

`gm-api` 需要访问管理员获授权的多款游戏，因此在 RBAC 检查通过后，按请求将 RLS 范围设置为路径中的 `game_id`，绝不设置为“所有游戏”。

## 7. 环境是另一条隔离轴

开发、预发布和生产环境通过数据库、Redis 实例、存储桶和微信应用相互隔离，而非通过 `game_id` 隔离。除非已匿名化，否则不得将生产数据复制到其他环境。

## 8. 验证隔离的测试

| 测试 | 预期结果 |
|---|---|
| 为游戏 A 的玩家插入钱包，但使用游戏 B 的 `game_id` | 外键约束冲突 |
| 插入的结算所关联的对局属于其他玩家或游戏 | 外键约束冲突 |
| 游戏 A 的玩家令牌调用任意 `game-api` 路由，并篡改请求体 ID | 只能读取或修改游戏 A 的数据；外部 ID 返回 `RESOURCE_NOT_FOUND` |
| 仅获授权访问游戏 A 的管理员请求 `/gm/v1/games/{B}/...` | 返回 `403 AUTH_FORBIDDEN`，且不泄露游戏 B 的信息 |
| 同一微信 OpenID 分别通过两款游戏的应用登录 | 得到两个不同的 `player_id` |
| Worker 执行游戏 A 的任务，但引用游戏 B 的玩家 | 任务步骤失败，不写入任何数据 |
| 使用 `game_api_runtime` 连接并查询 `admin.admin_users` | 权限拒绝 |

以上测试对应 T03（约束和角色）与 T21（请求级测试）。
