# 服务边界

- **状态：** 评审草案（2026-11-23）
- **细化：** [ADR-0001](../adr/ADR-0001-modular-monolith.md)、[ADR-0005](../adr/ADR-0005-api-service-boundaries.md)、[ADR-0008](../adr/ADR-0008-internal-api-and-worker.md)
- **来源：** [技术设计](../game-platform-technical-design.md)第 2.2、2.3、6.3、6.4 和 8.3 节

若本文档与 ADR 冲突，以 ADR 为准。标记为**（提案）**的内容未在设计文档或 ADR 中说明，尚待确认。

## 1. 四个入口

| 入口 | 调用方 | 认证 | 可以做什么 | 绝不可做什么 |
|---|---|---|---|---|
| `game-api` | 游戏客户端 | 玩家令牌 | 操作令牌所属游戏中该令牌玩家自己的数据 | 接受任意 `player_id` 或 `game_id`；暴露任何 GM 操作 |
| `gm-api` | `gm-web` | MFA 后的管理员会话，以及带游戏范围的 RBAC | 在管理员授权范围内读取和操作玩家、经济、配置与运营数据 | 接受玩家令牌；在请求中执行批量任务；直接设置余额 |
| `game-worker` | 无（主动拉取任务） | 以 `system` Actor 运行 | 通过 `gamecore` 执行任务和 Outbox 事件 | 持有 GM 权限；通过 HTTP 调用 `gamecore` |
| `internal-api` | 可信服务 | 服务身份（HMAC AK/SK 或 mTLS） | 预留契约：任务控制、批处理、内部事件和维护 | 演变成第二套 GM API；从公网访问 |

拆分 `game-api` 与 `gm-api` 是安全决策，而非扩缩容决策。仅用 URL 前缀无法表达“玩家只能读取自己的钱包”和“运营人员可以扣除游戏 X 中任意钱包”之间的权限差异。

## 2. 共享内容与隔离内容

| 共享（在 `internal/gamecore` 中只有一份） | 按入口隔离（绝不共享） |
|---|---|
| 领域模型和不变量 | Handler |
| 应用服务和事务边界 | Router |
| Repository 接口和实现 | 认证中间件 |
| | 请求与响应 DTO |
| | 限流策略、CORS、请求体限制 |
| | 进程配置、镜像、健康检查 |

面向玩家和面向 GM 的同一实体 DTO 可以不同，并且有意分别定义。

## 3. 导入规则

| 包 | 可以导入 | 禁止导入 |
|---|---|---|
| `internal/gamecore/domain` | 标准库、`internal/shared` | 本模块中的其他所有包 |
| `internal/gamecore/application` | `domain`、`repository` 接口、`internal/shared` | `transport`、`security`、Gin |
| `internal/gamecore/repository` | `domain`、`internal/infrastructure/postgres` | `transport`、Gin |
| `internal/transport/http/game` | `gamecore/application`、`security/playerauth` | `transport/http/gm`、`transport/http/internal`、`security/adminauth` |
| `internal/transport/http/gm` | `gamecore/application`、`security/adminauth` | `transport/http/game`、`transport/http/internal`、`security/playerauth` |
| `internal/transport/http/internal` | `gamecore/application`、`security/serviceauth` | 另外两个传输层包 |
| `services/game-worker` | `gamecore/application`、`internal/infrastructure` | 任何 `transport` 包 |

**（提案）** 在 CI 中使用导入边界 lint 工具（例如 golangci-lint 中的 `depguard` 或 `go-arch-lint`）强制执行规则，使违规直接导致构建失败，而非只依赖评审发现。

## 4. Actor 契约

每个应用服务方法都将 `Actor` 作为第一个业务参数。

```go
type Actor struct {
    Type    string // player / admin / service / system
    ID      string
    GameID  string
    Roles   []string
    Service string
}
```

- 入口在完成认证和授权后构造 `Actor`。任何字段都不得从客户端提供的请求体、查询字符串或请求头复制。
- `gamecore` 重新校验只有自身才知道的信息：目标行属于 `actor.GameID`；若为玩家 Actor，目标玩家必须就是该 Actor。
- 流水、审计和任务记录都保存 `actor_type` 和 `actor_id`。

| 入口 | `Type` | `ID` | `GameID` |
|---|---|---|---|
| `game-api` | `player` | 令牌中的玩家 ID | 令牌中的游戏 ID |
| `gm-api` | `admin` | 会话中的管理员 ID | 权限范围校验通过后的路径 `game_id` |
| `game-worker` | `system` | Worker 实例名称 | 任务记录中的游戏 ID |
| `internal-api` | `service` | 服务身份 ID | 服务授权校验通过后的请求 `game_id` |

## 5. 第三方回调

平台发给我们的调用通过独立入口 `/platform-callbacks/v1/<platform>/...` 接收。请求来自公网，不带玩家令牌或内部凭据，使用平台自有机制认证。

### 5.1 用途

| 场景 | 触发方式 | 服务端处理 | V1 是否需要 |
|---|---|---|---|
| 激励广告服务端验证 | 玩家符合奖励条件时，微信广告服务器调用开发者服务器。微信将此列为可选验证模式。 | 验证请求，与 `ad_session` 匹配，并将会话标记为服务端已验证，使领取不再仅依赖客户端标记 | V1 暂不接入，风险与限额见 ADR-0010 |
| 微信消息推送：客服消息 | 玩家打开客服会话或发送消息 | 接收消息或事件；可选择回复或转发至客服工具 | 仅当游戏内使用客服时需要 |
| 微信消息推送：订阅消息事件 | 玩家接受或拒绝订阅；消息发送成功或失败 | 记录结果，仅向已同意的玩家发送提醒 | 仅当使用订阅消息时需要 |
| 微信消息推送：异步内容安全结果 | 服务端提交图片或音频进行检测 | 接收结果并拦截或放行内容 | 仅当玩家可以上传媒体时需要 |
| 虚拟支付发货及支付事件 | 玩家购买金币或道具 | 验证、去重、通过经济服务发放，并在平台超时前响应 | 不需要；支付不在 V1 范围内 |
| 其他平台回调 | 抖音、支付宝、原生广告网络 | 通过相应平台适配器采用相同模式 | 不需要 |

编写本文档时尚未获取广告验证回调的字段列表、签名算法和重试行为。设计端点前请查阅微信最新文档。

### 5.2 规则

- 使用平台自有签名、令牌或加密机制进行验证，绝不使用内部 AK/SK 规则。
- 平台提供时间戳时，检查并拒绝过期请求。
- 通过平台消息或交易 ID 的唯一键去重；平台可能重试。
- 根据接收应用解析 `game_id`（URL 或请求体中的 `app_id`），绝不使用任意客户端参数。
- 通过 `gamecore` 在一个事务中完成工作，然后返回平台要求的准确成功响应。耗时工作转为后台任务。
- 平台公布 IP 地址范围时，应用对应的 IP 策略。
- 记录事件类型和结果；绝不记录令牌、密钥或包含个人数据的消息正文。

### 5.3 V1 承载位置

出现实际回调需求时，在 `game-api` 下设置 `/platform-callbacks/v1` 独立路由组，单独配置平台认证、限流及监控。玩家令牌中间件不用于此路由组。详见 [ADR-0010](../adr/ADR-0010-v1-decision-baseline.md)。

## 6. 新增端点检查清单

1. 调用方属于哪个入口？若“玩家和运营人员都要用”，则应设计两个端点。
2. 先将操作加入对应入口的 OpenAPI 文件。
3. 指定权限代码（GM）或所有权规则（玩家）。
4. 说明幂等策略：`Idempotency-Key`、自然唯一键或只读。
5. 说明事务边界，以及事务中是否写入审计或 Outbox 事件。
6. 在 `gamecore` 中实现规则；Handler 只负责解析请求、调用服务和映射结果。

## 7. 看似方便但禁止的做法

- 因为“逻辑相同”就共享 Handler 或中间件。
- 在 `game-api` 路由上添加 `player_id` 查询参数。
- `gm-api` 调用 `game-api`，或 Worker 通过 HTTP 调用任一 API。
- 在请求中循环处理玩家的 GM 端点。
- 只包装调用方可在进程内直接调用函数的内部端点。
