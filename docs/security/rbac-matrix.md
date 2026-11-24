# RBAC 权限矩阵

- **状态** V1 权限基线。角色映射由 ADR-0010 确认，初始授权由 T15 迁移写入并测试。
- **相关：** [ADR-0005](../adr/ADR-0005-api-service-boundaries.md)、[认证与授权](../architecture/authentication-and-authorization.md)、[`gm-api.yaml`](../../api/openapi/gm-api.yaml)
- **来源：** [技术设计](../game-platform-technical-design.md)第 5.2 J 和 7.2 节

## 1. 模型

```text
权限 + 角色 + 管理员 + 游戏范围
```

- **权限**是服务端检查的一种操作代码。
- **角色**是一组具名权限。代码中绝不根据角色名称进行判断。
- **角色分配**为管理员授予角色，并指定 `platform` 范围或某个游戏范围。
- 若管理员的某项角色分配包含所需权限，且范围覆盖目标游戏，则请求获准。

## 2. 权限目录

`schema.sql` 中预置 25 个权限代码。“设计示例”表示该代码出现在设计文档的十一个示例中；其余代码为确保每项 GM 操作均有权限代码而新增。

| 代码 | 允许的操作 | 来源 | 高风险 |
|---|---|---|---|
| `game.read` | 查看游戏和平台应用配置 | 新增 | |
| `game.manage` | 创建和配置游戏、平台应用及环境 | 新增 | |
| `player.read` | 搜索和查看玩家 | 设计示例 | |
| `player.ban` | 封禁玩家 | 设计示例 | 是 |
| `player.unban` | 解除封禁 | 设计示例 | |
| `player.save.restore` | 从快照恢复存档 | 新增 | 是 |
| `economy.read` | 查看钱包、道具和流水 | 设计示例 | |
| `economy.grant` | 手动增加货币或道具 | 设计示例 | 是 |
| `economy.deduct` | 手动扣除货币或道具 | 新增 | 是 |
| `config.read` | 查看配置、版本和发布记录 | 设计示例 | |
| `config.edit` | 创建配置和草稿版本、执行校验 | 设计示例 | |
| `config.publish` | 发布或回滚版本 | 设计示例 | 是 |
| `mail.create` | 创建邮件草稿 | 设计示例 | |
| `mail.send` | 向玩家发送邮件 | 设计示例 | 是 |
| `activity.manage` | 创建和管理活动 | 新增 | |
| `announcement.manage` | 创建和管理公告 | 新增 | |
| `ranking.read` | 查看排行榜 | 新增 | |
| `ranking.manage` | 管理和重建排行榜 | 新增 | 是 |
| `job.read` | 查询本游戏的 GM 后台任务 | 新增 | |
| `job.manage` | 取消或重试本游戏的 GM 后台任务 | 新增 | 是 |
| `analytics.read` | 查看仪表盘和分析数据 | 新增 | |
| `admin.read` | 查看管理员和角色 | 新增 | |
| `admin.manage` | 创建和管理管理员 | 新增 | 是 |
| `rbac.manage` | 修改角色权限和分配关系 | 新增 | 是 |
| `audit.read` | 查询审计日志 | 设计示例 | |

## 3. V1 角色矩阵

| 权限 | 超级管理员 | 游戏管理员 | 运营人员 | 配置管理员 | 客服 | 分析员 | 审计员 |
|---|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| `game.read` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `game.manage` | ✓ | ✓ | | | | | |
| `player.read` | ✓ | ✓ | ✓ | | ✓ | | |
| `player.ban` | ✓ | ✓ | | | | | |
| `player.unban` | ✓ | ✓ | | | | | |
| `player.save.restore` | ✓ | ✓ | | | | | |
| `economy.read` | ✓ | ✓ | | | ✓ | | |
| `economy.grant` | ✓ | ✓ | | | | | |
| `economy.deduct` | ✓ | ✓ | | | | | |
| `config.read` | ✓ | ✓ | | ✓ | | | |
| `config.edit` | ✓ | ✓ | | ✓ | | | |
| `config.publish` | ✓ | ✓ | | ✓ | | | |
| `mail.create` | ✓ | ✓ | ✓ | | | | |
| `mail.send` | ✓ | ✓ | ✓ | | | | |
| `activity.manage` | ✓ | ✓ | ✓ | | | | |
| `announcement.manage` | ✓ | ✓ | ✓ | | | | |
| `ranking.read` | ✓ | ✓ | ✓ | | | ✓ | |
| `ranking.manage` | ✓ | ✓ | | | | | |
| `job.read` | ✓ | ✓ | ✓ | | | | |
| `job.manage` | ✓ | ✓ | | | | | |
| `analytics.read` | ✓ | ✓ | | | | ✓ | |
| `admin.read` | ✓ | | | | | | |
| `admin.manage` | ✓ | | | | | | |
| `rbac.manage` | ✓ | | | | | | |
| `audit.read` | ✓ | ✓ | | | | | ✓ |

| 角色 | `admin.roles` 中的代码 | 常规范围 | 权限数 |
|---|---|---|---:|
| 超级管理员 | `super_admin` | 平台 | 25 |
| 游戏管理员 | `game_admin` | 游戏 | 22 |
| 运营人员 | `operator` | 游戏 | 8 |
| 配置管理员 | `config_manager` | 游戏 | 4 |
| 客服 | `customer_support` | 游戏 | 3 |
| 分析员 | `analyst` | 游戏 | 3 |
| 审计员 | `auditor` | 游戏或平台 | 2 |

运营人员可查询已授权游戏的任务进度。任务读取只返回状态与计数，不返回任务载荷。客服仅保留已授权游戏的读取权限。封禁、解封和资产变更由具有相应权限的游戏管理员执行。

## 4. 范围规则

| 规则 | 说明 |
|---|---|
| 仅限平台级的操作 | 创建游戏、`admin.*`、`rbac.manage`。游戏范围的角色分配无法满足这些操作的授权 |
| 游戏范围内的 `game.manage` | 配置该游戏的平台应用、环境和设置；不允许创建游戏 |
| 列表 | `GET /games` 和 `GET /audit-logs` 仅返回管理员授权范围内的内容 |
| 平台级审计记录 | 只有具备平台范围 `audit.read` 权限时才可查看 |
| 多项角色分配 | 权限按各项分配合并，并针对每款游戏分别评估 |
| 不隐式授予全局权限 | 平台范围必须通过明确的分配记录表示；缺少 `game_id` 绝不代表所有游戏 |

## 5. 操作与权限对应关系

根据 `gm-api.yaml` 中的 `x-required-permission` 整理。

| 操作 | 权限 |
|---|---|
| `GET /games` | `game.read` |
| `POST /games` | `game.manage`（平台范围） |
| `GET .../players`、`GET .../players/{player_id}` | `player.read` |
| `POST .../players/{player_id}/ban` | `player.ban` |
| `POST .../players/{player_id}/unban` | `player.unban` |
| `POST .../players/{player_id}/save/restore` | `player.save.restore` |
| `GET .../players/{player_id}/wallets`、`GET .../transactions` | `economy.read` |
| `POST .../players/{player_id}/wallet-adjustments` | 正数为 `economy.grant`；负数为 `economy.deduct` |
| `GET .../configs` | `config.read` |
| `POST .../configs`、`.../versions`、`.../validate` | `config.edit` |
| `POST .../publish`、`.../rollback` | `config.publish` |
| `POST .../mails` | `mail.create` |
| `POST .../mails/{mail_id}/send` | `mail.send` |
| `POST .../activities` | `activity.manage` |
| `POST .../announcements` | `announcement.manage` |
| `GET .../leaderboards` | `ranking.read` |
| `GET /admins`、`GET /roles` | `admin.read` |
| `POST /admins` | `admin.manage` |
| `PUT /roles/{role_id}/permissions` | `rbac.manage` |
| `GET /audit-logs` | `audit.read` |
| `GET /analytics/overview` | `analytics.read` |
| `POST .../players/{player_id}/item-adjustments` | 正数为 `economy.grant`，负数为 `economy.deduct` |
| `POST .../reward-jobs` | `economy.grant` |
| 活动与公告查询、编辑、发布和停用 | `activity.manage` 或 `announcement.manage` |
| 排行榜创建和重建 | `ranking.manage` |
| 任务查询 | `job.read` |
| 任务取消与重试 | `job.manage` |

## 6. 模型自身的防护措施

- 预置的七个角色标记为 `is_system`。**（提案）** 系统角色只能由具备平台范围 `rbac.manage` 权限的管理员修改权限，且不可删除。
- **（提案）** 不允许停用最后一名有效超级管理员或移除其角色。
- **（提案）** 管理员不得修改自己的角色分配。
- 每次修改角色或分配关系都要审计变更前后的权限集。
- 角色变更在权限缓存 TTL 到期后生效。
- `role_permissions` 初始数据由 T15 迁移写入，并根据第 3 节已确认的矩阵生成。`schema.sql` 仅预置权限和角色。

## 7. 测试（T15、T21）

| 场景 | 预期结果 |
|---|---|
| 每种角色在其所属游戏中调用每项操作 | 仅在矩阵标记允许的位置通过 |
| 任一角色调用其未获授权游戏中的操作 | 返回 `403` |
| 仅获游戏范围授权的游戏管理员调用 `POST /games` | 返回 `403` |
| 客服调用 `wallet-adjustments`、封禁或解封 | 返回 `403` |
| 仅有 `economy.grant` 权限的用户提交负数 | 返回 `403` |
| 角色被撤销某项权限 | 权限缓存 TTL 过后，下一个请求被拒绝 |
| 未声明所需权限的操作 | 不得挂载路由 |
