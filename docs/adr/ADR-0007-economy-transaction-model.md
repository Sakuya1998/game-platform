# ADR-0007 — 经济事务模型

- **状态：** 已接受
- **日期：** 2026-11-23
- **取代：** `docs/architecture/decisions.md` v1.0 中 ADR-004 的经济不变量
- **相关：** [ADR-0004](ADR-0004-data-authority-model.md)、[ADR-0006](ADR-0006-postgresql-schema-design.md)

## 背景

金币、钻石、体力、其他游戏内货币和道具库存，是最值得攻击且出错后影响最大的资产。奖励来源多样，包括对局结算、广告、邮件、活动、GM 调整和批处理任务；每种操作都可能被重试或重放。

## 决策

**余额与不可变流水并行维护。**

```text
wallets       └── wallet_transactions
player_items  └── item_transactions
```

- 每次余额或数量变更都必须在同一个数据库事务中写入流水。任何代码路径都不得只更新余额而不写流水。
- 事务锁定钱包行（`SELECT … FOR UPDATE`）或使用等效的条件更新，校验幂等性、规则和限额，更新余额并插入流水。
- 金额以最小单位整数表示，不使用浮点数。
- 扣款不得导致余额为负。V1 对所有货币使用 `CHECK (balance >= 0)`；若某种货币允许负余额，必须修订本 ADR。

**幂等性。**

- 每次发放和扣除都必须幂等。同一业务来源不得重复发奖。
- 最终保障依靠 PostgreSQL 流水唯一键，而非 Redis 锁：同一玩家同一货币的 `(source_type, source_id, transaction_type)` 只能生效一次。
- 请求级重放通过 `Idempotency-Key` 和 `system.idempotency_keys` 处理。

**唯一写入路径。** 无论请求来自哪个入口，所有资产变更都必须经过 `gamecore` 中的经济应用服务。每次调用都携带 `Actor`，流水记录 Actor 类型和 ID。生产环境通过受控数据库函数同时写入资产状态和流水。详见 [ADR-0010](ADR-0010-v1-decision-baseline.md)。

**GM 调账。**

- GM 不得直接设置余额。API 接受带符号的调账金额，并要求指定货币、金额、必填原因和工单引用，同时携带 `Idempotency-Key`：
  `POST /gm/v1/games/{game_id}/players/{player_id}/wallet-adjustments`。
- 每次调账都在同一事务中写入流水和独立的 `audit.admin_audit_logs` 记录。
- 发放和扣除使用独立权限（`economy.grant`、`economy.deduct`）。超过阈值的双人审批暂作预留。

**批量发放。** 群体奖励和邮件附件由 `game-worker` 调用同一服务执行，每位玩家单独进行幂等发放；不得在 GM HTTP 请求中处理（ADR-0009）。

## 后果

- 热门钱包的写入会因行锁串行化；对小游戏的写入频率而言可以接受，并通过压测测量。
- 流水表会持续增长，需在数据规模明确后制定分区和保留计划。
- 退款和更正必须新增冲正流水，不得编辑原记录。
- V1 不含支付功能。任何支付接入前，付费货币、退款和拒付都需单独通过 ADR 决策。
