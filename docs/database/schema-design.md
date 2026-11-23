# Schema 设计说明

- **状态：** 评审草案（2026-11-23）
- **细化：** [ADR-0006](../adr/ADR-0006-postgresql-schema-design.md)
- **来源：** [技术设计](../game-platform-technical-design.md)第 5 节；可执行基线见[数据库结构](schema.sql)

`schema.sql` 是表名和类型的事实来源。本文解释各表的设计原因。标记为**（提案）**的内容未在设计文档或 ADR 中说明，尚待确认。

## 1. 布局

单一数据库 `game_platform`，包含 13 个 Schema、57 张表。不为每款游戏单独建库；各游戏通过 `game_id` 隔离（见[游戏隔离](../architecture/game-isolation.md)）。

| Schema | 表数 | 职责 |
|---|---:|---|
| `platform` | 4 | 游戏、平台应用、设置、环境 |
| `auth` | 3 | 外部身份、玩家会话、登录记录 |
| `player` | 5 | 玩家主体、资料、存档、快照、封禁 |
| `game` | 4 | 配置定义、版本、发布记录、发布项 |
| `gameplay` | 3 | 对局、结算、对局事件 |
| `economy` | 6 | 货币和道具定义、钱包、背包、两类流水 |
| `ads` | 4 | 广告位、会话、领取、每日限额 |
| `operation` | 7 | 公告、邮件、活动、批量奖励任务 |
| `ranking` | 3 | 排行榜、条目、快照 |
| `admin` | 7 | 管理员、角色、权限、会话、MFA |
| `audit` | 2 | GM 审计日志、服务审计日志 |
| `analytics` | 3 | 事件、每日聚合数据 |
| `system` | 6 | 幂等、Outbox、任务、服务身份 |

## 2. 约定

| 主题 | 规则 |
|---|---|
| 主键 | 使用 `uuid`，默认值为 `gen_random_uuid()`。自然键本身就是身份的数据表（`wallets`、`player_items`、`game_settings`、每日统计）直接使用自然键 |
| 游戏范围 | 游戏归属表包含 `game_id uuid NOT NULL`。父表提供 `UNIQUE (game_id, id)`；子表通过复合外键引用 |
| 时间 | 统一使用 `timestamptz`，以 UTC 存储。每张表都有 `created_at`；可变表还包含 `updated_at` |
| 金额和数量 | 使用最小单位的 `bigint`；不使用 `numeric` 或浮点数 |
| 枚举 | 使用带 `CHECK` 列表的 `text`，而非 PostgreSQL `ENUM`，以便通过普通迁移新增值 |
| 自由格式数据 | 仅当结构属于具体游戏或规则引擎时使用 `jsonb`（见第 4 节） |
| 密钥 | 不直接存储。列中保存引用（`credential_ref`、`secret_ref`）或单向哈希（`refresh_token_hash`）。唯一加密列为 `admin_mfa.secret_encrypted` |
| 删除 | 业务记录不硬删除；通过状态列和 `deleted_at` / `revoked_at` 标记生命周期结束。清理任务只删除过期的技术性记录 |
| 命名 | 使用 `snake_case`；表名采用复数；外键按被引用实体命名（`player_id`、`board_id`）；列名不得使用保留字 |
| Actor 列 | 若一条记录可能由多种调用方写入，则包含 `actor_type` / `created_by_type`（取值为 `player`、`admin`、`service`、`system`）和文本类型的 ID |

## 3. 各 Schema 说明

### platform

`games.code` 是供人员和工具使用的简短稳定标识；`games.id` 是其他所有数据引用的键。一个平台应用只能属于一款游戏：`UNIQUE (platform, app_id)` 使登录时可以在不信任客户端的情况下解析游戏。`game_platform_apps.credential_ref` 指向密钥库中的凭据。

`game_environments` 描述一款游戏在各环境中的端点。它不用于分区玩家数据；不同环境使用不同数据库。

### auth 和 player

`player.players` 是玩家主体。外部账号身份保存在 `auth.player_identities` 并关联到玩家；同一游戏中的玩家可绑定多个身份。会保存 `unionid`，但不为其添加约束，因为绝不能据此跨游戏合并玩家。

玩家资料、存档、快照和封禁分表保存，使每类数据拥有独立写入路径和权限：

| 表 | 写入方 |
|---|---|
| `player_profiles` | 玩家 |
| `player_saves` | 玩家（乐观锁）；GM 恢复操作 |
| `player_save_snapshots` | Worker（定时）；`gm-api`（恢复前） |
| `player_bans` | 仅 `gm-api` |

封禁记录具有独立生命周期：开始时间、可选的过期时间和撤销时间。`players.status = 'banned'` 用于快速检查；`player_bans` 保存历史和原因。

登录可能在识别玩家前失败，因此 `auth.login_records.player_id` 允许为空。

### game

```text
game_configs（配置键）
  └─ config_versions（通过校验后不可变；内容内嵌或存于对象存储）
config_releases（不可变的发布事件，按 release_no 排序）
  └─ config_release_items（此发布启用的各配置版本）
```

版本绝不覆盖。发布时创建一条发布记录；回滚时创建另一条发布记录，其发布项指向较早版本，并通过 `rollback_of_release_id` 指明被撤销的发布。某配置当前生效的版本，是包含该配置且 `release_no` 最高的发布项。

`release_no` 使用 identity 列，因为时间戳可能相同，而发布顺序必须明确且唯一。

### gameplay

`game_runs.id` 由服务端生成，客户端通过它提交结算。对局记录保存服务端稍后校验结果所需的信息：关卡、难度、规则版本和服务端 `run_context`。

`run_settlements` 并列保存客户端声明（`result`）与服务端判定（`validation_status`、`rewards`）。`UNIQUE (game_id, run_id)` 防止重复结算。

`run_events` 保存对局的重要事件，包括风险信号。

### economy

详见[经济系统设计](../architecture/economy-design.md)。表结构遵循以下原则：

- `wallets` 使用自然复合主键，每位玩家的每种货币各有一行。
- 流水保存正数 `amount`、`direction` 和 `balance_after`，每条记录均可独立校验。
- 流水引用钱包或背包记录，确保投影记录存在。
- 两种流水表都通过触发器实现只追加。

### ads

`ad_sessions` 记录服务端确认已开始的广告观看；`ad_reward_claims` 记录发放奖励的决定。`ad_daily_limits` 是按玩家、广告位和日期设置的计数表，并在领取事务内更新，以保证并发情况下仍遵守限额。`limit_date` 使用游戏设置的每日重置时区。

### operation

邮件拆分为内容（`mail_messages`）、附件（`mail_attachments`）和玩家投递记录（`player_mail`）。群发邮件只创建一条内容记录，再由 Worker 插入多条投递记录。

`announcements` 可以是全局公告（`scope = 'global'`，不关联游戏），也可以属于单款游戏。

`activities.config` 保存活动任务和奖励表；`activity_claims` 确保每项奖励只领取一次。

`reward_jobs` 面向运营人员保存批处理信息；具体执行状态保存在 `system.background_jobs`。

### ranking

分数存储在 PostgreSQL。条目主键包含 `period_key`，使日榜、周榜和赛季榜在每个周期内都能为每位玩家保存一条记录。快照用于冻结已结束周期的数据。

### admin 和 audit

管理员属于平台级，不包含 `game_id`。范围记录在角色分配上（`admin_user_roles.scope_type`、`game_id`）。

两张审计表都通过触发器和权限设置为只追加。详见[审计策略](../security/audit-policy.md)。

### analytics

`game_events` 保存客户端和服务端上报的原始事件，并通过 `(game_id, event_id)` 去重。每日统计表保存 Worker 生成的聚合结果。此处的数据都不是权威数据，也不得用于发放资产。

### system

`idempotency_keys` 保存请求级重放结果。`outbox_events` 和 `background_jobs` 详见[异步任务设计](../architecture/async-job-design.md)。三个 `service_*` 表为预留的内部 API 准备，V1 中为空。

## 4. JSONB 的使用范围

| 列 | 使用 JSONB 的原因 | 禁止包含 |
|---|---|---|
| `player_saves.save_data`、快照 | 平台不解释的游戏专属状态 | 余额、道具、权益 |
| `config_versions.content` | 由游戏定义并通过 JSON Schema 校验的配置 | — |
| `game_runs.run_context`、`run_settlements.result`、`rewards` | 游戏规则快照和结算声明 | — |
| `ad_placements.reward_rule`、`activities.config`、`leaderboards.ranking_rule` | 各游戏不同的规则定义 | — |
| `mail_messages.target_filter`、任务和 Outbox 的 `payload` | 按目标或任务类型变化的结构 | 密钥 |
| `*_audit_logs.before_data` / `after_data` | 任意实体的脱敏快照 | 密码、令牌、密钥 |
| `daily_*_stats.metrics` | 指标集合会随时间增长 | — |

按值查询、需约束或需求和的字段都应使用独立列。

## 5. 预期增长较快的数据表

| 表 | 增长来源 | 处理方案 |
|---|---|---|
| `analytics.game_events` | 每次客户端事件 | 优先考虑按时间分区和较短保留期；数据量足够时迁至独立存储 |
| `economy.wallet_transactions`、`item_transactions` | 每次资产变更 | 按时间分区；因其属于财务记录，保留期限需通过策略决定 |
| `auth.login_records` | 每次登录 | 按时间分区；按策略确定保留期 |
| `audit.admin_audit_logs`、`service_audit_logs` | 每次 GM 变更 | 长期保留；归档，保留期内绝不删除 |
| `gameplay.game_runs`、`run_settlements`、`run_events` | 每场对局 | 归档旧对局 |
| `operation.player_mail` | 群发邮件 × 玩家数 | 保留期后删除过期及已领取邮件 |
| `system.background_jobs`、`outbox_events`、`idempotency_keys` | 系统操作 | 定时清理任务 |

根据实际测得的数据量决定分区和保留策略，而非提前设定（ADR-0006）。保留期限仍是[决策文档](../architecture/decisions.md)中的待决事项。

## 6. Schema 变更

- `schema.sql` 是经评审的基线。T03 会将其转换为 `/migrations` 下的有序迁移；此后迁移将成为事实来源，`schema.sql` 则重新生成或退役。**（提案：** 迁移建立后退役此文件，以避免出现两个事实来源。）
- 已应用的迁移绝不修改。
- 变更遵循扩展/收缩流程。
- 每张新表都需评审其游戏范围、唯一约束、索引、保留期限和个人数据分类。
