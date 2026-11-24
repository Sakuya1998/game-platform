# 游戏 API 指南

- **状态：** 评审草案（2026-11-23）
- **契约：** [`api/openapi/game-api.yaml`](../../api/openapi/game-api.yaml) 是事实来源。本指南解释 YAML 无法表达的行为；若两者不一致，应修正本指南。
- **相关：** [ADR-0005](../adr/ADR-0005-api-service-boundaries.md)、[数据权威模型](../architecture/data-authority-model.md)

标记为**（提案）**的内容未在设计文档或 ADR 中说明，尚待确认。

## 1. 基本信息

| 项目 | 值 |
|---|---|
| 服务入口 | `game-api` |
| 基础 URL | `https://api.example.com/api/v1` |
| 调用方 | 游戏客户端 |
| 认证 | `Authorization: Bearer <access token>`；标记为公开的两个认证路由除外 |
| 格式 | JSON，字段采用 `snake_case`，UTF-8 编码 |
| 金额 | 以最小单位表示的整数 |
| 时间 | RFC 3339，UTC |

玩家和游戏身份始终从令牌中获取。任何路由都不接受 `player_id` 或 `game_id`。登录时，服务端根据 `app_id` 解析游戏。

## 2. 响应信封

```json
{ "code": "OK", "message": "success", "data": {}, "request_id": "uuid" }
```

错误响应使用相同结构，并返回稳定的 `code`。客户端应根据 `code` 分支处理，不应依赖 `message`。

| `code` | HTTP 状态 | 含义 | 客户端操作 |
|---|---:|---|---|
| `AUTH_UNAUTHORIZED` | 401 | 令牌缺失、无效或过期 | 刷新一次令牌，然后重新登录 |
| `AUTH_FORBIDDEN` | 403 | 玩家已被封禁 | 显示封禁通知；不要重试 |
| `GAME_DISABLED` | 403 | 游戏或平台应用已停用 | 显示维护通知 |
| `PLAYER_NOT_FOUND` | 404 | 令牌对应的玩家不存在 | 重新登录 |
| `RESOURCE_NOT_FOUND` | 404 | 该玩家名下不存在目标资源 | 不要重试 |
| `SAVE_VERSION_CONFLICT` | 412 | 存档已在其他位置变更 | 重新加载、合并后重试 |
| `GAME_RUN_ALREADY_SETTLED` | 409 | 对局已结算 | 视为已完成；刷新余额 |
| `INSUFFICIENT_BALANCE` | 409 | 货币或道具不足 | 刷新资产信息 |
| `IDEMPOTENCY_CONFLICT` | 409 | 相同幂等键对应不同请求体 | 属于客户端错误；每个逻辑操作生成新键 |
| `CONFIG_VERSION_INVALID` | 409 | 配置版本不可用 | 重新加载配置索引 |
| `RATE_LIMITED` | 429 | 请求过于频繁 | 延迟后重试 |
| `INTERNAL_ERROR` | 500 | 服务端故障 | 退避重试；若请求带幂等键则可安全重试 |

上述状态码映射为与 YAML 一致的**提案**；设计文档只列出了错误码。

## 3. 请求头

| 请求头 | 方向 | 用途 |
|---|---|---|
| `X-Request-ID` | 请求，可选 | 客户端生成 ID，服务端在 `request_id` 中回显；若未提供则由服务端生成 |
| `Idempotency-Key` | 请求；下列标注的操作必填 | 每个逻辑操作使用一个键；重试同一操作时复用该键 |
| `If-Match` | 请求；更新存档时必填 | 客户端上次读取的带引号 `save_version`；首次存档使用 `"0"`（**提案**） |
| `If-None-Match` / `ETag` | 配置读取 | 配置未变时跳过响应正文 |

## 4. 操作

“幂等”说明如何使重复请求无害；“写入”列出服务端在同一事务中变更的内容。

### 认证

| 操作 | 认证 | 幂等方式 | 写入内容 |
|---|---|---|---|
| `POST /auth/wechat/login` | 公开 | 身份唯一键 | 首次登录时创建玩家和身份；创建会话与登录记录 |
| `POST /auth/refresh` | 公开（请求体中带 refresh token） | 已使用的令牌会被拒绝 | 新会话记录；撤销旧会话 |
| `POST /auth/logout` | 令牌 | 天然幂等 | 撤销会话 |

### 玩家、配置与存档

| 操作 | 幂等方式 | 写入内容 |
|---|---|---|
| `GET /player/profile` | 读取 | — |
| `PATCH /player/profile` | 最后写入者生效 | 玩家资料 |
| `GET /player/bootstrap` | 读取 | — |
| `GET /configs` | 读取，使用 `ETag` | — |
| `GET /configs/{key}` | 读取，使用 `ETag` | — |
| `GET /player/save` | 读取 | — |
| `PUT /player/save` | `If-Match` | 存档，`save_version + 1` |

`bootstrap` 返回玩家资料、服务器时间、`save_version`、钱包、配置索引和未读邮件数，因此客户端登录后只需调用一次。

昵称和头像属于用户生成内容。**（提案）** 服务端应校验长度和字符；接受昵称前应调用平台文本安全检测。

### 游戏玩法

| 操作 | 幂等方式 | 写入内容 |
|---|---|---|
| `POST /runs` | `Idempotency-Key` | 对局；若关卡设有入场消耗，则同时写入消耗及流水 |
| `POST /runs/{run_id}/settlement` | `Idempotency-Key`，且每场对局仅允许一次结算 | 结算、对局状态、奖励及流水 |

结算请求体是客户端的声明。响应会列出服务端实际发放的奖励和结算后的余额。若 `validation_status` 为 `rejected` 或 `review`，则不发放奖励。

### 经济系统与道具

| 操作 | 幂等方式 | 写入内容 |
|---|---|---|
| `GET /wallets` | 读取 | — |
| `GET /wallets/transactions` | 读取，游标分页 | — |
| `GET /items` | 读取 | — |

面向玩家的 API 不提供直接发放或扣除资产的端点。资产只能因结算、领取或对局消耗而变更。

### 广告

| 操作 | 幂等方式 | 写入内容 |
|---|---|---|
| `GET /ads/placements` | 读取 | — |
| `POST /ads/sessions` | `Idempotency-Key` | 广告会话 |
| `POST /ads/sessions/{session_id}/claim` | `Idempotency-Key`，且每个会话只能领取一次 | 领取记录、每日计数、奖励及流水 |

`client_completed` 表示客户端观察到 `isEnded`。它是证据，但不是证明。详见[数据权威模型](../architecture/data-authority-model.md#5-广告奖励)中的信任级别。

### 邮件、活动、排行榜与事件

| 操作 | 幂等方式 | 写入内容 |
|---|---|---|
| `GET /mails` | 读取，游标分页 | — |
| `PUT /mails/{mail_id}/read` | 保留首次设置的 `read_at` | 当前玩家邮件的 `read_at` |
| `POST /mails/{mail_id}/claim` | `Idempotency-Key`，且 `claimed_at` 仅设置一次 | `claimed_at`、附件及流水 |
| `GET /activities` | 读取 | — |
| `POST /activities/{activity_id}/claim` | `Idempotency-Key`，每项奖励仅可领取一次 | 领取记录、奖励及流水 |
| `GET /leaderboards/{board_code}` | 读取 | — |
| `POST /events/batch` | 每个事件提供 `event_id` | 事件 |

领取路径中的 `mail_id` 是玩家自己的邮件条目 ID，由 `GET /mails` 返回。

设计文档将排行榜路由写为 `/leaderboards/{id}`。契约使用 `board_code`，因为客户端从配置中获取排行榜代码，且没有列出排行榜 ID 的端点。

列出邮件不会改变已读状态。客户端调用 `PUT /mails/{mail_id}/read` 后，`bootstrap` 的 `unread_mail_count` 按未删除且 `read_at` 为空的条目计算。已读操作与附件领取独立。

## 5. 分页

列表操作接受 `cursor` 和 `limit`（1–100，默认 20），并返回 `next_cursor`；最后一页时该值为 `null`。游标是不透明值，客户端不得自行构造或修改。

## 6. 客户端重试规则

| 情况 | 规则 |
|---|---|
| 带 `Idempotency-Key` 的请求发生网络错误或超时 | 使用相同的键重试 |
| `5xx` | 退避重试；适用时复用相同的幂等键 |
| `401` | 刷新令牌一次后重试请求；刷新失败则重新登录 |
| `409`、`412`、`403`、`404` | 不要盲目重试；根据 `code` 处理 |
| `429` | 延迟后重试 |

不得根据已发出的请求推定奖励已经到账；客户端应以响应内容为准。

## 7. 建议的启动顺序

1. 调用 `wx.login()`，然后请求 `POST /auth/wechat/login`。
2. 请求 `GET /player/bootstrap`。
3. 对配置索引中校验和与本地副本不同的条目，调用 `GET /configs/{key}` 或从 CDN URL 下载。
4. 若 `save_version` 高于本地版本，则调用 `GET /player/save`。

## 8. 本 API 永不提供的能力

- 接受其他玩家 ID 的路由。
- 设置余额、发放道具或接受客户端提交奖励数量的路由。
- GM 操作。
