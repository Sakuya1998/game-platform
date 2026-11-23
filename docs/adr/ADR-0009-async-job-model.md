# ADR-0009 — 异步任务模型

- **状态：** 已接受
- **日期：** 2026-11-23
- **取代：** `docs/architecture/decisions.md` v1.0 中 ADR-008 关于异步工作的部分
- **相关：** [ADR-0007](ADR-0007-economy-transaction-model.md)、[ADR-0008](ADR-0008-internal-api-and-worker.md)

## 背景

部分工作无法放在同步 HTTP 请求中执行，包括批量投递邮件、批量发放奖励、统计、重建排行榜、清理过期数据、存档快照、刷新配置缓存和重试失败任务。若 GM 请求尝试处理数十万名玩家，就会超时并留下部分完成的状态。

## 决策

**V1 使用 PostgreSQL 作为任务队列。** 不引入消息代理。

```text
gm-api / game-api ── 创建任务（与业务变更在同一事务中）──> PostgreSQL
                                                                  ├─ system.background_jobs
                                                                  └─ system.outbox_events
game-worker ── 领取 → 执行 → 重试 → 完成 ──> gamecore
```

- 任务和 Outbox 事件与触发它们的业务变更在同一事务中写入。
- `game-worker` 使用 `SELECT … FOR UPDATE SKIP LOCKED` 领取任务，获取租约，并通过心跳续租。

**任务状态：** `pending`、`running`、`succeeded`、`failed`、`retrying`、`cancelled`。

**必须具备的能力。**

- 最大重试次数和退避策略。
- 租约、Worker 心跳，以及重新领取租约过期任务的能力。
- 幂等执行：任务重复执行不得重复产生副作用；奖励步骤依赖流水唯一键（ADR-0007）。
- 记录失败原因，并允许 GM 手动重试。

**GM 操作规则。** 群发邮件、批量奖励和群体补偿必须创建任务（以 `operation.reward_jobs` 记录业务，以 `system.background_jobs` 负责执行），并立即返回任务引用。不得在 GM 请求中直接执行。

**引入消息代理的条件。** 只有在实测吞吐、延迟或扇出规模超出 PostgreSQL 轮询能力时，才通过新 ADR 引入消息队列。

## 后果

- 轮询会给异步工作增加数秒延迟；对 V1 任务类型可以接受。
- 任务表会增加主库写入负载和 vacuum 压力；完成的任务需要清理任务和保留期限。
- 投递保证为至少一次，因此每个任务处理器都必须从设计上保证幂等，并通过强制重复执行进行测试。
