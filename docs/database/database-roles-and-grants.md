# 数据库角色与授权

- **状态：** 评审草案（2026-11-23）。第 3 节授权矩阵为**提案**：设计明确了原则（角色分离、最小权限、不得使用超级用户），但未规定逐表权限。
- **细化：** [ADR-0002](../adr/ADR-0002-game-isolation.md)、[ADR-0006](../adr/ADR-0006-postgresql-schema-design.md)
- **来源：** [技术设计](../game-platform-technical-design.md)第 5.4 节

本文中的配置尚未应用到任何数据库。T03 将交付创建角色和授权的迁移，以及以各角色连接数据库的测试。

## 1. 为什么重要

应用层 RBAC 决定管理员可以执行哪些操作。若 `gm-api` 使用一个能写入所有表的账号连接数据库，`gm-api` 中的缺陷或进程被攻破就能绕过全部应用层检查。即使应用代码出错，数据库权限仍是最后一道防线。

## 2. 角色

| 角色 | 可登录 | 使用方 | 用途 |
|---|---|---|---|
| `game_platform_owner` | 否 | 运行时无人使用 | 拥有 Schema、数据表和函数 |
| `game_migrator` | 是 | 仅迁移任务 | 属于所有者角色；执行 DDL |
| `game_api_runtime` | 是 | `game-api` | 玩家平面数据访问 |
| `gm_api_runtime` | 是 | `gm-api` | GM 平面数据访问 |
| `game_worker_runtime` | 是 | `game-worker` | 任务、批处理和聚合 |
| `internal_api_runtime` | 是 | `internal-api` | 预留；服务部署前不创建 |

所有运行时角色均不得为超级用户或对象所有者，不得拥有 `CREATEDB`、`CREATEROLE`、`BYPASSRLS` 或 DDL 权限；应限制连接数，且只有对应进程可以获得其凭据。

## 3. 授权矩阵（提案）

图例：**R** = `SELECT`；**I** = `INSERT`；**U** = `UPDATE`；**D** = `DELETE`；**—** = 无权限；若整个 Schema 为“—”，还包括无 `USAGE` 权限。

| Schema.数据表 | `game_api_runtime` | `gm_api_runtime` | `game_worker_runtime` |
|---|---|---|---|
| **platform**.games、game_platform_apps、game_settings、game_environments | R | R I U | R |
| **auth**.player_identities | R I U | R | R |
| auth.player_sessions | R I U | R U（封禁时撤销） | R D（过期清理） |
| auth.login_records | I | R | R D（保留期清理） |
| **player**.players | R I U | R U（状态） | R |
| player.player_profiles | R I U | R | R |
| player.player_saves | R I U | R U（恢复） | R |
| player.player_save_snapshots | — | R I | R I D（保留期清理） |
| player.player_bans | R | R I U | R |
| **game**.game_configs、config_versions | R | R I U | R |
| game.config_releases、config_release_items | R | R I | R |
| **gameplay**.game_runs | R I U | R | R U（过期处理） |
| gameplay.run_settlements | R I | R | R |
| gameplay.run_events | R I | R | R I |
| **economy**.currency_definitions、item_definitions | R | R I U | R |
| economy.wallets、player_items | R I U | R I U | R I U |
| economy.wallet_transactions、item_transactions | R I | R I | R I |
| **ads**.ad_placements | R | R I U | R |
| ads.ad_sessions | R I U | R | R U（过期处理） |
| ads.ad_reward_claims | R I | R | R |
| ads.ad_daily_limits | R I U | R | R D（保留期清理） |
| **operation**.announcements | R | R I U | R |
| operation.mail_messages | R | R I U | R U（状态） |
| operation.mail_attachments | R | R I | R |
| operation.player_mail | R U（已读、领取、删除标记） | R | R I D（过期清理） |
| operation.activities | R | R I U | R U（结束状态） |
| operation.activity_claims | R I | R | R |
| operation.reward_jobs | — | R I U | R U |
| **ranking**.leaderboards | R | R I U | R |
| ranking.leaderboard_entries | R I U | R | R I U D |
| ranking.leaderboard_snapshots | R | R | R I |
| **admin**.* | — | R I U | — |
| **audit**.admin_audit_logs | — | R I | — |
| audit.service_audit_logs | — | R | — |
| **analytics**.game_events | I | R | R D（保留期清理） |
| analytics.daily_player_stats、daily_game_stats | — | R | R I U |
| **system**.idempotency_keys | R I U | R I U | R D（过期清理） |
| system.outbox_events | I | I | R U D |
| system.background_jobs | I | R I U（取消、重试） | R U D |
| system.service_identities、service_credentials、service_game_grants | — | — | — |

以下授权是刻意设计的：

- `game_api_runtime` 完全无权访问 `admin` 和 `audit` Schema。
- 任何角色都不能 `UPDATE` 或 `DELETE` 资产流水和审计日志；任何角色都没有 `TRUNCATE` 权限。
- `gm_api_runtime` 不能写入对局、结算、广告领取或活动领取记录：GM 通过调账（写入流水）变更资产。
- `game_worker_runtime` 不能读取管理员凭据或写入 GM 审计记录。
- 在 `internal-api` 部署前，服务身份表由迁移和运维管理。

本矩阵根据 API 契约和任务目录制定，尚未通过运行代码验证。`RETURNING` 和 `ON CONFLICT` 等 SQL 写法可能还需要 `SELECT` 权限；若 Repository 语句需要的权限未列出，应在 T03 中同步更新本文档和迁移。

## 4. 钱包写入路径

矩阵中 `economy.wallets` 的 `UPDATE` 权限比其用途更宽：三个运行时角色都可能在未写流水的情况下修改余额。可通过以下方式收紧：

| 选项 | 做法 | 成本 |
|---|---|---|
| A. Repository 规范 + 对账 | 仅由经济 Repository 执行语句；通过[经济系统设计](../architecture/economy-design.md)中的对账任务发现余额与流水不符 | 无需新增数据库对象；只能检测，不能阻止 |
| B. `SECURITY DEFINER` 函数 | 撤销所有运行时角色对 `wallets` 和 `player_items` 的 `UPDATE` 权限；授予它们执行由所有者角色拥有的函数的权限，由函数锁定、校验、写入流水并更新余额 | 在数据库层阻止违规；部分业务逻辑转为 PL/pgSQL；函数需固定 `search_path` 并独立测试 |

ADR-0006 规定，在授予广泛写权限前评估该方案。开发初期可采用选项 A；生产前必须在 A 与 B 中作出选择，并记录在 ADR-0007 中。

## 5. 迁移示例

```sql
-- 密码来自密钥管理器，绝不写入迁移文件
CREATE ROLE game_platform_owner NOLOGIN;
CREATE ROLE game_migrator       LOGIN IN ROLE game_platform_owner;
CREATE ROLE game_api_runtime    LOGIN CONNECTION LIMIT 100;
CREATE ROLE gm_api_runtime      LOGIN CONNECTION LIMIT 20;
CREATE ROLE game_worker_runtime LOGIN CONNECTION LIMIT 20;

-- 默认不开放任何权限
REVOKE ALL ON DATABASE game_platform FROM PUBLIC;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT CONNECT ON DATABASE game_platform
    TO game_migrator, game_api_runtime, gm_api_runtime, game_worker_runtime;

-- 仅对至少拥有一项表权限的角色授予 Schema USAGE
GRANT USAGE ON SCHEMA economy TO game_api_runtime, gm_api_runtime, game_worker_runtime;

-- 每张表严格按照授权矩阵授予
GRANT SELECT, INSERT, UPDATE ON economy.wallets, economy.player_items
    TO game_api_runtime, gm_api_runtime, game_worker_runtime;
GRANT SELECT, INSERT ON economy.wallet_transactions, economy.item_transactions
    TO game_api_runtime, gm_api_runtime, game_worker_runtime;

-- admin Schema 仅供 gm-api 使用
GRANT USAGE ON SCHEMA admin TO gm_api_runtime;
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA admin TO gm_api_runtime;
```

连接数限制仅为占位值，需根据连接池配置调整。不得使用 `ALTER DEFAULT PRIVILEGES` 向运行时角色默认授予权限：新表默认不向运行时开放，只有迁移明确授权后才可访问。

## 6. 连接池

- 每个进程使用独立连接池和独立角色；不同入口不得共用连接池。
- 若启用 RLS，应在事务内使用 `SET LOCAL` 设置游戏范围，防止设置通过连接池泄露（见[游戏隔离](../architecture/game-isolation.md)）。
- 使用事务级连接池（例如 PgBouncer）时，无法使用会话级设置和 advisory lock；设计不依赖这两项功能。

## 7. 验证

以下测试必须以真实登录角色连接，绝不使用所有者角色（测试触发器的情况除外）。

| 身份 | 语句 | 预期结果 |
|---|---|---|
| `game_api_runtime` | `SELECT * FROM admin.admin_users` | 权限拒绝 |
| `game_api_runtime` | `SELECT * FROM audit.admin_audit_logs` | 权限拒绝 |
| 任一运行时角色 | `UPDATE economy.wallet_transactions SET amount = 1` | 权限拒绝 |
| 任一运行时角色 | `DELETE FROM audit.admin_audit_logs` | 权限拒绝 |
| 所有者（用于测试触发器） | `UPDATE economy.wallet_transactions ...` | `system.reject_mutation()` 抛出异常 |
| `gm_api_runtime` | `INSERT INTO gameplay.run_settlements ...` | 权限拒绝 |
| `game_worker_runtime` | `SELECT * FROM admin.admin_mfa` | 权限拒绝 |
| 任一运行时角色 | `CREATE TABLE economy.x ()` | 权限拒绝 |
| 任一运行时角色 | `TRUNCATE economy.wallets` | 权限拒绝 |

另需从 `information_schema.role_table_grants` 查询每个运行时角色的全部权限，并与矩阵比较，以便在 CI 中发现偏差。

## 8. 运维

- 按计划轮换运行时凭据，并演练轮换流程。
- 人员访问生产环境默认通过独立、可审计的只读角色；不得手动使用运行时角色或迁移角色。
- 迁移凭据仅保存在部署流水线中。
