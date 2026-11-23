# ADR-0002 — 以 `game_id` 隔离游戏

- **状态：** 已接受
- **日期：** 2026-11-23
- **取代：** `docs/architecture/decisions.md` v1.0 中 ADR-003 和 ADR-005 的隔离部分
- **相关：** [ADR-0003](ADR-0003-player-account-model.md)、[ADR-0006](ADR-0006-postgresql-schema-design.md)

## 背景

多款游戏共用一套数据库和代码库。遗漏 `WHERE game_id = ?` 不能导致其他游戏的数据泄露或损坏；客户端也不能通过传入不同标识切换游戏。

## 决策

- 以平台签发的 UUID `game_id` 作为隔离键。微信 AppID 是游戏配置，不是游戏身份。
- V1 所有游戏共用一个 PostgreSQL 数据库，不为每款游戏单独建库。
- 每张归属某款游戏的表都包含 `game_id`。重要表设置 `UNIQUE (game_id, id)`；游戏内表之间通过包含 `game_id` 的复合外键关联。
- Repository 的每个查询都必须显式传入 `game_id`。不得提供不带游戏范围的游戏数据查询方法。
- 游戏范围始终来自已认证上下文，不接受客户端任意传参：

  | 入口 | `game_id` 来源 |
  |---|---|
  | `game-api` | 玩家令牌声明；登录时由服务端根据 `(platform, app_id)` 解析 |
  | `gm-api` | URL 路径；仅在 RBAC 确认管理员拥有该游戏权限后接受 |
  | `internal-api` | 请求字段；仅在校验服务身份的 `service_game_grants` 后接受 |
  | `game-worker` | 任务记录 |

- `game-api`、`gm-api` 和 `game-worker` 使用不同数据库角色连接；迁移使用第四个角色；任何运行时角色都不是所有者或超级用户。
- 对高风险表启用 PostgreSQL RLS 作为纵深防御。RLS 是应用授权的补充，不可取代应用授权。

## 后果

- 复合键会使部分外键更宽，并要求原本可以省略 `game_id` 的子表也包含该字段。
- 未经新 ADR 批准，不支持跨游戏功能（如共享账号或共享背包）。
- 隔离必须通过测试验证：集成与安全测试（T03、T21）需覆盖跨游戏外键拒绝和跨游戏访问尝试。
