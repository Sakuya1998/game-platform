# 约束与索引

- **状态：** 评审草案（2026-11-23）
- **细化：** [ADR-0002](../adr/ADR-0002-game-isolation.md)、[ADR-0006](../adr/ADR-0006-postgresql-schema-design.md)、[ADR-0007](../adr/ADR-0007-economy-transaction-model.md)
- **来源：** [schema.sql](schema.sql)

本文列出承载业务规则的约束，以及每个索引所服务的查询。内容根据 `schema.sql` 编写；DDL 尚未执行，以下索引尚未通过查询计划验证。标记为**（提案）**的项目待确认。

## 1. 落实业务规则的唯一约束

| 表 | 约束 | 保障规则 |
|---|---|---|
| `platform.games` | `UNIQUE (code)` | 每个游戏代码唯一对应一款游戏 |
| `platform.game_platform_apps` | `UNIQUE (platform, app_id)` | 一个平台应用只属于一款游戏，登录时可据此解析游戏 |
| `platform.game_environments` | `UNIQUE (game_id, environment)` | 每款游戏的每个环境仅有一条记录 |
| `auth.player_identities` | `UNIQUE (game_id, platform, app_id, openid)` | 每种外部身份在每款游戏中只对应一名玩家；并发首次登录安全 |
| `auth.player_sessions` | `UNIQUE (refresh_token_hash)` | 一个 refresh token 只对应一个会话 |
| `player.player_save_snapshots` | `UNIQUE (game_id, player_id, save_version)` | 每个存档版本只有一个快照 |
| `game.game_configs` | `UNIQUE (game_id, config_key)` | 每个配置键只对应一份配置 |
| `game.config_versions` | `UNIQUE (game_id, config_id, version)` | 版本号不可复用 |
| `game.config_release_items` | `PRIMARY KEY (game_id, release_id, config_id)` | 一次发布中的每份配置只指定一个版本 |
| `gameplay.run_settlements` | `UNIQUE (game_id, run_id)` | 每场对局最多结算一次 |
| `economy.wallets` | `PRIMARY KEY (game_id, player_id, currency_code)` | 每位玩家的每种货币只有一个钱包 |
| `economy.wallet_transactions` | `UNIQUE (game_id, player_id, currency_code, source_type, source_id, transaction_type)` | 同一业务来源只变更同一余额一次 |
| `economy.player_items` | `PRIMARY KEY (game_id, player_id, item_id)` | 每位玩家的每种道具只有一条背包记录 |
| `economy.item_transactions` | `UNIQUE (game_id, player_id, item_id, source_type, source_id, transaction_type)` | 道具也遵循相同的单次变更规则 |
| `ads.ad_placements` | `UNIQUE (game_id, placement_code)` | 每个代码只对应一个广告位 |
| `ads.ad_reward_claims` | `UNIQUE (game_id, session_id)` | 每个广告会话最多领取一次 |
| `ads.ad_daily_limits` | `PRIMARY KEY (game_id, player_id, placement_id, limit_date)` | 每位玩家、每个广告位每天只有一个计数器 |
| `operation.mail_attachments` | `UNIQUE (game_id, mail_id, reward_type, reward_id)` | 同一邮件中的资产不重复 |
| `operation.player_mail` | `UNIQUE (game_id, mail_id, player_id)` | 每封邮件向每位玩家仅投递一次 |
| `operation.activities` | `UNIQUE (game_id, activity_code)` | 每个活动代码仅对应一个活动 |
| `operation.activity_claims` | `UNIQUE (game_id, activity_id, player_id, reward_id)` | 每位玩家在每个活动中只领取每项奖励一次 |
| `ranking.leaderboards` | `UNIQUE (game_id, board_code)` | 每个排行榜代码只对应一个排行榜 |
| `ranking.leaderboard_entries` | `PRIMARY KEY (game_id, board_id, period_key, player_id)` | 每位玩家每个周期只有一个分数 |
| `ranking.leaderboard_snapshots` | `UNIQUE (game_id, board_id, period_key)` | 每个周期只有一个快照 |
| `admin.admin_users` | `UNIQUE (username)`、`UNIQUE (email)` | 登录名和邮箱唯一 |
| `admin.admin_user_roles` | 按范围类型设置部分唯一索引 | 同一角色在每款游戏内及平台级范围均只能分配一次 |
| `analytics.game_events` | `UNIQUE (game_id, event_id)` | 事件上传幂等 |
| `system.idempotency_keys` | `PRIMARY KEY (scope, idempotency_key)` | 每个范围和键只保存一个结果 |
| `system.background_jobs` | `(job_type, dedupe_key)` 部分唯一索引 | 同一调度任务不重复入队 |

## 2. 复合外键

游戏归属表之间的每项引用都包含 `game_id`，以防子表指向其他游戏的父表。以下复合外键还约束了第二个关联字段。

| 子表 | 引用目标 | 额外保障 |
|---|---|---|
| `auth.player_identities (game_id, platform, app_id)` | `platform.game_platform_apps` | 身份只能绑定到该游戏已注册的平台应用 |
| `auth.player_sessions (game_id, player_id, rotated_from)` | `auth.player_sessions (game_id, player_id, id)` | 令牌轮换链始终属于同一玩家 |
| `game.config_release_items (game_id, config_id, version_id)` | `game.config_versions (game_id, config_id, id)` | 发布项所引用的版本必须属于其指定配置 |
| `gameplay.run_settlements (game_id, run_id, player_id)` | `gameplay.game_runs (game_id, id, player_id)` | 结算必须属于对局自己的玩家 |
| `ads.ad_reward_claims (game_id, session_id, player_id)` | `ads.ad_sessions (game_id, id, player_id)` | 领取记录必须属于会话自己的玩家 |
| `economy.wallet_transactions (game_id, player_id, currency_code)` | `economy.wallets` | 每条钱包流水都有对应钱包 |
| `economy.item_transactions (game_id, player_id, item_id)` | `economy.player_items` | 每条道具流水都有对应背包记录 |
| `economy.wallets (game_id, currency_code)` | `economy.currency_definitions` | 钱包只能使用已定义的货币 |
| `economy.player_items (game_id, item_id)` | `economy.item_definitions` | 背包只能持有已定义的道具 |

含可空字段的外键（`login_records.player_id`、`game_events.player_id`、`reward_jobs.mail_id`、`config_releases.rollback_of_release_id`）采用 PostgreSQL 默认的 `MATCH SIMPLE`：只有所有字段均非空时才校验引用。

## 3. 检查约束

| 类型 | 示例 |
|---|---|
| 资产非负 | `wallets.balance >= 0`、`player_items.quantity >= 0`、`balance_after >= 0`、`quantity_after >= 0` |
| 金额为正 | `wallet_transactions.amount > 0`、`item_transactions.quantity > 0`、`mail_attachments.quantity > 0` |
| 版本为正 | `save_version > 0`、`schema_version > 0`、`config_versions.version > 0` |
| 时间窗口 | 活动和公告的 `end_at > start_at`；`game_runs.expires_at > started_at`；封禁的 `expires_at > starts_at` |
| 明确范围 | `admin_user_roles`：平台范围不带游戏，游戏范围必须指定游戏。`announcements`：全局范围不带游戏，游戏范围必须指定游戏 |
| 必须有负载 | `config_versions`：`content` 和 `object_key` 至少提供一项 |
| 凭据结构 | `service_credentials`：HMAC 必须提供 `access_key_id` 和 `secret_ref`；mTLS 必须提供 `credential_hash` |
| 回滚关联 | `config_releases`：类型为 `rollback` 时必须指定被撤销的发布记录 |
| 明确限额 | `ad_placements.daily_limit > 0`、`session_ttl_seconds > 0` |
| 状态取值 | 每个 `status`、`direction`、`result`、`actor_type` 列都限定允许值 |
| 格式 | `games.code` 符合 `^[a-z][a-z0-9_-]{1,62}$` |

## 4. 只追加数据表

`economy.wallet_transactions`、`economy.item_transactions`、`audit.admin_audit_logs` 和 `audit.service_audit_logs` 均设置 `BEFORE UPDATE OR DELETE` 触发器并调用 `system.reject_mutation()`。运行时角色也仅拥有这些表的 `INSERT` 和 `SELECT` 权限。触发器无法阻止 `TRUNCATE`，也无法阻止有权限的角色禁用触发器，因此数据表必须由 `NOLOGIN` 角色拥有。

## 5. 索引及其服务的查询

主键和唯一约束会自动建立索引，见第 1 节。显式索引如下：

| 索引 | 列 | 服务的查询 |
|---|---|---|
| `players_game_created_idx` | `(game_id, created_at DESC)` | GM 玩家列表，按最新创建时间排序 |
| `player_profiles_nickname_idx` | `(game_id, nickname)` | GM 按昵称精确匹配或前缀搜索 |
| `player_bans_player_idx` | `(game_id, player_id, starts_at DESC)` | 查看玩家封禁历史 |
| `player_bans_active_idx` | `(game_id, player_id) WHERE revoked_at IS NULL` | 检查玩家当前是否被封禁 |
| `player_identities_player_idx` | `(game_id, player_id)` | 查询玩家绑定的身份 |
| `player_sessions_player_idx` | `(game_id, player_id)` | 撤销玩家的所有会话 |
| `player_sessions_expiry_idx` | `(expires_at) WHERE revoked_at IS NULL` | 清理过期会话 |
| `login_records_player_idx` | `(game_id, player_id, created_at DESC)` | 查看玩家登录历史 |
| `login_records_time_idx` | `(game_id, created_at DESC)` | 统计一段时间内的登录成功率 |
| `config_releases_game_idx` | `(game_id, release_no DESC)` | 查看游戏的最新发布 |
| `config_release_items_config_idx` | `(game_id, config_id)` | 查看单项配置的发布历史 |
| `game_runs_player_idx` | `(game_id, player_id, started_at DESC)` | 查看玩家近期对局；检测短时间通关 |
| `run_settlements_player_idx` | `(game_id, player_id, settled_at DESC)` | 按玩家计算每日奖励上限 |
| `run_events_run_idx` | `(game_id, run_id, created_at)` | 查询对局事件 |
| `wallet_transactions_player_idx` | `(game_id, player_id, created_at DESC)` | 分页查看玩家钱包流水 |
| `wallet_transactions_source_idx` | `(game_id, source_type, source_id)` | 查询某业务事件发放的全部资产 |
| `item_transactions_player_idx`、`item_transactions_source_idx` | 同类结构 | 查询道具流水 |
| `ad_sessions_player_idx` | `(game_id, player_id, created_at DESC)` | 查看玩家近期广告会话 |
| `announcements_game_window_idx` | `(game_id, start_at, end_at) WHERE status = 'published'` | 查询当前可见公告 |
| `player_mail_inbox_idx` | `(game_id, player_id, created_at DESC) WHERE deleted_at IS NULL` | 查询玩家收件箱 |
| `reward_jobs_game_idx` | `(game_id, created_at DESC)` | 查询某游戏的批处理任务 |
| `leaderboard_entries_rank_idx` | `(game_id, board_id, period_key, score DESC, updated_at)` | 查询排行榜前 N 名；并列时较早更新者优先 |
| `admin_sessions_admin_idx`、`admin_sessions_expiry_idx` | 按管理员；按过期时间 | 查询会话列表并清理过期会话 |
| `admin_audit_logs_game_time_idx`、`..._actor_time_idx`、`..._target_idx` | 按游戏和时间；按操作员和时间；按目标 | 支持三类审计查询 |
| `service_audit_logs_service_time_idx`、`..._game_time_idx` | 按服务和时间；按游戏和时间 | 查询服务审计日志 |
| `game_events_type_time_idx` | `(game_id, event_type, occurred_at DESC)` | 聚合事件 |
| `idempotency_keys_expiry_idx` | `(expires_at)` | 清理过期幂等键 |
| `outbox_pending_idx` | `(next_attempt_at, occurred_at) WHERE published_at IS NULL` | 轮询 Outbox |
| `background_jobs_claim_idx` | `(priority DESC, run_at) WHERE status IN ('pending','retrying')` | 领取任务 |
| `background_jobs_lease_idx` | `(lease_expires_at) WHERE status = 'running'` | 重新领取租约过期的任务 |
| `service_credentials_service_idx` | `(service_id)` | 查询服务凭据 |

## 6. 已知缺口

以下 API 契约中的查询无法由基线索引良好支持。新增索引前，需使用真实数据通过 `EXPLAIN` 确认。

| 查询 | 缺口 | 备选方案 |
|---|---|---|
| `GET /gm/v1/games/{game_id}/transactions`：不指定玩家，按 `currency` 或 `transaction_type` 过滤 | 目前仅有按玩家和来源的索引 | `(game_id, created_at DESC)`；必要时将过滤列置于前面 |
| GM 按昵称子串搜索玩家 | B-tree 仅支持前缀搜索 | 如确需子串搜索，使用 `pg_trgm` GIN 索引 |
| GM 跨平台应用按 `openid` 搜索玩家 | 唯一索引前缀为 `platform, app_id` | `(game_id, openid)` |
| 大型排行榜中查询玩家自己的名次 | 统计高于某分数的行数需要范围扫描 | 使用 Redis 有序集合读取模型；设计已允许此方式 |
| 过期广告会话 | `expires_at` 上无索引 | 对 `(expires_at) WHERE status = 'created'` 建立部分索引 |
| 过期对局 | `expires_at` 上无索引 | 对 `(expires_at) WHERE status = 'started'` 建立部分索引 |
| `bootstrap` 中的未读邮件数 | 收件箱索引未覆盖 `read_at` | 测量后增加部分索引或计数器 |

## 7. 验证方式

T03 将增加集成测试，尝试违反第 1–4 节的规则，并验证数据库会拒绝重复结算、重复领取、跨游戏引用、负余额，以及流水的更新和删除。索引选择在 T22 负载测试中验证。
