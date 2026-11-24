# 审计策略

- **状态：** 评审草案
- **相关：** [ADR-0005](../adr/ADR-0005-api-service-boundaries.md)、[ADR-0007](../adr/ADR-0007-economy-transaction-model.md)、[RBAC 矩阵](rbac-matrix.md)
- **来源：** [技术设计](../game-platform-technical-design.md)第 5.2 K 和 7.3 节；[schema.sql](../database/schema.sql) 中的 `audit.admin_audit_logs` 和 `audit.service_audit_logs` 表

标记为**（提案）**的内容未在设计文档或 ADR 中说明，尚待确认。

## 1. 目的

审计日志用于事后回答：谁在何时、哪个游戏中、因何原因对什么目标执行了什么操作，造成了哪些变化。它是业务记录，不是调试日志。

| | 审计日志 | 应用日志 | 资产流水 |
|---|---|---|---|
| 存储位置 | PostgreSQL 的 `audit` Schema | 日志平台 | PostgreSQL 的 `economy` Schema |
| 写入方式 | 与变更在同一事务中 | 尽力写入 | 与变更在同一事务中 |
| 内容 | 操作员行为 | 请求和错误 | 资产变更 |
| 是否可丢失 | 否 | 是 | 否 |

## 2. 审计范围

### 2.1 每一项 GM 变更

`gm-api` 的每项业务变更都必须在 `audit.admin_audit_logs` 中同事务写入一条记录。`action` 通常为授权该操作的权限代码。任务取消与重试、身份认证事件使用第 2.2 节的操作代码。

| `action` | `target_type` | `before_data` / `after_data` |
|---|---|---|
| `game.manage` | `game`、`game_platform_app`、`game_environment`、`game_setting` | 变更字段；不含密钥，仅保存 `credential_ref` |
| `player.ban`、`player.unban` | `player` | 状态和封禁记录 |
| `player.save.restore` | `player_save` | 变更前后的 `save_version`、快照 ID；不含存档内容 |
| `economy.grant`、`economy.deduct` | `wallet`、`player_item`、`reward_job` | 货币或道具、变更前后状态及流水 ID，或批量奖励任务 ID 与目标范围 |
| `config.edit` | `game_config`、`config_version` | 键、版本、校验和；不含完整配置内容 |
| `config.publish` | `config_release` | 发布 ID、类型、发布项、之前启用的版本 |
| `mail.create` | `mail_message` | 标题、目标类型、附件 |
| `mail.send` | `mail_message` | 状态、奖励任务 ID、目标数量 |
| `activity.manage` | `activity` | 变更字段 |
| `announcement.manage` | `announcement` | 变更字段 |
| `ranking.manage` | `leaderboard` | 变更字段、重建请求 |
| `admin.manage` | `admin_user` | 状态和角色分配；不含密码或 MFA 材料 |
| `rbac.manage` | `role`、`admin_user_role` | 变更前后的权限集或分配关系 |

### 2.2 GM 安全与任务事件

以下安全和任务事件写入同一张表，并使用独立于权限代码的操作代码。

| `action` | 事件 |
|---|---|
| `auth.login` | 密码校验成功并通过 MFA |
| `auth.login_failed` | 密码错误或用户不存在；`admin_id` 可以为空 |
| `auth.mfa_failed` | MFA 验证码错误 |
| `auth.locked` | 多次失败后锁定账号 |
| `auth.logout` | 管理员撤销会话 |
| `auth.mfa_enrolled`、`auth.mfa_reset` | 注册或重置 MFA。注册审计与注册状态及会话同事务写入 |
| `auth.password_changed` | 修改密码 |
| `job.retry`、`job.cancel` | `job.manage` 授权的手动操作，审计与任务状态同事务写入 |

### 2.3 服务调用

部署 `internal-api` 后，每次调用（包括被拒绝的调用，`result = 'denied'`）都在 `audit.service_audit_logs` 中写入一条记录。V1 中该表为空。

### 2.4 V1 不审计的行为

- **读取操作。** 查看玩家、钱包或审计日志本身不会写入审计记录；相关信息记录在包含 `request_id` 和管理员 ID 的应用日志中。是否审计敏感数据读取仍待决定。
- **玩家操作。** 由资产流水、结算、领取记录和登录记录追踪。
- **Worker 操作。** 由任务记录及其写入记录中的 `actor_type = 'system'` 字段追踪。

## 3. 审计记录内容

| 列 | 规则 |
|---|---|
| `admin_id` | 已认证的管理员。仅当未知用户登录失败时为空 |
| `game_id` | 操作所属游戏。平台级操作时为空 |
| `action` | 使用上表中的代码；新增操作代码前先更新本文档 |
| `target_type`、`target_id` | 被操作的实体 |
| `before_data`、`after_data` | 脱敏后的快照或差异（见第 4 节） |
| `reason` | 高风险操作必填 |
| `ticket_id` | 有支持或变更工单时填写 |
| `request_id` | 将此记录关联到应用日志和链路追踪 |
| `ip` | 边缘入口观测到的客户端地址 |
| `created_at` | 服务端时间 |

## 4. 脱敏

审计记录中的任何列都不得保存以下内容：

- 密码及密码哈希；
- 访问令牌、刷新令牌、挑战令牌、MFA 注册令牌及配置 URI；
- MFA 密钥和恢复码；
- 微信 AppSecret、`session_key`、服务密钥和签名密钥；
- 完整存档或配置内容（改为保存版本、校验和与 ID）。

作为目标时可以出现玩家标识（`player_id`、OpenID）。**（提案）** 由构造记录的代码按 `target_type` 的字段允许列表完成脱敏，而非事后再过滤。

## 5. 完整性

| 控制 | 说明 |
|---|---|
| 同一事务 | 审计记录与变更一起提交。若插入审计记录失败，操作也失败；不存在“变更成功但审计丢失”的情况 |
| 通过权限只追加 | `gm_api_runtime` 对管理员审计日志仅有 `INSERT` 和 `SELECT` 权限。其他运行时角色无写入权限 |
| 通过触发器只追加 | `system.reject_mutation()` 拒绝 `UPDATE` 和 `DELETE` |
| 对象所有权 | 数据表归 `NOLOGIN` 角色所有；常规操作中无人以所有者身份连接 |
| 失败尝试 | 被拒绝的请求未更改数据，不写审计记录；改由指标和日志统计。失败登录除外（见第 2.2 节） |

**（提案）** 如需更强的防篡改证据，可每日将审计记录导出到启用对象锁的存储，或使用前一行哈希链接记录。V1 不强制要求。

## 6. 访问

- 读取需要 `audit.read` 权限，并限制在读取者获授权的游戏范围内；平台级记录需要平台级授权。
- `GET /gm/v1/audit-logs` 支持按游戏、管理员、操作、目标和时间过滤，并使用游标分页。
- 任何 API 都不得编辑或删除审计记录。
- 人员直接访问 `audit` Schema 必须遵循生产环境访问流程；数据库也会记录该访问。

## 7. 保留期限

临时基线为审计记录 2 年、资产流水 7 年。发布前按目标市场批准最终保留、删除与匿名化规则。在最终规则获批前，临时基线用于容量和归档设计。详见 [ADR-0010](../adr/ADR-0010-v1-decision-baseline.md)。

执行已批准策略时遵循下列规则。

- 保留期内的记录绝不删除；
- 更早的记录须先归档到对象存储，然后才能删除；
- 删除通过迁移级流程执行，使用对象所有者角色，因为运行时角色无删除权限，且必须有意绕过触发器。

经济流水采用同样策略。

## 8. 评审与告警（提案）

| 信号 | 操作 |
|---|---|
| `economy.grant` 或 `economy.deduct` 超过游戏级阈值 | 通知游戏负责人 |
| 单个管理员的调账次数或金额超过每日阈值 | 告警 |
| `rbac.manage`、`admin.manage` | 通知平台所有者 |
| `config.publish` | 通知游戏频道 |
| 反复出现 `auth.login_failed` 或 `auth.mfa_failed` | 告警；同时执行锁定策略 |
| 管理员从新网络登录 | 通知该管理员 |
| 每周检查 | 游戏负责人评审本游戏的高风险操作 |

首款游戏上线时按游戏设定阈值。

## 9. 测试（T17、T21）

| 场景 | 预期结果 |
|---|---|
| 契约中的每项 GM 变更 | 恰好一条审计记录，操作、目标、游戏和管理员均正确 |
| 变更失败并回滚 | 不产生审计记录 |
| 强制审计记录插入失败 | 变更回滚 |
| 任一运行时角色尝试 `UPDATE` 或 `DELETE` 审计记录 | 操作被拒绝 |
| 修改密码、注册 MFA、创建游戏后的审计记录 | 不含任何密钥材料 |
| 游戏范围内的审计员调用 `GET /audit-logs` | 仅返回该游戏记录 |
