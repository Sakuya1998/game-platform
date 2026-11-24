# ADR-0006 — PostgreSQL Schema 设计

- **状态：** 已接受
- **日期：** 2026-11-23
- **取代：** `docs/architecture/decisions.md` v1.0 中的 ADR-005 及 ADR-006 的数据库角色部分
- **相关：** [ADR-0002](ADR-0002-game-isolation.md)、[ADR-0007](ADR-0007-economy-transaction-model.md)、[数据库结构](../database/schema.sql)、[ERD](../database/erd.md)

## 背景

所有持久化业务数据均存储于 PostgreSQL。数据库布局应保持领域边界清晰，使约束能够落实游戏隔离，并防止数据库权限绕过应用层 RBAC。

## 决策

**单一数据库，按领域划分 Schema。** 数据库名为 `game_platform`，包含 `platform`、`auth`、`player`、`game`、`gameplay`、`economy`、`ads`、`operation`、`ranking`、`admin`、`audit`、`analytics`、`system` 等 Schema。V1 的 57 张表列于技术设计第 5.2 节。

**约定。**

- 主键使用 UUID；时间统一使用 `timestamptz`；金额和数量使用最小单位整数。
- 游戏归属表包含 `game_id`，在被引用时提供 `UNIQUE (game_id, id)`，并通过复合外键建立引用。
- 除应用层检查外，还通过数据库约束落实唯一性、余额非负和幂等性，作为最终防线。
- 审计日志和流水仅追加：运行时角色只授予 `INSERT`/`SELECT` 权限，并通过触发器拒绝 `UPDATE`/`DELETE`。

**数据访问。**

- 钱包发放与扣除、流水、幂等处理、排行榜查询和复杂统计使用显式 SQL（sqlc 或手写），确保事务及锁语义清晰可见。
- 管理员、游戏配置以及可选的玩家资料等管理类 CRUD 可使用 GORM。
- Handler 中不得编写 SQL。

**角色与权限。**

- `game-api`、`gm-api`、`game-worker` 分别使用独立运行时角色；迁移使用单独角色。运行时角色不得为超级用户或表所有者。
- V1 通过区分角色、最小权限授权和受控 Repository 实现隔离。
- 生产前使用受控数据库函数写入钱包和道具，运行时角色不得直接变更资产表。
- V1 推迟 RLS，由复合外键、应用范围校验、角色授权及隔离测试落实隔离。详见 [ADR-0010](ADR-0010-v1-decision-baseline.md)。

**迁移。** Schema 变更采用有序、只向前的迁移（golang-migrate 或 Atlas），存放于 `/migrations`。已应用的迁移不得修改。`docs/database/schema.sql` 是经过评审的基线，T03 将据此生成首批迁移。

**环境。** 开发、预发布和生产使用不同数据库。测试环境与生产环境不得共享玩家数据。

## 后果

- 单一数据库构成共同故障域和扩展上限；V1 接受此权衡。
- `analytics.game_events` 的数据量会最先超过主库承载能力；达到可测量规模后，再决定分区、保留策略或独立分析存储。
- 按角色和表逐项授权需要持续维护，必须通过使用各运行时角色建立连接的测试加以覆盖。
