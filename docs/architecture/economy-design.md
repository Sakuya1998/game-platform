# 经济系统设计

- **状态：** 评审草案（2026-11-23）
- **细化：** [ADR-0007](../adr/ADR-0007-economy-transaction-model.md)
- **来源：** [技术设计](../game-platform-technical-design.md)第 4.6、5.2 F 和 6.2 节；[schema.sql](../database/schema.sql) 中的表

若本文档与 ADR 冲突，以 ADR 为准。标记为**（提案）**的内容未在设计文档或 ADR 中说明，尚待确认。

## 1. 模型

```text
economy.currency_definitions ── economy.wallets ── economy.wallet_transactions（只追加）
economy.item_definitions     ── economy.player_items ── economy.item_transactions（只追加）
```

- 一条钱包记录保存某玩家某种货币的当前余额，是流水的投影。
- 流水记录是不可变事实：谁在何时、因何业务来源、以何原因变更了什么资产以及变更数量。
- 金额以最小单位的 `bigint` 表示，全程不使用浮点数。
- 余额和数量不得低于零（`CHECK (balance >= 0)`、`CHECK (quantity >= 0)`）。

## 2. 经济服务

无论哪个入口调用，所有资产变更都必须经过 `gamecore` 中的同一个应用服务。

```go
type EconomyService interface {
    Grant(ctx context.Context, actor Actor, req GrantRequest) error
    Spend(ctx context.Context, actor Actor, req SpendRequest) error
    GetWallet(ctx context.Context, actor Actor, playerID string) (*Wallet, error)
}
```

请求应指定玩家、资产、正数金额和业务来源：`transaction_type`、`source_type`、`source_id`。若调用方已持有事务（如结算或领取邮件），则传入该事务，使发放与对应记录一同提交。

## 3. 单次资产变更步骤

```sql
BEGIN;

-- 1. 确保钱包记录存在（首次发放该货币时）。
INSERT INTO economy.wallets (game_id, player_id, currency_code)
VALUES ($1, $2, $3)
ON CONFLICT DO NOTHING;

-- 2. 锁定钱包。
SELECT balance FROM economy.wallets
WHERE game_id = $1 AND player_id = $2 AND currency_code = $3
FOR UPDATE;

-- 3. 在应用层校验：货币已启用、金额 > 0、扣款不超余额、
--    充值后不超 max_balance。

-- 4. 写入流水记录。唯一键是幂等性保障。
INSERT INTO economy.wallet_transactions
    (game_id, player_id, currency_code, direction, amount, balance_after,
     transaction_type, source_type, source_id, idempotency_key,
     actor_type, actor_id, reason)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13);

-- 5. 更新余额投影。
UPDATE economy.wallets
SET balance = $6, version = version + 1, updated_at = now()
WHERE game_id = $1 AND player_id = $2 AND currency_code = $3;

COMMIT;
```

若第 4 步触发唯一键冲突，表示该变更已执行过：服务回滚并返回之前的结果，不将其作为错误展示给玩家。

## 4. 幂等性

两种机制各司其职：

| 机制 | 范围 | 防护内容 |
|---|---|---|
| `Idempotency-Key` 请求头和 `system.idempotency_keys` | 单个 HTTP 请求 | 防止客户端或代理重复提交同一请求；返回已存储响应 |
| 流水唯一键 `(game_id, player_id, currency_code, source_type, source_id, transaction_type)` | 单个业务事件 | 防止同一事件通过任意路径重复发放，包括不同请求、任务重试或代码缺陷 |

第二项是最终保障；绝不依赖 Redis 锁。

### 4.1 资产来源目录（提案）

每一行表示一种资产变更来源。`source_id` 必须在业务事件中保持稳定，确保重试时生成相同的唯一键。

| `transaction_type` | `source_type` | `source_id` | 方向 |
|---|---|---|---|
| `run_cost` | `game_run` | 对局 ID | 扣除 |
| `run_reward` | `game_run` | 对局 ID | 发放 |
| `ad_reward` | `ad_session` | 广告会话 ID | 发放 |
| `mail_claim` | `player_mail` | 玩家邮件 ID | 发放 |
| `activity_reward` | `activity_claim` | `<activity_id>:<reward_id>` | 发放 |
| `batch_reward` | `reward_job` | 奖励任务 ID | 发放 |
| `gm_adjustment` | `admin_adjustment` | 请求的 `Idempotency-Key` | 任一方向 |
| `correction` | `wallet_transaction` | 被冲正的流水 ID | 任一方向 |

新增类型必须先加入此目录，再在代码中使用。

## 5. 单个事件涉及多项资产

结算或邮件可能同时发放多种货币和道具。所有变更在一个事务中执行，每项资产各写一条流水。

**（提案）** 为避免同一玩家的并发事务死锁，始终按固定顺序加锁：先按 `currency_code` 升序锁定钱包，再按 `item_id` 升序锁定道具。

## 6. 限额

| 限制 | 校验位置 | 超限处理 |
|---|---|---|
| 余额不足 | 步骤 3 及 `CHECK` 约束 | 返回 `409 INSUFFICIENT_BALANCE`；不写入任何内容 |
| `currency_definitions.max_balance` | 步骤 3 | **（提案）** 拒绝发放，不静默截断；若游戏需要封顶余额，必须在货币配置中声明 |
| `item_definitions.max_quantity` | 同上 | 同上 |
| 货币或道具已停用 | 步骤 3 | 拒绝 |
| 单来源限额（对局、广告、活动） | 调用 `Grant` 的服务中 | 调用方决定金额；经济服务只检查全局限额 |

## 7. 道具

道具沿用相同模式，使用 `player_items` 和 `item_transactions`。`item_id` 是每款游戏内唯一、面向策划的代码。不可堆叠道具使用 `stackable = false`，数量限定为 0 或 1；V1 不支持单件道具属性。

## 8. GM 调账

- 端点：`POST /gm/v1/games/{game_id}/players/{player_id}/wallet-adjustments`。
- 请求体：`currency`、带符号的 `amount`、必填的 `reason`、可选的 `ticket_id`。
- 正金额需要 `economy.grant` 权限；负金额需要 `economy.deduct` 权限。
- 在同一事务中写入流水和包含变更前后余额的 `audit.admin_audit_logs` 记录。
- GM 绝不传入目标余额，也不存在直接设置余额的 API。
- 更正操作应新增冲正记录；流水不得编辑或删除（由触发器和权限强制执行）。

设计中的 GM API 目前仅支持钱包调账。GM 道具调整还没有端点；有需要时按相同结构添加。

## 9. 批量发放

群体奖励由 `game-worker` 执行，对每位玩家调用一次 `Grant`，其中 `source_type = 'reward_job'`、`source_id` 为奖励任务 ID。任务重试时会再次处理已发放的玩家；唯一键会使重复尝试成为空操作。详见[异步任务设计](async-job-design.md)。

## 10. 对账（提案）

定时 Worker 任务按钱包比较余额与其全部流水的有符号合计，并检查最新流水的 `balance_after` 是否与当前余额相同。发现差异时发出告警并调查；任务绝不自行“修复”余额。道具执行相同检查。

## 11. 指标

按 `transaction_type` 统计发放成功和失败次数、唯一键拦截的重复请求、余额不足拒绝次数、GM 调账次数与金额、钱包锁等待时间及对账差异。

## 12. 不在范围内

支付、付费货币、退款和拒付。接入任何支付前都需通过新的 ADR 决策，包括[服务边界](service-boundaries.md#5-third-party-callbacks)所述的发货回调。
