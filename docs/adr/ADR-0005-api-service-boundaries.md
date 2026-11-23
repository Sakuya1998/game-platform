# ADR-0005 — API 服务边界与安全平面

- **状态：** 已接受
- **日期：** 2026-11-23
- **取代：** `docs/architecture/decisions.md` v1.0 中的 ADR-006 和 ADR-007
- **相关：** [ADR-0001](ADR-0001-modular-monolith.md)、[ADR-0008](ADR-0008-internal-api-and-worker.md)

## 背景

玩家、GM 运营人员、后台任务和可信服务都需要访问相同的业务规则，但各自权限差异很大。玩家只能操作自己的数据；GM 可在授权游戏范围内封禁玩家和调整钱包；Worker 执行系统任务但不得拥有 GM 权限；服务以机器身份认证。仅凭 URL 前缀无法承载这些差异。

## 决策

**四个入口，三个安全平面。**

| 组件 | 使用方 | 认证方式 | V1 状态 |
|---|---|---|---|
| `game-api` | 玩家客户端 | 玩家令牌 | 部署 |
| `gm-api` | GM 管理后台 | 管理员会话、MFA、带游戏范围的 RBAC | 部署 |
| `internal-api` | 可信服务 | 服务身份（HMAC AK/SK 或 mTLS） | 预留，不部署 |
| `game-worker` | —（无 HTTP 入口） | 以 `system` Actor 运行 | 有异步任务时部署 |

- 玩家端和 GM 端使用独立的令牌签发方、受众、签名密钥和会话存储。`game-api` 不暴露 GM 路由；`gm-api` 不接受玩家凭据。
- 建议域名：`api.example.com` → `game-api`；`gm-api.example.com` → `gm-api`；`gm.example.com` → `gm-web`；`internal.example.com` → `internal-api`（部署时仅限内网）；`cdn.example.com` → CDN。

**显式调用方上下文。** 每个入口完成请求认证与授权后，构造 `Actor`（包含 `type`：player / admin / service / system，`id`、`game_id`、角色及服务信息），并传给每次应用服务调用。Actor 字段不得从客户端输入复制。

**GM 授权。** 默认拒绝。授权依据为管理员、权限代码和游戏范围，而非角色名称。高风险操作（手动发放或扣除资产、批量奖励、封禁、存档恢复、配置发布、群发邮件、权限变更）必须二次确认、填写原因并记录审计。V1 使用单人操作，但必须填写原因并审计；高金额双人审批作为预留增强项。

**玩家 API 规则。** `game-api` 不得提供接受任意 `player_id` 的端点。玩家身份只能从已验证的令牌中获取。

**契约。**

- OpenAPI 3.1 是唯一事实来源：`api/openapi/game-api.yaml`、`gm-api.yaml`、`internal-api.yaml`。TypeScript SDK 从这些契约生成。
- 前缀：`/api/v1`、`/gm/v1`、`/internal/v1`。
- 响应信封：`{ "code", "message", "data", "request_id" }`，包含稳定且可供机器解析的错误码。
- 写入端点支持 `Idempotency-Key`；存档更新使用 `If-Match`；集合使用游标分页；每个请求都带有 `request_id`。

**第三方回调属于独立入口。** 微信或广告平台通过公网访问 `/platform-callbacks/v1/...`。回调需按各平台规则验证签名、时间戳、重复请求和 IP；不得使用内部 AK/SK 规则。

## 后果

- 从首个版本开始分别构建、配置和监控两种 API 镜像。
- 若玩家端和 GM 端对同一实体的视图不同，则分别定义 DTO；这是有意设计。
- 待决事项：设计尚未确定承载 `/platform-callbacks/v1` 的进程。默认建议在 `game-api` 中设置独立路由组，不使用玩家令牌中间件；首次实现回调前需确认。
