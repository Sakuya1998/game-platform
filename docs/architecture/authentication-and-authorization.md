# 认证与授权

- **状态：** 评审草案（2026-11-23）
- **细化：** [ADR-0003](../adr/ADR-0003-player-account-model.md)、[ADR-0005](../adr/ADR-0005-api-service-boundaries.md)、[ADR-0008](../adr/ADR-0008-internal-api-and-worker.md)
- **来源：** [技术设计](../game-platform-technical-design.md)第 4.2、6、7.2、7.3 和 11.1 节

若本文档与 ADR 冲突，以 ADR 为准。标记为**（提案）**的内容未在设计文档或 ADR 中说明，尚待确认。

## 1. 三个安全平面

| 平面 | 入口 | 主体 | 凭据 | 存储 |
|---|---|---|---|---|
| 玩家 | `game-api` | 某款游戏中的玩家 | 平台 access token 和 refresh token | `auth.player_sessions` |
| GM | `gm-api` | 管理员 | 密码、MFA、access token 和 refresh token | `admin.admin_sessions`、`admin.admin_mfa` |
| 服务 | `internal-api`（预留） | 服务身份 | HMAC AK/SK 或 mTLS 证书 | `system.service_credentials` |

三个平面完全隔离：分别使用不同的签发方、受众、签名密钥、会话表和中间件包（`playerauth`、`adminauth`、`serviceauth`）。一个平面的令牌在其他平面会因签名或受众校验失败而被拒绝。

`game-worker` 不接收入站凭据。它以 `system` Actor 身份运行，并受数据库角色限制。

## 2. 玩家安全平面

### 2.1 登录

1. 客户端调用 `wx.login()` 获取临时 code。
2. 客户端携带 `app_id` 和 `code` 请求 `POST /api/v1/auth/wechat/login`。
3. 服务端解析平台应用及所属游戏；拒绝未知或停用的平台应用，以及已停用的游戏。
4. 服务端使用从密钥库读取的应用密钥调用 `jscode2session`。
5. 服务端按 `(game_id, platform, app_id, openid)` 查找身份；若不存在，则在同一事务中创建玩家和身份。若并发创建导致唯一键冲突，失败方重新读取已有记录。
6. 服务端检查是否存在有效封禁；已封禁玩家返回 `403 AUTH_FORBIDDEN`。
7. 服务端创建会话，保存 refresh token 哈希，写入登录记录，并返回两种令牌。

### 2.2 令牌

| 令牌 | 初始有效期 | 内容 | 存储方式 |
|---|---|---|---|
| Access | 1 小时 | `sub` = 玩家 ID、`game_id`、`sid` = 会话 ID、`iss`、`aud`、`exp`、`iat` | 不持久化；通过签名验证 |
| Refresh | 30 天 | 不透明随机值 | 在 `auth.player_sessions.refresh_token_hash` 中存储 SHA-256 哈希 |

有效期可在安全评审后调整。

### 2.3 刷新、登出和撤销

- 刷新时轮换令牌：已提交的令牌被消费；创建新的会话记录，并通过 `rotated_from` 指向旧会话；旧会话被撤销。
- **（提案）** 重用检测：若提交的 refresh token 对应的会话已轮换或撤销，则撤销该玩家的整条会话链，因为这可能表示令牌已被复制。
- 登出时撤销当前会话。
- 封禁玩家时撤销其所有会话。

Access token 在密码学上仍然有效，直到其过期；因此封禁或登出后最长可能仍有效一小时。**（提案）** 使用以会话 ID 为键、有效期等于 access token 剩余有效期的短时 Redis 拒绝名单，并由 `playerauth` 检查以缩短此窗口。Redis 不可用时，资产变更路由回退到数据库检查。

### 2.4 玩家授权

玩家没有独立的权限模型。授权规则是所有权：每个操作只能访问 `actor.GameID` 下属于 `actor.ID` 的数据。`game-api` 不提供用于指定其他玩家的路由参数。

## 3. GM 安全平面

### 3.1 MFA 登录

1. 使用用户名和密码调用 `POST /gm/v1/auth/login`。成功后返回短时、单次使用的 `challenge_token`，而不是 access token。
2. 使用 challenge token 和 TOTP 或恢复码调用 `POST /gm/v1/auth/mfa/verify`。成功后服务端创建包含 `mfa_verified_at` 的 `admin.admin_sessions` 记录，并返回令牌。
3. 尚未注册 MFA 的管理员必须先完成注册，才会签发任何令牌。**（提案）** 生产环境强制所有管理员启用 MFA。

| 控制项 | 规则 |
|---|---|
| 密码存储 | `admin.admin_users.password_hash` 中保存 Argon2id 或 bcrypt 哈希（**提案：** Argon2id） |
| 锁定 | 用户记录保存 `failed_login_count` 和 `locked_until`；连续失败后锁定（**提案：** 失败 5 次后锁定 15 分钟） |
| MFA 密钥 | 使用 KMS 管理的密钥加密，存于 `admin.admin_mfa.secret_encrypted` |
| Access token | 15–30 分钟 |
| Refresh token | 有效期由安全策略决定；哈希存储、轮换且可撤销 |
| 网络 | 可行时在 `gm-api` 前配置 VPN、零信任网络或 IP 允许列表 |

### 3.2 RBAC 评估

每个请求都按照**管理员 + 权限代码 + 游戏范围**进行授权。代码中绝不比较角色名称。

```text
allow(admin, permission, game_id) =
    exists assignment a of admin where
        permission in permissions(a.role)
        and ( a.scope_type = 'platform'
              or (a.scope_type = 'game' and a.game_id = game_id) )
```

- 默认拒绝。未声明所需权限代码的操作不得挂载路由。
- 对平台级操作（创建游戏、管理管理员、修改角色权限），请求不带 `game_id`，只有 `platform` 范围的授权才能通过检查。
- 列表端点应过滤为管理员获授权的游戏，而非直接拒绝整个请求。
- 被拒绝的请求返回 `403 AUTH_FORBIDDEN`，不得泄露目标是否存在。
- 权限检查从数据库读取，或使用短 TTL 缓存（**提案：** 60 秒），以便撤销角色后快速生效。

权限目录和角色矩阵见 [RBAC 矩阵](../security/rbac-matrix.md)。

### 3.3 高风险操作

手动发放和扣除、批量奖励、封禁、存档恢复、配置发布、群发邮件和权限变更必须：

- 在 `gm-web` 中二次确认；
- 必填 `reason`（有工单时同时提供 `ticket_id`）；
- 携带 `Idempotency-Key`；
- 与变更在同一事务中写入审计记录。

V1 由单人操作。超过金额阈值后实施双人审批属于预留增强项，需先确定阈值。

## 4. 服务安全平面（预留）

V1 不部署该平面；保留相关表和 `serviceauth` 抽象，以便未来启用时无需修改 `gamecore`。

| 步骤 | HMAC AK/SK | mTLS |
|---|---|---|
| 识别 | `X-Access-Key` 对应一条 `service_credentials` 记录 | 客户端证书指纹与 `credential_hash` 匹配 |
| 认证 | 使用从密钥管理器读取的密钥，对请求方法、路径、查询、时间戳、nonce 和请求体哈希重新计算 HMAC-SHA256 签名 | TLS 握手 |
| 防重放 | `X-Timestamp` 在允许的时钟偏差内；该时间窗口内未出现过 `X-Nonce` | 幂等键 |
| 授权 | `system.service_game_grants` 中，该服务在请求 `game_id` 范围内拥有此操作的权限代码 | 同左 |
| 记录 | 写入 `audit.service_audit_logs` | 同左 |

## 5. 第三方调用方

微信和广告平台回调使用平台自有签名机制认证，不签发任何平面的令牌。详见[服务边界](service-boundaries.md#5-third-party-callbacks)。

## 6. 从凭据构造 Actor

```text
request ─ 按安全平面中间件认证 ─ 按所有权/RBAC/服务授权检查 ─ 构造 Actor ─ gamecore
```

`Actor` 是身份进入 `gamecore` 的唯一途径。其字段只能来自已验证凭据和服务端查询，不得来自请求体。

## 7. 密钥和敏感信息

| 秘密 | 存放位置 | 绝不可 |
|---|---|---|
| 微信 AppSecret | 密钥库；数据库只保存 `credential_ref` | 存入数据库、日志、响应或代码仓库 |
| 微信 `session_key` | 登录期间保存在服务端内存；仅在功能需要时加密持久化 | 返回给客户端或写入日志 |
| 令牌签名密钥 | 密钥库；每个平面独立密钥集，轮换时允许新旧密钥重叠 | 在多个平面间共用 |
| Refresh token | 仅存哈希 | 静态明文存储 |
| MFA 密钥 | 加密字段 | 静态明文存储 |
| 服务密钥 | 密钥库，通过 `secret_ref` 引用 | 存入数据库 |

日志绝不包含 AppSecret、refresh token、完整 `Authorization` 请求头或 `session_key`。

## 8. 限流

按路由组分别限流：玩家登录和令牌刷新、存档、结算、广告领取、GM 登录和 MFA 验证。已认证请求按玩家或管理员限流；未认证请求按 IP 和 app ID 限流。具体数值在 T22 压测期间确定。
