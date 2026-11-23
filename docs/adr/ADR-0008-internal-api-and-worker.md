# ADR-0008 — 内部 API 与 Worker

- **状态：** 已接受
- **日期：** 2026-11-23
- **取代：** `docs/architecture/decisions.md` v1.0 中的 ADR-002
- **相关：** [ADR-0001](ADR-0001-modular-monolith.md)、[ADR-0005](ADR-0005-api-service-boundaries.md)、[ADR-0009](ADR-0009-async-job-model.md)

## 背景

V1 需要后台执行批量邮件、批量奖励、统计和清理任务，但暂时不需要机器间 HTTP 调用。早期基线将 Worker 视为未来组件，要求其通过私有内部 API 访问平台；这会导致同一模块中的进程通过 HTTP 调用自身的业务核心。

## 决策

**Worker 不等同于内部 API。** Worker 是执行任务的进程；内部 API 是供服务调用的入口。

**V1 的 `game-worker`。**

- `game-worker` 是由同一 Go 模块构建的独立进程。它在进程内直接调用 `gamecore` 应用服务，并通过相同的 Repository 访问 PostgreSQL。
- Worker 以 `system` Actor 运行，使用独立数据库角色，且不持有 GM 权限。
- 一旦存在异步任务就部署 Worker。Worker 不得通过 HTTP 调用 `gamecore`。

**预留 `internal-api`。**

- V1 保留 `services/internal-api` 目录、`internal/security/serviceauth` 中的服务认证抽象，以及 `api/openapi/internal-api.yaml` 契约；不部署第三个 HTTP 服务。
- 仅在独立 Worker 或其他系统需要通过 HTTP 访问平台业务逻辑时部署。届时仍调用相同的 `gamecore` 服务；它不是业务逻辑的第三份副本，也不得演变成另一个 GM API。
- 预留契约（`/internal/v1`）包括：领取任务、心跳、完成/失败任务、邮件投递执行、奖励任务执行、内部事件批处理、配置发布通知及受控维护任务。

**部署后的要求。**

- 通过私有网络控制访问。
- 使用独立服务身份（`system.service_identities`、`service_credentials`）。
- 使用 HMAC AK/SK 签名或 mTLS，并通过时间戳和 nonce 防止重放。
- 按服务身份授权，并从 `system.service_game_grants` 获取 `game_id` 范围。
- 实施请求幂等、调用审计（`audit.service_audit_logs`）和限流。

**V1 预先做好准备。** `Actor` 类型包含 `service` 和 `system`，服务身份表也已存在，因此未来启用内部 API 时不需要改变 `gamecore` 方法签名。

**第三方回调不属于内部 API。** 详见 ADR-0005。

## 后果

- V1 无需运维第三个服务，Worker 与业务逻辑之间也没有网络跳转。
- Worker 与 API 通过共享模块耦合发布；任务载荷变更必须兼容已入队任务。
- 内部契约在未使用时可能与实现脱节。它与其他两个契约一同在 CI 中执行 lint，并在首次部署前重新评审。
