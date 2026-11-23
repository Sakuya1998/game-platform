# Game Platform 技术设计与实施方案

> 文档状态：架构基线（Proposal / Initial Baseline）  
> 版本：1.0  
> 日期：2026-11-23  
> 适用范围：首期微信小游戏；架构预留后续多游戏平台接入  
> 配套规范：`docs/architecture/decisions.md`、`docs/database/schema.sql`、`docs/database/erd.md`、`api/openapi/*.yaml`

## 1. 目标与设计原则

建设一套可复用的小游戏服务端平台，为多款小游戏提供账号、配置、存档、局次结算、经济系统、广告奖励、运营管理和数据分析能力。

核心目标：

1. 每款游戏拥有独立玩家账号空间，避免不同游戏之间意外共享玩家身份和数据。
2. 服务端掌握金币、钻石、道具、永久进度、奖励发放等关键数据的最终权威。
3. 第一版支持微信小游戏，同时通过平台适配层为后续平台预留扩展能力。
4. 第一版同时交付玩家 API、GM API 和基础 GM Web 管理能力。
5. 玩家 API 与 GM API 独立部署、独立认证和独立安全策略，但共享同一套领域业务核心。
6. 保持模块化单体，不为追求形式上的微服务而引入不必要的网络调用、消息队列和分布式事务。

非目标：

- 首期不实现实时战斗服、帧同步或权威物理模拟。
- 不承诺仅凭客户端上报即可证明战斗过程或广告完整播放真实可信。
- 不在 MVP 引入 Kubernetes、Kafka/RocketMQ、复杂服务网格或独立微服务集群。
- 不把 GM 直接数据库写入作为业务操作入口。

## 2. 关键架构决策

| 主题 | 决策 |
|---|---|
| 后端语言与框架 | Go + Gin |
| 玩家 API / GM API | 两个独立运行服务、独立发布和扩缩容 |
| 业务核心 | 共享 Go `gamecore` 包，进程内直接调用 |
| 内部 API | 独立维护 OpenAPI 契约；MVP 不部署第三个内部 API 服务 |
| 数据库 | PostgreSQL，统一实例和 Database，按业务域划分 Schema |
| 缓存 | Redis，仅作为缓存、限流和短期协调设施 |
| 玩家身份 | 每个 game 独立 player_id 与账号命名空间 |
| 首期平台 | 微信小游戏；通过 adapter 隔离平台差异 |
| GM 前端 | Vue 3 + TypeScript + Element Plus |
| 游戏客户端 | Cocos Creator + TypeScript（首期建议方案） |
| 文件与静态资源 | S3/OSS + CDN |
| 部署 | Docker Compose 或现有容器平台；两个 API 独立部署 |

### 2.1 玩家 API、GM API 与 Game Core

```text
Game Client ──HTTPS──> game-api ──┐
                                 ├──> shared gamecore ──> PostgreSQL
GM Web ─────────HTTPS──> gm-api ──┘                    ├──> Redis
                                                      └──> S3 / OSS
```

- `game-api` 只暴露玩家端接口。
- `gm-api` 只暴露 GM / 管理员接口。
- 两个服务共享领域服务、Repository 接口、领域模型和业务规则。
- 两个服务之间不互相调用 HTTP，也不通过对方转发业务请求。
- 两个服务分别构建镜像、配置运行参数、健康检查、日志、部署和扩容。
- 两个服务可使用不同数据库 runtime role，落实最小权限。

该模式是**模块化单体 + 双 API 入口**，不是完整微服务架构。拆分的是运行入口和安全边界，不是领域模型和数据所有权。

### 2.2 内部 API 的定位

内部 API 作为独立契约维护在 `api/openapi/internal-api.yaml`，用于约束未来可信工作负载与平台之间的调用，例如异步 Worker、数据导入任务或内部自动化。

MVP 阶段：
- 不运行第三个 `platform-internal-api` 服务。
- 玩家 API 和 GM API 对共享 `gamecore` 直接调用。
- 不允许玩家客户端访问内部 API。
- 不允许 GM Web 通过内部 API 绕过 GM API 的授权和审计。

当确实出现独立 Worker、跨进程任务执行或其他可信服务调用需求时，再启用私有网络入口，并补齐服务身份认证、请求签名/短期凭证、重放保护、授权范围和审计。

## 3. 系统组件与职责

| 组件 | 职责 | 运行形态 |
|---|---|---|
| game-api | 玩家登录、玩家资料、配置、存档、局次、钱包、道具、广告、邮件、活动、排行榜 | 独立 Go 服务 |
| gm-api | GM 登录、RBAC、玩家管理、配置发布、经济操作、运营、审计和报表 | 独立 Go 服务 |
| gamecore | 领域模型、用例服务、业务规则、事务编排 | Go 共享内部包 |
| gm-web | GM 管理界面 | 静态前端 + CDN/Nginx |
| game-client | 小游戏客户端 | 微信小游戏包 |
| PostgreSQL | 权威业务数据、事务、审计、幂等、Outbox | 数据库 |
| Redis | 缓存、限流、短期状态、排行榜缓存 | 缓存 |
| Object Storage | 配置快照、静态资源、导出文件、归档 | S3/OSS |
| CDN | 配置和静态资源分发 | CDN |
| Worker（后续） | 异步任务、Outbox 消费、报表聚合等 | 按需增加 |

## 4. 多游戏与多平台模型

### 4.1 Game 是核心租户边界

平台内所有游戏业务数据必须归属明确的 `game_id`。同一数据库可以承载多个游戏，但逻辑隔离不能依赖开发人员记得在每条 SQL 中手动补条件。

基本规则：

- 每款游戏有独立的 `game_id`。
- 玩家、存档、局次、钱包、道具、邮件、活动、广告位等业务对象均有明确的游戏归属。
- 通过组合唯一约束和组合外键约束，确保对象不能跨游戏引用。
- Repository 查询必须显式携带授权后的 game scope。
- 对高风险表评估并逐步启用 PostgreSQL RLS；RLS 不是替代业务授权的唯一机制。
- GM 的平台级权限与游戏级权限明确区分，不能把 NULL scope 当作隐式全局授权。

### 4.2 平台适配层

首期只接入微信小游戏，但业务核心不直接依赖微信 SDK 或微信 API 的数据结构。

建议抽象：

- `PlatformLoginProvider`：平台登录凭证校验与身份解析。
- `PlatformAdProvider`：广告能力、广告位和回调能力适配。
- `PlatformPaymentProvider`：未来支付能力（首期可不实现）。
- `PlatformProfile`：平台用户标识和可选资料。
- `PlatformApp`：某款游戏在某个平台上的 AppID / 应用配置。

平台身份映射建议使用 `game_id + platform + app_id + openid` 唯一定位。可保存 unionid 等辅助标识，但默认不自动跨游戏合并玩家。

## 5. 玩家账号与认证

### 5.1 独立玩家账号

每款游戏有独立 `player_id`。同一个微信 OpenID 在不同游戏中默认对应不同的玩家账号。

建议身份映射唯一键：

```sql
UNIQUE (game_id, platform, app_id, openid)
```

客户端不能通过请求参数任意指定 `game_id`。服务端应根据可信的应用配置、路由域名、AppID 或签名上下文解析游戏，再将 game scope 写入认证上下文。

### 5.2 微信登录流程

1. 客户端调用 `wx.login()` 获取临时 code。
2. 客户端将 code 提交给玩家登录接口。
3. 服务端使用服务端保存的 AppSecret 调用微信 `jscode2session`。
4. 服务端获取 OpenID / session_key，并完成身份映射或创建当前游戏的玩家账号。
5. 服务端签发平台自己的 Access Token 和 Refresh Token。
6. 客户端仅保存平台 Token；session_key 和 AppSecret 不返回客户端。

安全要求：

- AppSecret 仅保存在服务端密钥管理设施或安全环境变量中。
- 不记录明文 code、session_key、Access Token、Refresh Token。
- Refresh Token 服务端仅存储哈希，支持轮换、撤销和设备/会话管理。
- 登录、刷新、登出、封禁和风控事件均应可审计。
- Access Token 可采用约 1 小时有效期；Refresh Token 有效期按产品风险设定（例如约 30 天），不是不可变常量。

### 5.3 玩家认证上下文

认证中间件解析 Token 后生成显式上下文，至少包括：

- `player_id`
- `game_id`
- `session_id`
- `platform`
- `scopes / claims`
- `request_id`

业务服务不得依赖全局变量或隐式线程状态获得当前玩家和游戏身份。调用 Service 时显式传入 Actor / Principal / Authorization Context。

## 6. 服务端权威与游戏数据边界

### 6.1 客户端负责什么

首期允许客户端负责局内实时战斗、动画、角色位置、表现层和短周期临时状态。这样可以降低实时服务器成本和开发复杂度。

### 6.2 服务端负责什么

以下数据必须由服务端权威管理：

- 金币、钻石、体力等资产余额。
- 道具数量、道具消耗和发放。
- 永久解锁、永久进度、成就和关键任务状态。
- 邮件附件领取、活动奖励领取。
- 付费订单、广告奖励和 GM 人工调账。
- 关卡结算后写入的永久数据。

客户端不得直接提交余额或指定最终奖励数量。

### 6.3 局次与结算

采用“客户端运行战斗，服务端结算”的折中模型：

1. 服务端创建游戏局次（run），生成不可预测的 run ID 和必要的规则快照。
2. 客户端本地执行战斗。
3. 客户端提交 run ID、关卡标识、结果摘要和必要证明材料。
4. 服务端校验 run 归属、状态、时效、重复提交、消耗、奖励上限和业务规则。
5. 服务端在一个数据库事务中写入结算结果、资产流水和永久进度。
6. 通过幂等键确保重复请求不会重复发奖。

重要限制：如果战斗完全在客户端执行，服务端无法仅凭客户端上报证明每一步战斗真实发生。对高价值奖励，应考虑服务端可重放规则、随机种子校验、合理性检测、限额、异常行为检测或后续升级为服务端模拟。

### 6.4 存档模型

- 存档可使用 JSONB 保存版本化的非经济状态。
- 存储 `schema_version` 和 `save_version`。
- 更新采用乐观锁，客户端携带 If-Match / 版本号。
- 服务端拒绝过期版本写入，避免覆盖较新存档。
- 钱包、道具、永久进度等关键数据不应只放在 JSON 存档中。

## 7. 经济系统与资产安全

### 7.1 钱包与流水

资产采用“余额快照 + 不可变交易流水”模型：

- 钱包记录当前余额。
- 每次增减都必须产生交易流水。
- 流水记录变更前后余额、变更数量、来源类型、来源业务 ID、操作者和原因。
- 通过数据库事务保证余额更新和流水写入原子性。
- 使用业务来源唯一键或幂等键防止重复发放。
- 并发扣减使用行锁或带余额条件的原子更新，禁止先读后无保护写入。

### 7.2 GM 调账

GM 不得直接 UPDATE 钱包余额。人工调账必须调用 Economy Service，并至少记录：

- 游戏、玩家、资产类型。
- 增减方向与数量。
- 操作原因和工单/审批引用。
- 操作者、请求 ID、幂等键。
- 调账前后余额。
- 必要时记录审批人和审批状态。

高额度、批量或高风险操作应增加双人审批和额度阈值。

## 8. 广告奖励与可信度边界

微信激励视频广告通常由客户端 SDK 播放。客户端的 `onClose` / `isEnded` 仅代表客户端观察到的播放结果，不能天然视为服务端可信证明。

推荐流程：

1. 客户端请求 prepare，服务端创建短时有效的 ad_session。
2. 客户端播放对应广告。
3. 客户端请求 claim，提交 ad_session。
4. 服务端校验会话归属、有效期、广告位、频次限制、重复领取和奖励规则。
5. 服务端通过幂等的 Economy Service 发奖，并记录审计/风控事件。

若广告平台提供可信服务端回调或 S2S 验证，应优先接入并验证签名、时间戳和重放保护。若没有可信回调，不能承诺彻底防止客户端伪造播放完成；应控制奖励价值、设置频次和每日上限，并对异常模式做风控。

## 9. 配置中心与资源发布

配置生命周期建议：

`Draft → Validate → Publish → Rollback`

能力包括：

- 配置草稿和版本管理。
- JSON Schema / 业务规则校验。
- 版本差异比较。
- 发布记录、发布人和发布时间。
- 回滚到历史版本。
- ETag / If-None-Match 缓存验证。
- 后续可扩展灰度发布和按渠道/版本分流。

大体积配置快照和静态资源存储在 S3/OSS，经 CDN 分发；数据库保留版本元数据和发布指针。客户端只读取配置，不获得任意执行代码的能力。动态配置不等于动态下载并执行未经审核的脚本。

## 10. GM 管理平台

### 10.1 功能范围

| 模块 | 主要功能 |
|---|---|
| 游戏管理 | 游戏创建、状态、平台 AppID、渠道配置 |
| 管理员与权限 | 管理员、角色、权限码、游戏 scope、MFA |
| 玩家管理 | 搜索、详情、封禁/解封、存档查看与恢复 |
| 经济管理 | 钱包查询、流水查询、人工调账、道具发放 |
| 配置中心 | 编辑、Schema 校验、版本比较、发布、回滚 |
| 广告管理 | 广告位、奖励规则、会话、异常记录 |
| 运营工具 | 邮件、公告、活动、奖励发放 |
| 排行榜 | 榜单配置、查询、重建/修复 |
| 数据分析 | DAU、留存、局次、通关率、广告转化 |
| 审计中心 | 管理员操作记录、敏感操作检索和导出 |

### 10.2 角色建议

- Super Admin：平台级管理。
- Game Admin：指定游戏的管理。
- Operator：邮件、公告、活动等运营操作。
- Config Manager：配置编辑、校验、发布。
- Customer Support：玩家查询、有限客服操作。
- Analyst：只读数据分析。

角色只是权限集合，不应替代资源范围判断。授权必须同时判断 permission code、game scope、资源归属和操作风险。

### 10.3 GM 安全要求

- GM 身份体系与玩家身份体系完全独立。
- 独立 JWT 签名密钥、登录流程、刷新/撤销机制和会话策略。
- 强制 MFA；敏感操作二次验证。
- 支持 IP allowlist、VPN 或 Zero Trust 接入。
- RBAC + game scope，默认拒绝。
- 所有敏感写操作记录审计日志。
- 对封禁、调账、批量发奖、配置发布等操作设置原因、幂等和审批策略。
- GM API 不向前端暴露数据库凭证，也不允许前端直连数据库。

## 11. API 契约设计

### 11.1 API 入口

| API | 建议路径 | 访问方 |
|---|---|---|
| Player API | `/api/v1` | 游戏客户端 |
| GM API | `/admin/v1` 或 `/gm/v1` | GM Web |
| Internal API | `/internal/v1` | 未来可信内部工作负载 |

建议域名：

- `api.game.example.com`：玩家 API。
- `gm-api.game.example.com`：GM API。
- `gm.example.com`：GM Web。
- `cdn.game.example.com`：配置和静态资源。

### 11.2 玩家 API 范围

- 微信登录、Token 刷新、登出。
- 玩家资料和 bootstrap。
- 配置查询。
- 存档读取和更新。
- 游戏局次创建和结算。
- 钱包、交易流水和道具查询。
- 广告位、广告 prepare 和 claim。
- 邮件查询和领取。
- 活动查询和奖励领取。
- 排行榜查询。
- 客户端事件批量上报。

### 11.3 GM API 范围

- GM 登录、MFA、会话和登出。
- 游戏及平台应用管理。
- 玩家查询、封禁、解封、存档恢复。
- 钱包、流水、人工调账、道具操作。
- 配置编辑、校验、发布和回滚。
- 广告位和奖励规则管理。
- 邮件、公告、活动管理。
- 排行榜管理。
- Dashboard / 留存 / 运营分析。
- 管理员、角色和权限管理。
- 审计日志查询。

### 11.4 内部 API 范围

未来可用于 Worker 注册、任务领取/确认、Outbox 消费、内部数据回填等可信工作负载。MVP 只维护契约，不开放公网，不把它作为玩家 API 或 GM API 的内部 HTTP 依赖。

### 11.5 API 通用约定

- OpenAPI 3.1，契约作为代码审查对象。
- 统一 JSON 格式、错误码、request_id 和时间格式。
- 写操作使用 `Idempotency-Key`。
- 存档更新使用 `If-Match` 或明确版本号。
- 列表使用 limit + cursor，不采用高偏移分页作为默认方案。
- Token、密钥和敏感个人信息不得写入日志。
- 对登录、领取奖励、调账、批量操作配置独立限流。
- 从 OpenAPI 生成 TypeScript 类型或客户端 SDK，避免前后端手工漂移。

配套契约文件：
- `api/openapi/player-api.yaml`
- `api/openapi/gm-api.yaml`
- `api/openapi/internal-api.yaml`

## 12. PostgreSQL 数据设计

### 12.1 Schema 分域

初始 DDL 按领域划分 Schema，具体以 `docs/database/schema.sql` 为准：

| Schema | 领域 |
|---|---|
| platform | 游戏、平台应用和平台配置 |
| auth | 平台身份映射、玩家会话 |
| player | 玩家资料和玩家基础数据 |
| game | 游戏配置和版本 |
| gameplay | 局次与结算 |
| economy | 钱包、交易、道具 |
| ads | 广告位、广告会话与奖励 |
| operation | 邮件、公告、活动 |
| admin | GM 用户、角色和权限 |
| audit | 管理操作审计 |
| system | 幂等、Outbox 等基础设施数据 |
| ranking | 排行榜 |
| analytics | 分析事件和聚合数据 |

### 12.2 数据库约束原则

- 所有业务表明确主键、创建/更新时间和归属字段。
- 组合唯一键与组合外键用于约束同一 game 内的数据引用。
- 外键和唯一约束优先于仅靠应用层校验。
- 关键金额和数量使用明确数值类型，避免浮点误差。
- 时间统一使用 timestamptz，应用侧统一 UTC 存储。
- 重要业务操作在单个事务中完成。
- DDL 通过有序 Migration 演进，已应用 Migration 不可原地修改。
- Migration 使用独立高权限账号；API runtime role 不得拥有 schema/table owner 权限。
- 对大表制定索引、分区、归档和保留策略。

### 12.3 数据库角色

建议至少区分：

- `game_migrator`：仅用于部署 Migration，拥有必要 DDL 权限。
- `game_api_runtime`：玩家 API 运行账号，按需读写玩家业务表。
- `gm_api_runtime`：GM API 运行账号，按需读取管理数据并执行受控业务操作。
- 后续 Worker 使用独立 runtime role。

不要让两个 API 使用数据库 owner 或超级用户连接。GM 高风险操作通过领域服务执行，不通过开放任意表 UPDATE 权限实现。

### 12.4 RLS 与审计

对 game scope 隔离进行威胁建模后，逐步为适合的表引入 RLS。应用连接池必须在事务范围内设置可信 game/player context，并确保连接归还前上下文不会泄漏。RLS 策略要通过真实 LOGIN role 测试，而不是只用表 owner 验证。

审计日志应限制 UPDATE/DELETE 权限，采用追加写入模型；同时设计保留、归档和防篡改策略。当前 DDL 是初始数据模型，生产上线前仍需完成 grants、RLS、审计不可变性和迁移测试。

## 13. Redis、对象存储与缓存策略

### Redis

适合存放：
- 可重建的玩家/配置缓存。
- API 限流计数。
- 短期登录/验证码/一次性状态（需明确 TTL）。
- 排行榜热数据缓存。
- 短时互斥或任务协调信息。

不应将 Redis 作为钱包余额、交易流水或永久进度的唯一存储。所有关键写操作最终落 PostgreSQL。

### S3 / OSS

适合存放：
- 配置版本快照和大型 JSON。
- 游戏静态资源、活动素材。
- 数据导出文件和归档数据。
- 后续日志/事件批量文件。

对象存储访问应使用最小权限、私有 Bucket、短期签名 URL 和明确生命周期策略。通过 CDN 分发静态资源时避免把管理接口或私有数据公开缓存。

## 14. 安全与可靠性

### 14.1 通用安全

- 全站 HTTPS。
- Secret 使用云密钥管理或安全注入，不进入 Git。
- 请求体大小、超时、并发和速率限制。
- 参数校验、SQL 参数化、输出编码。
- CORS 白名单，不使用宽泛通配符承载凭证。
- 统一 request_id / trace_id，日志脱敏。
- 依赖漏洞扫描、镜像扫描和定期升级。

### 14.2 可靠性

- API 无状态，支持多副本。
- PostgreSQL 做备份、PITR 和恢复演练。
- Redis 可重建，避免成为权威数据单点。
- 对外部微信 API 设置超时、重试上限和熔断/退避。
- 对重复请求采用幂等机制。
- 使用 Outbox 保障事务内业务事件可靠落库；初期可由简单 Worker 轮询，不必立即引入 MQ。
- 关键业务指标、错误率、延迟、数据库连接池和外部 API 失败率纳入监控。

### 14.3 可观测性

建议至少采集：
- API 请求量、P50/P95/P99 延迟、状态码和限流数。
- 登录成功率、微信接口耗时和错误码。
- 局次创建/结算成功率、重复结算拦截量。
- 资产流水数量、调账量和异常负余额拦截量。
- 广告 prepare/claim 比例和异常领取量。
- 配置发布/回滚事件。
- PostgreSQL 连接池、锁等待、慢查询、复制/备份状态。
- Redis 命中率、内存和延迟。
- Worker Outbox 积压和最老事件年龄（启用后）。

## 15. Go 项目结构

建议采用一个 Go module，两个服务共用根目录下的 `internal/gamecore`，避免早期拆分多个 go.mod 带来版本管理和本地开发复杂度。

```text
game-platform/
├── apps/
│   ├── game-client/
│   │   └── cocos/
│   └── gm-web/
├── services/
│   ├── game-api/
│   │   ├── cmd/server/main.go
│   │   └── internal/
│   │       ├── handler/
│   │       ├── middleware/
│   │       └── router/
│   └── gm-api/
│       ├── cmd/server/main.go
│       └── internal/
│           ├── handler/
│           ├── middleware/
│           └── router/
├── internal/
│   └── gamecore/
│       ├── auth/
│       ├── player/
│       ├── config/
│       ├── save/
│       ├── gameplay/
│       ├── economy/
│       ├── ads/
│       ├── operation/
│       ├── ranking/
│       ├── admin/
│       ├── audit/
│       └── repository/
├── api/
│   └── openapi/
├── docs/
├── migrations/
├── deploy/
│   ├── docker/
│   └── compose/
└── go.mod
```

依赖方向应保持清晰：

```text
HTTP Handler -> Application Service -> Domain Model
                                  └──> Repository Interface
Infrastructure Adapter -> Repository Interface
```

Game Core 不应依赖 Gin 的 Request/Context 类型。HTTP 层负责协议解析、认证中间件和响应映射；领域服务负责业务规则和事务边界。

## 16. 部署与环境

### 16.1 部署拓扑

| 入口 | 目标 |
|---|---|
| api.game.example.com | game-api |
| gm-api.game.example.com | gm-api |
| gm.example.com | gm-web |
| cdn.game.example.com | CDN / Object Storage |

GM API 应配置独立 WAF / 限流策略；条件允许时增加 VPN、Zero Trust 或 IP allowlist。玩家 API 与 GM API 不共享认证密钥。

### 16.2 环境划分

至少区分 dev、staging、production：
- 不同环境使用独立数据库、Redis、对象存储 Bucket 和平台密钥。
- 生产数据不得复制到开发环境，除非经过脱敏。
- Migration 在 staging 验证后再进入 production。
- 发布采用可回滚镜像和配置版本。
- 数据库变更遵循 expand-and-contract，避免应用与 DDL 不兼容。

### 16.3 MVP 部署建议

初期使用 Docker Compose 或现有容器平台即可：
- game-api 一个独立 Deployment/Container。
- gm-api 一个独立 Deployment/Container。
- gm-web 静态部署。
- PostgreSQL 托管服务优先。
- Redis 可先单实例或托管缓存。
- 对象存储与 CDN 使用云服务。
- 仅当实际容量、HA 或团队运维能力要求时再迁移 Kubernetes。

## 17. 测试策略与质量门禁

### 单元测试
- 领域规则、奖励计算、资产变更、权限决策、配置校验。
- 边界值、负数、溢出、时间窗口和状态机转换。

### 集成测试
- 使用真实 PostgreSQL 验证 Migration、外键、唯一约束、事务和并发。
- 使用独立 LOGIN role 验证 GRANT / RLS，不使用 owner 身份代替。
- Redis 测试缓存失效、限流和短期状态。
- 微信平台适配使用 mock server / contract test。

### API 契约测试
- OpenAPI lint。
- Handler 与 OpenAPI schema 一致性测试。
- 认证、授权、错误码、分页、幂等和 If-Match 行为测试。
- GM API 越权、跨 game 访问和玩家访问他人资源的负向测试。

### 关键安全测试
- 跨游戏 IDOR。
- 玩家伪造 game_id / player_id。
- 重复结算、重复领取、并发扣款。
- Refresh Token 重放和轮换。
- GM 越权、MFA 绕过、审计缺失。
- 存档版本冲突。
- 广告 claim 伪造、重放和过期会话。

## 18. 分阶段实施路线图

按小团队、核心开发者投入估算，整体可按约 10–12 周作为初步计划；实际周期取决于 GM 报表深度、客户端接入和安全验收范围。

| 阶段 | 主要交付 | 验收重点 |
|---|---|---|
| P0 架构基线 | ADR、ERD、DDL、OpenAPI、目录和 CI | 契约审查通过，设计决策冻结 |
| P1 工程与认证 | Go 工程、配置、日志、健康检查、微信登录、玩家会话 | 登录链路、Token 轮换、跨游戏隔离 |
| P2 玩家基础能力 | 玩家资料、bootstrap、配置读取 | game scope 和缓存策略正确 |
| P3 存档与局次 | 存档版本控制、run 创建、结算 | 幂等、并发和奖励规则测试 |
| P4 经济与广告 | 钱包流水、道具、广告 prepare/claim | 事务一致性、重复发奖拦截 |
| P5 GM 基础 | GM 登录、MFA、RBAC、玩家查询 | 独立认证、game scope、审计 |
| P6 GM 运营 | 配置发布、邮件、公告、活动、调账 | 敏感操作审批与审计 |
| P7 数据与部署 | 指标、Dashboard、备份、发布流水线 | 恢复演练、告警和发布回滚 |
| P8 联调上线 | 小游戏接入、压测、安全验收 | 业务闭环和上线检查表通过 |

## 19. Codex / AI 辅助实施任务拆分

建议以小而可验收的任务推进，禁止一次性生成整个系统。每个任务必须提供：

1. 修改文件清单。
2. 数据库 Migration 变化。
3. OpenAPI 变化。
4. 单元/集成测试命令及真实结果。
5. 未完成项、风险和后续任务。
6. 如涉及架构决策变化，先提交 ADR 修改建议，不得自行把未审批决定标记为 Accepted。

推荐任务序列：

- T00：仓库工程规范、目录、Makefile、CI。
- T01：配置加载、结构化日志、request_id、健康检查。
- T02：数据库连接池、Migration 工具和 runtime role。
- T03：平台 / 游戏基础模型。
- T04：微信登录 adapter 和玩家 Token。
- T05：玩家资料与 bootstrap。
- T06：配置版本和 CDN 读取。
- T07：存档读写与乐观锁。
- T08：局次创建与结算状态机。
- T09：钱包、交易流水和幂等。
- T10：道具与邮件领取。
- T11：广告 prepare / claim。
- T12：GM 认证、MFA 和 RBAC。
- T13：GM 玩家管理与审计。
- T14：GM 配置管理与发布。
- T15：GM 经济操作、审批和道具管理。
- T16：活动、公告、排行榜和数据面板。
- T17：部署、监控、备份与恢复演练。
- T18：端到端、安全、并发和上线验收。

## 20. 主要风险与应对

| 风险 | 影响 | 应对 |
|---|---|---|
| 客户端战斗结果可伪造 | 虚假通关和奖励 | 限制奖励价值、服务端校验、异常检测；高价值玩法升级服务端模拟 |
| 广告完成状态不可信 | 虚假广告领奖 | S2S 回调优先；否则限额、频控、风控 |
| 跨游戏数据越权 | 玩家数据泄露/污染 | game_id 组合约束、显式授权上下文、RLS 和负向测试 |
| GM 高权限滥用 | 资产或运营事故 | MFA、RBAC、审批、审计、IP/Zero Trust |
| 重复请求 | 重复发奖/扣款 | Idempotency-Key、数据库唯一键、事务 |
| 存档覆盖 | 玩家进度丢失 | schema_version、save_version、If-Match |
| Redis 数据丢失 | 缓存/短期状态丢失 | Redis 不承载权威资产；可重建缓存 |
| 配置错误发布 | 全量玩家异常 | 发布前校验、版本留存、回滚、后续灰度 |
| 数据库权限过宽 | 横向越权和误操作 | migration/runtime 分离、最小 GRANT、RLS 验证 |
| 过早微服务化 | 开发和运维复杂度增加 | 共享 Game Core，按真实边界演进 |

## 21. 上线前检查清单

### 架构与代码
- [ ] 玩家 API 与 GM API 独立部署、独立认证。
- [ ] 两个 API 只通过共享 Game Core 复用业务逻辑，不互相 HTTP 调用。
- [ ] Handler 不承载领域规则，Game Core 不依赖 Gin。
- [ ] 所有业务请求显式携带授权后的 game scope。

### 身份与安全
- [ ] 微信 AppSecret 只存在服务端。
- [ ] 玩家与 GM Token 完全隔离。
- [ ] Refresh Token 哈希存储、轮换和撤销已验证。
- [ ] GM MFA、RBAC、game scope 和敏感操作审计已验证。
- [ ] 跨游戏和跨玩家越权测试通过。

### 数据与经济
- [ ] Migration 在空库和升级库均验证。
- [ ] 关键外键、唯一键和组合外键测试通过。
- [ ] 钱包余额与流水事务一致。
- [ ] 并发扣款、重复结算和重复领取测试通过。
- [ ] 存档乐观锁冲突测试通过。
- [ ] RLS / GRANT 使用真实 runtime LOGIN role 验证。

### 运营与可靠性
- [ ] 配置发布前校验，历史版本可回滚。
- [ ] 广告奖励可信度边界已向产品明确。
- [ ] PostgreSQL 备份和恢复演练通过。
- [ ] 监控、告警、日志脱敏和 request_id 已接入。
- [ ] 发布、回滚和密钥轮换 Runbook 已准备。

## 22. 配套文档索引与状态说明

本方案是面向团队理解系统全貌的总览文档。以下规范文档承载可直接用于实现的详细契约：

- [ADR 与架构决策](architecture/decisions.md)
- [PostgreSQL DDL](database/schema.sql)
- [ERD](database/erd.md)
- [玩家 API OpenAPI](../../api/openapi/player-api.yaml)
- [GM API OpenAPI](../../api/openapi/gm-api.yaml)
- [内部 API OpenAPI](../../api/openapi/internal-api.yaml)
- [实施路线图](implementation/roadmap.md)

**重要状态声明：** 本仓库当前文档定义的是初始架构与数据模型基线，不代表系统代码已实现，也不代表 DDL 已在目标 PostgreSQL 版本执行验证、OpenAPI 已通过 lint、权限/RLS 已完成安全测试或系统已通过生产验收。后续必须通过 Migration、自动化测试和安全评审逐项验证。
