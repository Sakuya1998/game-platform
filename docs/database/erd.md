# PostgreSQL ERD

The ERD is a domain-level view. The executable source of truth is [schema.sql](schema.sql). Most game-owned tables include `game_id`; composite foreign keys prevent cross-game references.

```mermaid
erDiagram
  GAMES ||--o{ GAME_APPS : configures
  GAMES ||--o{ PLAYERS : owns
  GAMES ||--o{ GAME_CONFIGS : defines
  GAMES ||--o{ ADMINS : scopes
  PLAYERS ||--o{ PLAYER_IDENTITIES : authenticates
  PLAYERS ||--o{ PLAYER_SESSIONS : has
  PLAYERS ||--o{ PLAYER_SAVES : stores
  PLAYERS ||--o{ GAME_RUNS : plays
  GAME_RUNS ||--o| RUN_SETTLEMENTS : settles
  PLAYERS ||--|| WALLETS : owns
  WALLETS ||--o{ WALLET_TRANSACTIONS : ledger
  PLAYERS ||--o{ PLAYER_ITEMS : owns
  PLAYER_ITEMS ||--o{ ITEM_TRANSACTIONS : ledger
  PLAYERS ||--o{ AD_SESSIONS : watches
  AD_SESSIONS ||--o| AD_REWARD_CLAIMS : claims
  GAMES ||--o{ MAILS : publishes
  MAILS ||--o{ PLAYER_MAIL : targets
  PLAYERS ||--o{ PLAYER_MAIL : receives
  GAMES ||--o{ ACTIVITIES : publishes
  ACTIVITIES ||--o{ ACTIVITY_CLAIMS : grants
  PLAYERS ||--o{ ACTIVITY_CLAIMS : claims
  GAMES ||--o{ ADMINS : manages
  ADMINS ||--o{ ADMIN_USER_ROLES : assigned
  ROLES ||--o{ ADMIN_USER_ROLES : contains
  ROLES ||--o{ ROLE_PERMISSIONS : grants
  PERMISSIONS ||--o{ ROLE_PERMISSIONS : included
  ADMINS ||--o{ ADMIN_AUDIT_LOGS : acts
```

## Relationship and key rules

- `games.id` is the game namespace. `players` has a composite unique key `(game_id, id)`.
- External identity uniqueness is `(game_id, platform, app_id, openid)`; `unionid` is not a cross-game account key.
- All player-owned references include `game_id` in their foreign key.
- Wallet balance is a cached current balance; `wallet_transactions` is the immutable accounting ledger.
- Item quantity is a current projection; `item_transactions` records changes.
- A game run can be settled at most once; a settlement references a unique run.
- An ad session can create at most one reward claim per reward type/session policy.
- Admin authorization is role + permission + game scope. Audit rows are append-only by privilege policy.
- Config payloads may live in object storage; PostgreSQL stores version, checksum, object key, validation and release metadata.
