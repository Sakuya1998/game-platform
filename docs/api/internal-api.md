# 内部 API 指南

- **状态：** 评审草案（2026-11-23）。**该服务仅作预留，V1 不部署。**
- **契约：** [`api/openapi/internal-api.yaml`](../../api/openapi/internal-api.yaml) 是事实来源。
- **相关：** [ADR-0008](../adr/ADR-0008-internal-api-and-worker.md)、[异步任务设计](../architecture/async-job-design.md)、[认证与授权](../architecture/authentication-and-authorization.md)

标记为**（提案）**的内容未在设计文档或 ADR 中说明，尚待确认。

## 1. 它是什么、又不是什么

| 它是 | 它不是 |
|---|---|
| 机器到机器访问平台业务逻辑的入口 | 第二套 GM API |
| 预先保留的契约，启用时无需修改 `gamecore` | 第三份业务逻辑副本 |
| 仅可从私有网络访问 | V1 中 `game-worker` 调用 `gamecore` 的方式 |
| | 第三方平台回调的入口 |

V1 中，`game-worker` 与平台处于同一 Go 模块，并在进程内调用 `gamecore`。若改为通过 HTTP 调用，只会增加网络跳转和故障模式，没有实际收益。

## 2. 部署时机

出现以下任一情况时，再部署 `internal-api`：

- Worker 或调度器在本模块之外构建，或使用其他语言实现。
- 其他内部系统（数据流水线、运营工具、第二套后端）需要触发平台操作。
- 任务执行需要与数据库隔离到不同网络区域。

在此之前，V1 只保留三项：`services/internal-api` 目录、`internal/security/serviceauth` 抽象和 API 契约。

## 3. 契约中的操作

| 分组 | 操作 | 权限代码 | 用途 |
|---|---|---|---|
| 任务 | `POST /internal/v1/jobs/{job_id}/claim` | `job.execute` | 为待处理任务获取租约 |
| 任务 | `POST /internal/v1/jobs/{job_id}/heartbeat` | `job.execute` | 延长租约 |
| 任务 | `POST /internal/v1/jobs/{job_id}/complete` | `job.execute` | 标记任务成功 |
| 任务 | `POST /internal/v1/jobs/{job_id}/fail` | `job.execute` | 上报失败，由服务端决定重试或终止 |
| 邮件 | `POST /internal/v1/mail-deliveries/execute` | `mail.deliver` | 投递一批邮件 |
| 奖励 | `POST /internal/v1/reward-jobs/execute` | `reward.execute` | 执行奖励任务的一批发放 |
| 分析 | `POST /internal/v1/events/batch` | `event.write` | 写入可信生产者发来的事件 |
| 配置 | `POST /internal/v1/config-releases/notify` | `config.notify` | 请求刷新某次发布对应的缓存和 CDN |
| 维护 | `POST /internal/v1/maintenance/tasks` | `maintenance.run` | 将允许列表中的维护任务加入队列 |

这些权限代码是存储于 `system.service_game_grants` 的服务权限，与 `admin.permissions` 中的 GM 权限代码分属不同命名体系；本契约选用的名称属于**提案**。

以下两项设计可避免该 API 演变为 GM API：

- 调用方不得自行提交奖励内容。`reward-jobs/execute` 接受奖励任务 ID 和玩家 ID；发放内容由创建任务的运营人员预先确定。
- `maintenance/tasks` 仅接受列出的任务类型。

契约中的 `claim` 操作要求传入任务 ID。轮询 Worker 还需要能够请求“下一个属于我处理类型的任务”；设计表中尚未定义此操作，待服务开始建设时决定。

## 4. 部署后的要求

| 要求 | 实现方式 |
|---|---|
| 仅限私有网络 | 监听内网；公网入口不可路由到此服务；配置防火墙或安全组规则 |
| 独立服务身份 | `system.service_identities` |
| 认证 | HMAC AK/SK 签名（`X-Access-Key`、`X-Signature`）或 mTLS |
| 防重放 | `X-Timestamp` 必须在允许的时钟偏差范围内，`X-Nonce` 仅可使用一次 |
| 按服务授权 | 根据调用方授权检查操作权限代码 |
| 游戏范围 | 请求中的 `game_id` 必须与 `system.service_game_grants` 中的记录一致 |
| 幂等性 | 每个变更请求都必须携带 `Idempotency-Key` |
| 审计 | 每次调用均写入一条 `audit.service_audit_logs`，包括被拒绝的调用 |
| 限流 | 按服务身份限流 |

私有网络是纵深防御措施，不能取代认证。

### HMAC 签名（提案）

契约规定使用 HMAC-SHA256 对请求方法、路径、查询参数、时间戳、nonce 和请求体哈希签名。服务首次构建时确定规范字符串。可采用以下格式：

```text
string_to_sign = METHOD + "\n" + PATH + "\n" + CANONICAL_QUERY + "\n"
               + X-Timestamp + "\n" + X-Nonce + "\n" + hex(sha256(body))
X-Signature    = hex(hmac_sha256(secret, string_to_sign))
```

允许的时钟偏差为 5 分钟。nonce 在此时间窗口内存储于 Redis；若 Redis 不可用，应拒绝请求，而不是跳过校验后放行。

密钥通过 `service_credentials.secret_ref` 从密钥管理器读取。由于服务端必须重新计算签名，不能将密钥保存为单向哈希。

## 5. Actor

验证通过的调用会转换为 `Actor`：`Type = "service"`，`ID` 为服务身份，`Service` 为其代码，`GameID` 为授权的游戏。`gamecore` 按照与其他调用方相同的方式处理：使用相同服务、校验逻辑、流水和审计字段。

## 6. 启用检查清单

- [ ] 重新评审并执行契约 lint；契约可能在未使用期间发生偏移。
- [ ] 若轮询 Worker 需要，补充“领取下一个任务”操作。
- [ ] 确定规范签名字符串并发布客户端辅助库。
- [ ] 创建 `internal_api_runtime` 数据库角色及授权。
- [ ] 通过经过评审的流程创建服务身份、凭据和游戏授权。
- [ ] 从私有网络外部确认 `/internal/` 路由无法访问。
- [ ] 为错误签名、过期时间戳、重放 nonce、缺少授权和错误游戏添加测试。
- [ ] 为被拒绝的调用添加仪表盘和告警。
- [ ] 通过修订 ADR-0008 记录该决策。

## 7. 第三方回调

来自微信或广告平台的请求不是内部调用。它们从公网到达，使用平台自有签名机制，路由前缀为 `/platform-callbacks/v1`。详见[服务边界](../architecture/service-boundaries.md#5-第三方回调)。
