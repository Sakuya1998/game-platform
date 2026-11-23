# ADR-0003 — 玩家账号模型

- **状态：** 已接受
- **日期：** 2026-11-23
- **取代：** `docs/architecture/decisions.md` v1.0 中的 ADR-003
- **相关：** [ADR-0002](ADR-0002-game-isolation.md)、[ADR-0005](ADR-0005-api-service-boundaries.md)

## 背景

首个接入平台为微信小游戏，后续可能支持抖音、支付宝和原生 Android/iOS。同一微信用户可以在平台上体验多款游戏。

## 决策

**账号按游戏隔离。**

- 同一微信用户进入两款游戏时，会获得不同的 `player_id`。
- 外部身份唯一约束为 `UNIQUE (game_id, platform, app_id, openid)`。
- 玩家在同一款游戏中可以绑定多个外部身份。可以存储 `unionid`，但即使 `unionid` 相同，也绝不跨游戏合并玩家。

**微信登录流程。**

1. 客户端调用 `wx.login()`，并将临时 code 发送给 `game-api`。
2. 服务端根据平台应用解析游戏，使用该应用的密钥调用 `jscode2session`，获取 OpenID。
3. 服务端在该游戏内将此身份映射到玩家；若不存在则创建。并发登录时通过身份唯一键保证创建幂等。
4. 服务端签发自有 access 和 refresh token；此后客户端只使用平台令牌。

**凭据处理。**

- AppSecret 仅保存在服务端密钥库中，数据库只存储其引用。
- 不得向客户端返回微信 `session_key`。
- Refresh token 以哈希形式存储，使用时轮换，并可撤销。支持登出、撤销和封禁。
- 登录接口应限流。失败的微信登录记录在 `auth.login_records`，保留可诊断错误码，但不记录 code、`session_key` 或令牌。

**初始令牌有效期**（可在安全评审后调整）：

| 令牌 | 初始值 |
|---|---|
| 玩家 access token | 1 小时 |
| 玩家 refresh token | 30 天 |
| GM access token | 15–30 分钟 |
| GM refresh token | 由安全策略确定，可撤销 |
| 服务凭据 | 独立 AK/SK 或 mTLS |

**平台适配器。** 各平台的登录逻辑位于 `internal/platform/<provider>` 下的适配器中。`gamecore` 使用规范化身份记录，不依赖微信数据结构。

## 后果

- 新增平台只需增加适配器和一条 `game_platform_apps` 记录，无需新增玩家模型。
- 跨游戏账号关联不在范围内，需另行通过 ADR 决策。
- 玩家重装应用或更换设备后，可通过 OpenID 找回账号；V1 不提供平台级账号恢复流程。
