# Audit policy

- **Status:** Draft for review (2026-11-23)
- **Related:** [ADR-0005](../adr/ADR-0005-api-service-boundaries.md), [ADR-0007](../adr/ADR-0007-economy-transaction-model.md), [rbac-matrix.md](rbac-matrix.md)
- **Source:** sections 5.2 K and 7.3 of the [technical design](../game-platform-technical-design.md); tables `audit.admin_audit_logs` and `audit.service_audit_logs` in [schema.sql](../database/schema.sql)

Items marked **(proposal)** are not stated in the design document or an ADR and need confirmation.

## 1. Purpose

The audit log answers one question after the fact: who did what, to which target, in which game, when, why, and what changed. It is a business record, not a debugging log.

| | Audit log | Application log | Ledger |
|---|---|---|---|
| Stored in | PostgreSQL, `audit` schema | Log platform | PostgreSQL, `economy` schema |
| Written | In the transaction of the change | Best effort | In the transaction of the change |
| Content | Operator actions | Requests and errors | Asset changes |
| Can be lost | No | Yes | No |

## 2. What is audited

### 2.1 Every GM mutation

Each state-changing operation of `gm-api` writes exactly one row to `audit.admin_audit_logs`. `action` is the permission code that authorized it.

| `action` | `target_type` | `before_data` / `after_data` |
|---|---|---|
| `game.manage` | `game`, `game_platform_app`, `game_environment`, `game_setting` | Changed fields; never a secret, only `credential_ref` |
| `player.ban`, `player.unban` | `player` | Status and ban row |
| `player.save.restore` | `player_save` | `save_version` before and after, snapshot ID; not the save content |
| `economy.grant`, `economy.deduct` | `wallet` | Currency, amount, balance before and after, ledger row ID |
| `config.edit` | `game_config`, `config_version` | Key, version, checksum; not the full content |
| `config.publish` | `config_release` | Release ID, type, items, previous active versions |
| `mail.create` | `mail_message` | Title, target type, attachments |
| `mail.send` | `mail_message` | Status, reward job ID, target count |
| `activity.manage` | `activity` | Changed fields |
| `announcement.manage` | `announcement` | Changed fields |
| `ranking.manage` | `leaderboard` | Changed fields; rebuild request |
| `admin.manage` | `admin_user` | Status and assignments; never password or MFA material |
| `rbac.manage` | `role`, `admin_user_role` | Permission set or assignment before and after |

### 2.2 GM security events (proposal)

The design requires monitoring of abnormal logins but defines no table for administrator login history. These events go to the same table, with action codes outside the permission vocabulary:

| `action` | When |
|---|---|
| `auth.login` | Password step succeeded and MFA verified |
| `auth.login_failed` | Wrong password or unknown user; `admin_id` may be null |
| `auth.mfa_failed` | Wrong MFA code |
| `auth.locked` | Account locked after repeated failures |
| `auth.logout` | Session revoked by the administrator |
| `auth.mfa_enrolled`, `auth.mfa_reset` | MFA set up or reset |
| `auth.password_changed` | Password changed |
| `job.retry`, `job.cancel` | Manual action on a background job |

### 2.3 Service calls

When `internal-api` is deployed, every call writes one row to `audit.service_audit_logs`, including calls that were denied (`result = 'denied'`). The table is empty in V1.

### 2.4 Not audited in V1

- **Reads.** Viewing a player, a wallet or the audit log itself writes no audit row. They appear in the application log with `request_id` and administrator ID. Whether sensitive reads should be audited is an open question.
- **Player actions.** They are recorded by the ledgers, settlements, claims and login records.
- **Worker actions.** They are recorded by job rows and by the `actor_type = 'system'` columns of the rows they write.

## 3. Content of a record

| Column | Rule |
|---|---|
| `admin_id` | The authenticated administrator. Null only for failed logins of unknown users. |
| `game_id` | The game acted on. Null for platform-level actions. |
| `action` | From the tables above. New actions are added to this document first. |
| `target_type`, `target_id` | The entity acted on |
| `before_data`, `after_data` | Redacted snapshots or diffs (section 4) |
| `reason` | Mandatory for high-risk operations |
| `ticket_id` | Support or change ticket, when there is one |
| `request_id` | Links the row to application logs and traces |
| `ip` | Client address as seen at the edge |
| `created_at` | Server time |

## 4. Redaction

Never stored in an audit row, in any column:

- passwords and password hashes,
- access tokens, refresh tokens, challenge tokens,
- MFA secrets and recovery codes,
- WeChat AppSecret, `session_key`, service secrets, signing keys,
- full save content and full config content (store version, checksum and IDs instead).

Player identifiers (`player_id`, OpenID) may appear where they are the target. Redaction is done by the code that builds the record, with an allowlist of fields per `target_type`, not by a filter applied afterwards. **(proposal)**

## 5. Integrity

| Control | Detail |
|---|---|
| Same transaction | The audit row commits with the change. If the audit insert fails, the operation fails. There is no "change succeeded, audit lost" outcome. |
| Append-only by privilege | `gm_api_runtime` has `INSERT` and `SELECT` only; other runtime roles have nothing |
| Append-only by trigger | `system.reject_mutation()` rejects `UPDATE` and `DELETE` |
| Ownership | The tables are owned by a `NOLOGIN` role; nobody connects as the owner in normal operation |
| Failed attempts | Denied requests are not audited rows (nothing changed); they are counted in metrics and logged. Failed logins are the exception (section 2.2). |

**(proposal)** For stronger tamper evidence, export audit rows daily to object storage with object lock, or chain rows with a hash of the previous row. Neither is required for V1.

## 6. Access

- Reading requires `audit.read`. Results are limited to the games the reader is scoped to; platform-level rows need platform scope.
- `GET /gm/v1/audit-logs` filters by game, administrator, action, target and time, with cursor pagination.
- Nobody can edit or delete audit rows through any API.
- Direct database access to the `audit` schema by people follows the production access process and is itself logged by the database.

## 7. Retention

Retention periods are not decided; they are an open question in [decisions.md](../architecture/decisions.md) and depend on legal and business requirements.

Until a period is set, audit rows are not deleted. When it is set:

- rows inside the period are never deleted;
- older rows are archived to object storage before removal;
- removal is done by a migration-level procedure run by the owner role, because runtime roles cannot delete and the trigger must be bypassed deliberately.

The same applies to the economy ledgers.

## 8. Review and alerting (proposal)

| Signal | Action |
|---|---|
| Any `economy.grant` or `economy.deduct` above a per-game threshold | Alert to the game owner |
| Volume of adjustments by one administrator above a daily threshold | Alert |
| `rbac.manage`, `admin.manage` | Notify platform owners |
| `config.publish` | Notify the game channel |
| Repeated `auth.login_failed` or `auth.mfa_failed` | Alert; lockout applies |
| Login from a new network for an administrator | Notify that administrator |
| Weekly | Game owners review high-risk actions in their game |

Thresholds are set per game when the first game goes live.

## 9. Tests (T17, T21)

| Case | Expected |
|---|---|
| Each GM mutation in the contract | Exactly one audit row with the right action, target, game and administrator |
| The mutation fails and rolls back | No audit row |
| The audit insert is made to fail | The mutation is rolled back |
| `UPDATE` or `DELETE` on an audit row as any runtime role | Refused |
| Audit rows after password change, MFA enrollment, game creation | Contain no secret material |
| `GET /audit-logs` by a game-scoped auditor | Only that game's rows |
