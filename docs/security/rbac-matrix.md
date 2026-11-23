# RBAC matrix

- **Status:** Draft for review (2026-11-23). The role-to-permission mapping in section 3 is a **proposal**: the design names the seven roles and their main duties, and lists eleven example permission codes; the rest is derived here and needs confirmation before it is seeded.
- **Related:** [ADR-0005](../adr/ADR-0005-api-service-boundaries.md), [authentication-and-authorization.md](../architecture/authentication-and-authorization.md), [`gm-api.yaml`](../../api/openapi/gm-api.yaml)
- **Source:** sections 5.2 J and 7.2 of the [technical design](../game-platform-technical-design.md)

## 1. Model

```text
Permission  +  Role  +  Admin user  +  Game scope
```

- A **permission** is a code checked by the server for one kind of operation.
- A **role** is a named set of permissions. Code never tests a role name.
- An **assignment** gives a role to an administrator at `platform` scope or for one game.
- A request is allowed when some assignment of the administrator contains the required permission and covers the target game.

## 2. Permission catalogue

The 23 codes seeded by `schema.sql`. "Design" marks the eleven codes given as examples in the design document; the others were added so that every GM operation has a code.

| Code | Allows | Origin | High risk |
|---|---|---|---|
| `game.read` | View games and platform app configuration | Added | |
| `game.manage` | Create and configure games, platform apps, environments | Added | |
| `player.read` | Search and view players | Design | |
| `player.ban` | Ban a player | Design | Yes |
| `player.unban` | Lift a ban | Design | |
| `player.save.restore` | Restore a save from a snapshot | Added | Yes |
| `economy.read` | View wallets, items and ledgers | Design | |
| `economy.grant` | Manually credit currency or items | Design | Yes |
| `economy.deduct` | Manually debit currency or items | Added | Yes |
| `config.read` | View configs, versions and releases | Design | |
| `config.edit` | Create configs and draft versions, run validation | Design | |
| `config.publish` | Publish or roll back a release | Design | Yes |
| `mail.create` | Create mail drafts | Design | |
| `mail.send` | Send mail to players | Design | Yes |
| `activity.manage` | Create and manage activities | Added | |
| `announcement.manage` | Create and manage announcements | Added | |
| `ranking.read` | View leaderboards | Added | |
| `ranking.manage` | Manage and rebuild leaderboards | Added | |
| `analytics.read` | View dashboards and analytics | Added | |
| `admin.read` | View administrators and roles | Added | |
| `admin.manage` | Create and manage administrators | Added | Yes |
| `rbac.manage` | Change role permissions and assignments | Added | Yes |
| `audit.read` | Query audit logs | Design | |

## 3. Role matrix (proposal)

| Permission | Super Admin | Game Admin | Operator | Config Manager | Customer Support | Analyst | Auditor |
|---|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| `game.read` | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| `game.manage` | ✓ | ✓ | | | | | |
| `player.read` | ✓ | ✓ | ✓ | | ✓ | | |
| `player.ban` | ✓ | ✓ | | | ✓ | | |
| `player.unban` | ✓ | ✓ | | | ✓ | | |
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
| `analytics.read` | ✓ | ✓ | | | | ✓ | |
| `admin.read` | ✓ | | | | | | |
| `admin.manage` | ✓ | | | | | | |
| `rbac.manage` | ✓ | | | | | | |
| `audit.read` | ✓ | ✓ | | | | | ✓ |

| Role | Code in `admin.roles` | Normal scope | Count |
|---|---|---|---|
| Super Admin | `super_admin` | Platform | 23 |
| Game Admin | `game_admin` | Game | 20 |
| Operator | `operator` | Game | 7 |
| Config Manager | `config_manager` | Game | 4 |
| Customer Support | `customer_support` | Game | 5 |
| Analyst | `analyst` | Game | 3 |
| Auditor | `auditor` | Game or platform | 2 |

### Choices that need a decision

| Choice made here | Alternative | Why it matters |
|---|---|---|
| Customer Support can ban and unban | Read-only support; bans by Game Admin | The design says support does "player lookup and support operations" without listing them |
| Customer Support cannot restore saves | Allow it | Restore is the most common support request and also destroys the current save |
| Customer Support cannot adjust wallets | — | Stated by the design: support must not have adjustment rights by default |
| Operator holds both `mail.create` and `mail.send` | Split creation and sending between two people | A mail with attachments is a way to grant assets to every player |
| Config Manager holds both `config.edit` and `config.publish` | Split editing and publishing | The design gives this role "edit and publish"; splitting adds a review step |
| Game Admin holds `economy.grant` and `economy.deduct` | A separate economy role | Keeps the role count at seven, as in the design |
| Operator has no `analytics.read` | Give it | Operators may need activity results |
| Game Admin has no `admin.read` | Let Game Admins see who else is assigned to their game | Needs game-scoped filtering of the administrator list |

## 4. Scope rules

| Rule | Detail |
|---|---|
| Platform-only operations | Creating a game, `admin.*`, `rbac.manage`. A game-scoped assignment never satisfies them. |
| `game.manage` at game scope | Configure that game's apps, environments and settings; it does not allow creating games |
| Lists | `GET /games` and `GET /audit-logs` return only what the administrator's assignments cover |
| Platform-level audit entries | Visible only with `audit.read` at platform scope |
| Several assignments | Permissions are the union across assignments, evaluated per game |
| No implicit global | Platform scope is an explicit assignment row; an absent game never means all games |

## 5. Operation to permission

Taken from `x-required-permission` in `gm-api.yaml`.

| Operation | Permission |
|---|---|
| `GET /games` | `game.read` |
| `POST /games` | `game.manage` (platform) |
| `GET .../players`, `GET .../players/{player_id}` | `player.read` |
| `POST .../players/{player_id}/ban` | `player.ban` |
| `POST .../players/{player_id}/unban` | `player.unban` |
| `POST .../players/{player_id}/save/restore` | `player.save.restore` |
| `GET .../players/{player_id}/wallets`, `GET .../transactions` | `economy.read` |
| `POST .../players/{player_id}/wallet-adjustments` | `economy.grant` (positive), `economy.deduct` (negative) |
| `GET .../configs` | `config.read` |
| `POST .../configs`, `.../versions`, `.../validate` | `config.edit` |
| `POST .../publish`, `.../rollback` | `config.publish` |
| `POST .../mails` | `mail.create` |
| `POST .../mails/{mail_id}/send` | `mail.send` |
| `POST .../activities` | `activity.manage` |
| `POST .../announcements` | `announcement.manage` |
| `GET .../leaderboards` | `ranking.read` |
| `GET /admins`, `GET /roles` | `admin.read` |
| `POST /admins` | `admin.manage` |
| `PUT /roles/{role_id}/permissions` | `rbac.manage` |
| `GET /audit-logs` | `audit.read` |
| `GET /analytics/overview` | `analytics.read` |

`ranking.manage` has no operation in the contract yet; it is reserved for leaderboard creation and rebuild.

## 6. Safeguards on the model itself

- The seven seeded roles are marked `is_system`. **(proposal)** System roles can have their permissions changed only by `rbac.manage` at platform scope, and cannot be deleted.
- **(proposal)** The last active Super Admin cannot be disabled or stripped of the role.
- **(proposal)** An administrator cannot change their own role assignments.
- Every role and assignment change is audited with the before and after permission set.
- A role change takes effect within the permission cache TTL.
- The `role_permissions` seed is added by a migration in T15, generated from the confirmed version of the matrix in section 3. `schema.sql` seeds permissions and roles only.

## 7. Tests (T15, T21)

| Case | Expected |
|---|---|
| Each role calls each operation in its game | Allowed exactly where the matrix has a mark |
| Any role calls an operation in a game it is not assigned to | `403` |
| Game-scoped Game Admin calls `POST /games` | `403` |
| Customer Support calls `wallet-adjustments` | `403` |
| Holder of `economy.grant` only sends a negative amount | `403` |
| Role loses a permission | Next request after the cache TTL is denied |
| An operation with no declared permission | Not routable |
