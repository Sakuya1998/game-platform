-- 游戏平台 PostgreSQL 基线结构（设计基线 v2.0，2026-11-23）
-- 目标版本：PostgreSQL 16+
--
-- 本文件是经评审的数据库设计基线，对应技术设计第 5.2 节中的数据表集合。
-- 本文件不是已应用的迁移，尚未
-- 在数据库中执行。T03 任务会将其拆分为有序、不可变的迁移文件
-- 并置于 `/migrations` 下（000001_create_schemas、000002_create_platform 等）。
--
-- 规则：
--   * 使用专用迁移角色执行。运行时角色（game_api_runtime、gm_api_runtime、
--     game_worker_runtime）绝不是对象所有者或超级用户。
--   * 每张游戏归属表都包含 game_id。游戏内跨表引用使用包含 game_id 的
--     复合外键，防止记录跨游戏引用。
--   * 金额和数量均使用最小单位整数，不使用浮点数。
--   * 所有时间戳均为 timestamptz（以 UTC 存储）。
--   * 与设计文档逻辑字段列表不同的命名，记录在
--     docs/database/erd.md（“与设计文档的差异”）中。

BEGIN;

CREATE SCHEMA IF NOT EXISTS platform;
CREATE SCHEMA IF NOT EXISTS auth;
CREATE SCHEMA IF NOT EXISTS player;
CREATE SCHEMA IF NOT EXISTS game;
CREATE SCHEMA IF NOT EXISTS gameplay;
CREATE SCHEMA IF NOT EXISTS economy;
CREATE SCHEMA IF NOT EXISTS ads;
CREATE SCHEMA IF NOT EXISTS operation;
CREATE SCHEMA IF NOT EXISTS ranking;
CREATE SCHEMA IF NOT EXISTS admin;
CREATE SCHEMA IF NOT EXISTS audit;
CREATE SCHEMA IF NOT EXISTS analytics;
CREATE SCHEMA IF NOT EXISTS system;

-- 只追加数据表（流水和审计日志）的共用保护触发器。
-- 权限限制（仅 INSERT/SELECT）是第一道防线；本触发器是第二道防线。
CREATE FUNCTION system.reject_mutation() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION '% on %.% is not allowed: table is append-only',
        TG_OP, TG_TABLE_SCHEMA, TG_TABLE_NAME
        USING ERRCODE = 'insufficient_privilege';
END;
$$;

-- ---------------------------------------------------------------------------
-- A. platform — 游戏和平台配置
-- ---------------------------------------------------------------------------

CREATE TABLE platform.games (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code text NOT NULL UNIQUE CHECK (code ~ '^[a-z][a-z0-9_-]{1,62}$'),
    name text NOT NULL,
    status text NOT NULL DEFAULT 'active' CHECK (status IN ('active','disabled','archived')),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE platform.game_platform_apps (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    game_id uuid NOT NULL REFERENCES platform.games(id),
    platform text NOT NULL CHECK (platform IN
        ('wechat_minigame','douyin_minigame','alipay_minigame','android','ios','web')),
    app_id text NOT NULL,
    credential_ref text NOT NULL, -- secret-manager reference; never the AppSecret itself
    status text NOT NULL DEFAULT 'active' CHECK (status IN ('active','disabled')),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (game_id, id),
    UNIQUE (game_id, platform, app_id),
    -- 一个平台应用只属于一款游戏，因此登录时服务端可根据
    -- (platform, app_id) 解析 game_id，而不信任客户端传入的 game_id。
    UNIQUE (platform, app_id)
);

CREATE TABLE platform.game_settings (
    game_id uuid NOT NULL REFERENCES platform.games(id),
    setting_key text NOT NULL,
    setting_value jsonb NOT NULL DEFAULT '{}'::jsonb,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (game_id, setting_key)
);

-- 游戏在各环境中的描述信息（端点、CDN 基础地址、测试应用绑定）。
-- 不同环境的玩家数据仍存放于各自独立的数据库。
CREATE TABLE platform.game_environments (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    game_id uuid NOT NULL REFERENCES platform.games(id),
    environment text NOT NULL CHECK (environment IN ('development','staging','production')),
    api_base_url text,
    cdn_base_url text,
    settings jsonb NOT NULL DEFAULT '{}'::jsonb,
    status text NOT NULL DEFAULT 'active' CHECK (status IN ('active','disabled')),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (game_id, id),
    UNIQUE (game_id, environment)
);

-- ---------------------------------------------------------------------------
-- J. admin — GM 身份与 RBAC（与玩家平面相互隔离）
-- ---------------------------------------------------------------------------

CREATE TABLE admin.admin_users (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    username text NOT NULL UNIQUE,
    email text UNIQUE,
    display_name text,
    password_hash text NOT NULL,
    status text NOT NULL DEFAULT 'active' CHECK (status IN ('active','disabled','locked')),
    failed_login_count integer NOT NULL DEFAULT 0 CHECK (failed_login_count >= 0),
    locked_until timestamptz,
    last_login_at timestamptz,
    password_changed_at timestamptz,
    created_by uuid REFERENCES admin.admin_users(id),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE admin.roles (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code text NOT NULL UNIQUE,
    name text NOT NULL,
    description text,
    is_system boolean NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE admin.permissions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code text NOT NULL UNIQUE,
    description text NOT NULL
);

-- 授权依据为 (admin, permission, game scope)。
-- 平台级范围通过 scope_type 明确表示，绝不隐式使用 NULL。
CREATE TABLE admin.admin_user_roles (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    admin_id uuid NOT NULL REFERENCES admin.admin_users(id),
    role_id uuid NOT NULL REFERENCES admin.roles(id),
    scope_type text NOT NULL CHECK (scope_type IN ('platform','game')),
    game_id uuid REFERENCES platform.games(id),
    granted_by uuid REFERENCES admin.admin_users(id),
    granted_at timestamptz NOT NULL DEFAULT now(),
    CHECK ((scope_type = 'platform' AND game_id IS NULL)
        OR (scope_type = 'game' AND game_id IS NOT NULL))
);
CREATE UNIQUE INDEX admin_user_roles_game_uniq
    ON admin.admin_user_roles (admin_id, role_id, game_id) WHERE scope_type = 'game';
CREATE UNIQUE INDEX admin_user_roles_platform_uniq
    ON admin.admin_user_roles (admin_id, role_id) WHERE scope_type = 'platform';

CREATE TABLE admin.role_permissions (
    role_id uuid NOT NULL REFERENCES admin.roles(id),
    permission_id uuid NOT NULL REFERENCES admin.permissions(id),
    PRIMARY KEY (role_id, permission_id)
);

CREATE TABLE admin.admin_sessions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    admin_id uuid NOT NULL REFERENCES admin.admin_users(id),
    refresh_token_hash bytea NOT NULL UNIQUE,
    mfa_verified_at timestamptz,
    ip inet,
    user_agent text,
    expires_at timestamptz NOT NULL,
    revoked_at timestamptz,
    rotated_from uuid REFERENCES admin.admin_sessions(id),
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX admin_sessions_admin_idx ON admin.admin_sessions (admin_id, created_at DESC);
CREATE INDEX admin_sessions_expiry_idx ON admin.admin_sessions (expires_at) WHERE revoked_at IS NULL;

CREATE TABLE admin.admin_mfa (
    admin_id uuid PRIMARY KEY REFERENCES admin.admin_users(id),
    mfa_type text NOT NULL DEFAULT 'totp' CHECK (mfa_type IN ('totp')),
    secret_encrypted bytea NOT NULL, -- encrypted with a KMS-managed key; never plaintext
    enabled boolean NOT NULL DEFAULT false,
    recovery_codes_hash jsonb NOT NULL DEFAULT '[]'::jsonb,
    enrolled_at timestamptz,
    last_verified_at timestamptz,
    updated_at timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- M. system — 幂等、Outbox、后台任务、服务身份
-- ---------------------------------------------------------------------------

CREATE TABLE system.idempotency_keys (
    scope text NOT NULL, -- e.g. '<entry>:<game_id>:<actor_id>:<route>'
    idempotency_key text NOT NULL,
    request_hash text NOT NULL,
    state text NOT NULL DEFAULT 'processing' CHECK (state IN ('processing','completed','failed')),
    response_status integer,
    response_body jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    PRIMARY KEY (scope, idempotency_key)
);
CREATE INDEX idempotency_keys_expiry_idx ON system.idempotency_keys (expires_at);

CREATE TABLE system.outbox_events (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    game_id uuid REFERENCES platform.games(id),
    aggregate_type text NOT NULL,
    aggregate_id text NOT NULL,
    event_type text NOT NULL,
    payload jsonb NOT NULL,
    occurred_at timestamptz NOT NULL DEFAULT now(),
    published_at timestamptz,
    attempts integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    next_attempt_at timestamptz NOT NULL DEFAULT now(),
    last_error text
);
CREATE INDEX outbox_pending_idx ON system.outbox_events (next_attempt_at, occurred_at)
    WHERE published_at IS NULL;

-- 基于 PostgreSQL 的 game-worker 任务队列。使用
-- SELECT ... FOR UPDATE SKIP LOCKED 领取任务，再持有并通过心跳续期。
CREATE TABLE system.background_jobs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    game_id uuid REFERENCES platform.games(id),
    job_type text NOT NULL,
    payload jsonb NOT NULL DEFAULT '{}'::jsonb,
    status text NOT NULL DEFAULT 'pending' CHECK (status IN
        ('pending','running','succeeded','failed','retrying','cancelled')),
    priority integer NOT NULL DEFAULT 0,
    retry_count integer NOT NULL DEFAULT 0 CHECK (retry_count >= 0),
    max_retries integer NOT NULL DEFAULT 5 CHECK (max_retries >= 0),
    run_at timestamptz NOT NULL DEFAULT now(), -- earliest execution time (backoff target)
    lease_owner text,
    lease_expires_at timestamptz,
    heartbeat_at timestamptz,
    last_error text,
    dedupe_key text,
    created_by_type text NOT NULL DEFAULT 'system' CHECK (created_by_type IN
        ('player','admin','service','system')),
    created_by_id text,
    created_at timestamptz NOT NULL DEFAULT now(),
    started_at timestamptz,
    finished_at timestamptz
);
CREATE INDEX background_jobs_claim_idx ON system.background_jobs (priority DESC, run_at)
    WHERE status IN ('pending','retrying');
CREATE INDEX background_jobs_lease_idx ON system.background_jobs (lease_expires_at)
    WHERE status = 'running';
CREATE UNIQUE INDEX background_jobs_dedupe_uniq ON system.background_jobs (job_type, dedupe_key)
    WHERE dedupe_key IS NOT NULL;

CREATE TABLE system.service_identities (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    service_code text NOT NULL UNIQUE,
    name text NOT NULL,
    status text NOT NULL DEFAULT 'active' CHECK (status IN ('active','disabled')),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

-- HMAC 验证需要签名密钥，因此对于
-- 'hmac' 凭据，单向哈希并不足够：密钥保存在密钥管理器中，并通过 secret_ref 引用。
-- 对于 'mtls' 凭据，credential_hash 保存证书的 SHA-256 指纹。
CREATE TABLE system.service_credentials (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    service_id uuid NOT NULL REFERENCES system.service_identities(id),
    credential_type text NOT NULL CHECK (credential_type IN ('hmac','mtls')),
    access_key_id text UNIQUE,
    secret_ref text,
    credential_hash bytea,
    status text NOT NULL DEFAULT 'active' CHECK (status IN ('active','revoked')),
    expires_at timestamptz,
    revoked_at timestamptz,
    last_used_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    CHECK ((credential_type = 'hmac' AND access_key_id IS NOT NULL AND secret_ref IS NOT NULL)
        OR (credential_type = 'mtls' AND credential_hash IS NOT NULL))
);
CREATE INDEX service_credentials_service_idx ON system.service_credentials (service_id);

CREATE TABLE system.service_game_grants (
    service_id uuid NOT NULL REFERENCES system.service_identities(id),
    game_id uuid NOT NULL REFERENCES platform.games(id),
    permission_code text NOT NULL,
    granted_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (service_id, game_id, permission_code)
);

-- ---------------------------------------------------------------------------
-- C. player — 玩家主体、资料、存档、封禁
-- ---------------------------------------------------------------------------

CREATE TABLE player.players (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    game_id uuid NOT NULL REFERENCES platform.games(id),
    status text NOT NULL DEFAULT 'active' CHECK (status IN ('active','banned','deleted')),
    last_login_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (game_id, id)
);
CREATE INDEX players_game_created_idx ON player.players (game_id, created_at DESC);

CREATE TABLE player.player_profiles (
    game_id uuid NOT NULL,
    player_id uuid NOT NULL,
    nickname text,
    avatar_url text,
    extra jsonb NOT NULL DEFAULT '{}'::jsonb,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (game_id, player_id),
    FOREIGN KEY (game_id, player_id) REFERENCES player.players (game_id, id)
);
CREATE INDEX player_profiles_nickname_idx ON player.player_profiles (game_id, nickname);

-- 当前存档。仅保存非权威游戏状态；钱包、道具和权益
-- 保存在各自的数据表中，绝不从 save_data 推导。
CREATE TABLE player.player_saves (
    game_id uuid NOT NULL,
    player_id uuid NOT NULL,
    save_data jsonb NOT NULL,
    schema_version integer NOT NULL CHECK (schema_version > 0),
    save_version bigint NOT NULL DEFAULT 1 CHECK (save_version > 0), -- optimistic lock / ETag
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (game_id, player_id),
    FOREIGN KEY (game_id, player_id) REFERENCES player.players (game_id, id)
);

CREATE TABLE player.player_save_snapshots (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    game_id uuid NOT NULL,
    player_id uuid NOT NULL,
    save_data jsonb NOT NULL,
    schema_version integer NOT NULL CHECK (schema_version > 0),
    save_version bigint NOT NULL CHECK (save_version > 0),
    snapshot_reason text NOT NULL DEFAULT 'scheduled' CHECK (snapshot_reason IN
        ('scheduled','before_restore','manual')),
    created_by_type text NOT NULL DEFAULT 'system' CHECK (created_by_type IN
        ('player','admin','service','system')),
    created_by_id text,
    created_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (game_id, player_id) REFERENCES player.players (game_id, id),
    UNIQUE (game_id, id),
    UNIQUE (game_id, player_id, save_version)
);

CREATE TABLE player.player_bans (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    game_id uuid NOT NULL,
    player_id uuid NOT NULL,
    reason text NOT NULL,
    ticket_id text,
    starts_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz, -- NULL = until revoked
    banned_by uuid REFERENCES admin.admin_users(id),
    revoked_at timestamptz,
    revoked_by uuid REFERENCES admin.admin_users(id),
    revoke_reason text,
    created_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (game_id, player_id) REFERENCES player.players (game_id, id),
    UNIQUE (game_id, id),
    CHECK (expires_at IS NULL OR expires_at > starts_at)
);
CREATE INDEX player_bans_player_idx ON player.player_bans (game_id, player_id, starts_at DESC);
CREATE INDEX player_bans_active_idx ON player.player_bans (game_id, player_id)
    WHERE revoked_at IS NULL;

-- ---------------------------------------------------------------------------
-- B. auth — 外部身份映射、玩家会话、登录记录
-- ---------------------------------------------------------------------------

CREATE TABLE auth.player_identities (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    game_id uuid NOT NULL,
    player_id uuid NOT NULL,
    platform text NOT NULL,
    app_id text NOT NULL,
    openid text NOT NULL,
    unionid text, -- stored for diagnostics only; never merges players across games
    created_at timestamptz NOT NULL DEFAULT now(),
    last_login_at timestamptz,
    FOREIGN KEY (game_id, player_id) REFERENCES player.players (game_id, id),
    FOREIGN KEY (game_id, platform, app_id)
        REFERENCES platform.game_platform_apps (game_id, platform, app_id),
    UNIQUE (game_id, id),
    UNIQUE (game_id, platform, app_id, openid)
);
CREATE INDEX player_identities_player_idx ON auth.player_identities (game_id, player_id);

CREATE TABLE auth.player_sessions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    game_id uuid NOT NULL,
    player_id uuid NOT NULL,
    refresh_token_hash bytea NOT NULL UNIQUE, -- hash only; plaintext is never stored
    device_id text,
    expires_at timestamptz NOT NULL,
    revoked_at timestamptz,
    rotated_from uuid,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (game_id, player_id, id),
    FOREIGN KEY (game_id, player_id) REFERENCES player.players (game_id, id),
    FOREIGN KEY (game_id, player_id, rotated_from)
        REFERENCES auth.player_sessions (game_id, player_id, id)
);
CREATE INDEX player_sessions_player_idx ON auth.player_sessions (game_id, player_id);
CREATE INDEX player_sessions_expiry_idx ON auth.player_sessions (expires_at)
    WHERE revoked_at IS NULL;

CREATE TABLE auth.login_records (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    game_id uuid NOT NULL REFERENCES platform.games(id),
    player_id uuid, -- NULL when login failed before a player was resolved
    platform text NOT NULL,
    app_id text,
    result text NOT NULL CHECK (result IN ('success','failed','blocked')),
    failure_code text, -- diagnosable error code; never the WeChat code, session_key or tokens
    ip inet,
    device_id text,
    request_id text,
    created_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (game_id, player_id) REFERENCES player.players (game_id, id)
);
CREATE INDEX login_records_player_idx ON auth.login_records (game_id, player_id, created_at DESC);
CREATE INDEX login_records_time_idx ON auth.login_records (game_id, created_at DESC);

-- ---------------------------------------------------------------------------
-- D. game — 配置定义、版本和发布
-- ---------------------------------------------------------------------------

CREATE TABLE game.game_configs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    game_id uuid NOT NULL REFERENCES platform.games(id),
    config_key text NOT NULL,
    description text,
    json_schema jsonb, -- JSON Schema used by the Validate step
    status text NOT NULL DEFAULT 'active' CHECK (status IN ('active','archived')),
    created_by uuid REFERENCES admin.admin_users(id),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (game_id, id),
    UNIQUE (game_id, config_key)
);

-- 版本离开 'draft' 状态后不可变。大型负载存入对象存储
-- （object_key）；PostgreSQL 保存元数据和校验和。
CREATE TABLE game.config_versions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    game_id uuid NOT NULL,
    config_id uuid NOT NULL,
    version integer NOT NULL CHECK (version > 0),
    content jsonb,
    object_key text,
    checksum_sha256 text NOT NULL,
    schema_version integer NOT NULL DEFAULT 1 CHECK (schema_version > 0),
    status text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','validated','invalid','published')),
    validation_errors jsonb,
    validated_at timestamptz,
    created_by uuid REFERENCES admin.admin_users(id),
    created_at timestamptz NOT NULL DEFAULT now(),
    CHECK (content IS NOT NULL OR object_key IS NOT NULL),
    FOREIGN KEY (game_id, config_id) REFERENCES game.game_configs (game_id, id),
    UNIQUE (game_id, id),
    UNIQUE (game_id, config_id, id),
    UNIQUE (game_id, config_id, version)
);

-- 发布记录是不可变的发布事件。回滚会创建新的发布记录，其发布项
-- 指向较早版本；不会覆盖任何内容。
CREATE TABLE game.config_releases (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    game_id uuid NOT NULL REFERENCES platform.games(id),
    release_no bigint GENERATED ALWAYS AS IDENTITY, -- monotonic ordering of releases
    release_type text NOT NULL DEFAULT 'publish' CHECK (release_type IN ('publish','rollback')),
    rollback_of_release_id uuid,
    reason text,
    released_by uuid REFERENCES admin.admin_users(id),
    released_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (game_id, id),
    UNIQUE (release_no),
    FOREIGN KEY (game_id, rollback_of_release_id) REFERENCES game.config_releases (game_id, id),
    CHECK (release_type <> 'rollback' OR rollback_of_release_id IS NOT NULL)
);
CREATE INDEX config_releases_game_idx ON game.config_releases (game_id, release_no DESC);

-- 配置的生效版本是其最新发布记录（release_no 最高）中的发布项。
CREATE TABLE game.config_release_items (
    game_id uuid NOT NULL,
    release_id uuid NOT NULL,
    config_id uuid NOT NULL,
    version_id uuid NOT NULL,
    PRIMARY KEY (game_id, release_id, config_id),
    FOREIGN KEY (game_id, release_id) REFERENCES game.config_releases (game_id, id),
    FOREIGN KEY (game_id, config_id, version_id)
        REFERENCES game.config_versions (game_id, config_id, id)
);
CREATE INDEX config_release_items_config_idx ON game.config_release_items (game_id, config_id);

-- ---------------------------------------------------------------------------
-- E. gameplay — 对局、单次结算、对局事件
-- ---------------------------------------------------------------------------

CREATE TABLE gameplay.game_runs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(), -- server-generated, unguessable
    game_id uuid NOT NULL,
    player_id uuid NOT NULL,
    level_id text NOT NULL,
    difficulty text,
    mode text,
    rule_version text, -- config release / rule snapshot the run was created under
    run_context jsonb NOT NULL DEFAULT '{}'::jsonb, -- server-side snapshot (costs, caps, seed)
    status text NOT NULL DEFAULT 'started' CHECK (status IN
        ('started','settled','expired','rejected','abandoned')),
    started_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    ended_at timestamptz,
    FOREIGN KEY (game_id, player_id) REFERENCES player.players (game_id, id),
    UNIQUE (game_id, id),
    UNIQUE (game_id, id, player_id),
    CHECK (expires_at > started_at)
);
CREATE INDEX game_runs_player_idx ON gameplay.game_runs (game_id, player_id, started_at DESC);

CREATE TABLE gameplay.run_settlements (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    game_id uuid NOT NULL,
    run_id uuid NOT NULL,
    player_id uuid NOT NULL,
    result jsonb NOT NULL, -- client-reported summary; untrusted input kept for review
    validation_status text NOT NULL CHECK (validation_status IN ('accepted','rejected','review')),
    rewards jsonb NOT NULL DEFAULT '[]'::jsonb, -- server-decided rewards actually granted
    idempotency_key text NOT NULL,
    settled_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (game_id, run_id, player_id) REFERENCES gameplay.game_runs (game_id, id, player_id),
    UNIQUE (game_id, id),
    UNIQUE (game_id, run_id) -- a run can be settled at most once
);
CREATE INDEX run_settlements_player_idx ON gameplay.run_settlements (game_id, player_id, settled_at DESC);

CREATE TABLE gameplay.run_events (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    game_id uuid NOT NULL,
    run_id uuid NOT NULL,
    event_type text NOT NULL,
    payload jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (game_id, run_id) REFERENCES gameplay.game_runs (game_id, id)
);
CREATE INDEX run_events_run_idx ON gameplay.run_events (game_id, run_id, created_at);

-- ---------------------------------------------------------------------------
-- F. economy — 货币、钱包、道具及其不可变流水
-- ---------------------------------------------------------------------------

CREATE TABLE economy.currency_definitions (
    game_id uuid NOT NULL REFERENCES platform.games(id),
    currency_code text NOT NULL, -- e.g. gold, diamond, energy
    name text NOT NULL,
    max_balance bigint CHECK (max_balance IS NULL OR max_balance > 0),
    status text NOT NULL DEFAULT 'active' CHECK (status IN ('active','disabled')),
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (game_id, currency_code)
);

-- 余额是流水的投影；仅在写入 wallet_transactions 记录的同一事务中
-- 更新余额。V1 禁止任何货币余额为负；若某种货币必须允许负余额，需修订 ADR
-- 并通过迁移修改此 CHECK 约束。
CREATE TABLE economy.wallets (
    game_id uuid NOT NULL,
    player_id uuid NOT NULL,
    currency_code text NOT NULL,
    balance bigint NOT NULL DEFAULT 0 CHECK (balance >= 0),
    version bigint NOT NULL DEFAULT 1,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (game_id, player_id, currency_code),
    FOREIGN KEY (game_id, player_id) REFERENCES player.players (game_id, id),
    FOREIGN KEY (game_id, currency_code) REFERENCES economy.currency_definitions (game_id, currency_code)
);

CREATE TABLE economy.wallet_transactions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    game_id uuid NOT NULL,
    player_id uuid NOT NULL,
    currency_code text NOT NULL,
    direction text NOT NULL CHECK (direction IN ('credit','debit')),
    amount bigint NOT NULL CHECK (amount > 0),
    balance_after bigint NOT NULL CHECK (balance_after >= 0),
    transaction_type text NOT NULL, -- business action: run_reward, ad_reward, mail_claim, gm_adjustment, ...
    source_type text NOT NULL,      -- owning business object: game_run, ad_session, player_mail, ...
    source_id text NOT NULL,
    idempotency_key text,           -- request key, for tracing; dedupe is the UNIQUE below
    actor_type text NOT NULL CHECK (actor_type IN ('player','admin','service','system')),
    actor_id text,
    reason text,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (game_id, player_id, currency_code)
        REFERENCES economy.wallets (game_id, player_id, currency_code),
    UNIQUE (game_id, id),
    -- 每项操作中，同一业务来源只能变更同一玩家的一种货币余额一次。
    UNIQUE (game_id, player_id, currency_code, source_type, source_id, transaction_type)
);
CREATE INDEX wallet_transactions_player_idx
    ON economy.wallet_transactions (game_id, player_id, created_at DESC);
CREATE INDEX wallet_transactions_source_idx
    ON economy.wallet_transactions (game_id, source_type, source_id);
CREATE TRIGGER wallet_transactions_append_only
    BEFORE UPDATE OR DELETE ON economy.wallet_transactions
    FOR EACH ROW EXECUTE FUNCTION system.reject_mutation();

CREATE TABLE economy.item_definitions (
    game_id uuid NOT NULL REFERENCES platform.games(id),
    item_id text NOT NULL, -- designer-facing stable code
    name text NOT NULL,
    item_type text NOT NULL,
    stackable boolean NOT NULL DEFAULT true,
    max_quantity bigint CHECK (max_quantity IS NULL OR max_quantity > 0),
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    status text NOT NULL DEFAULT 'active' CHECK (status IN ('active','disabled')),
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (game_id, item_id)
);

CREATE TABLE economy.player_items (
    game_id uuid NOT NULL,
    player_id uuid NOT NULL,
    item_id text NOT NULL,
    quantity bigint NOT NULL DEFAULT 0 CHECK (quantity >= 0),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (game_id, player_id, item_id),
    FOREIGN KEY (game_id, player_id) REFERENCES player.players (game_id, id),
    FOREIGN KEY (game_id, item_id) REFERENCES economy.item_definitions (game_id, item_id)
);

CREATE TABLE economy.item_transactions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    game_id uuid NOT NULL,
    player_id uuid NOT NULL,
    item_id text NOT NULL,
    direction text NOT NULL CHECK (direction IN ('credit','debit')),
    quantity bigint NOT NULL CHECK (quantity > 0),
    quantity_after bigint NOT NULL CHECK (quantity_after >= 0),
    transaction_type text NOT NULL,
    source_type text NOT NULL,
    source_id text NOT NULL,
    idempotency_key text,
    actor_type text NOT NULL CHECK (actor_type IN ('player','admin','service','system')),
    actor_id text,
    reason text,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (game_id, player_id, item_id)
        REFERENCES economy.player_items (game_id, player_id, item_id),
    UNIQUE (game_id, id),
    UNIQUE (game_id, player_id, item_id, source_type, source_id, transaction_type)
);
CREATE INDEX item_transactions_player_idx
    ON economy.item_transactions (game_id, player_id, created_at DESC);
CREATE INDEX item_transactions_source_idx
    ON economy.item_transactions (game_id, source_type, source_id);
CREATE TRIGGER item_transactions_append_only
    BEFORE UPDATE OR DELETE ON economy.item_transactions
    FOR EACH ROW EXECUTE FUNCTION system.reject_mutation();

-- ---------------------------------------------------------------------------
-- G. ads — 广告位、会话、奖励领取、每日限额
-- 客户端完成回调是证据，不是可信证明。
-- ---------------------------------------------------------------------------

CREATE TABLE ads.ad_placements (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    game_id uuid NOT NULL REFERENCES platform.games(id),
    placement_code text NOT NULL,
    platform text NOT NULL DEFAULT 'wechat_minigame',
    ad_unit_id text,
    reward_rule jsonb NOT NULL DEFAULT '{}'::jsonb,
    daily_limit integer NOT NULL CHECK (daily_limit > 0), -- per player per day; always explicit
    session_ttl_seconds integer NOT NULL DEFAULT 300 CHECK (session_ttl_seconds > 0),
    status text NOT NULL DEFAULT 'active' CHECK (status IN ('active','disabled')),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (game_id, id),
    UNIQUE (game_id, placement_code)
);

CREATE TABLE ads.ad_sessions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    game_id uuid NOT NULL,
    player_id uuid NOT NULL,
    placement_id uuid NOT NULL,
    status text NOT NULL DEFAULT 'created' CHECK (status IN ('created','claimed','expired','rejected')),
    device_id text,
    client_completed_at timestamptz, -- when the client reported completion (untrusted)
    expires_at timestamptz NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (game_id, player_id) REFERENCES player.players (game_id, id),
    FOREIGN KEY (game_id, placement_id) REFERENCES ads.ad_placements (game_id, id),
    UNIQUE (game_id, id),
    UNIQUE (game_id, id, player_id)
);
CREATE INDEX ad_sessions_player_idx ON ads.ad_sessions (game_id, player_id, created_at DESC);

CREATE TABLE ads.ad_reward_claims (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    game_id uuid NOT NULL,
    player_id uuid NOT NULL,
    session_id uuid NOT NULL,
    reward jsonb NOT NULL DEFAULT '[]'::jsonb,
    reward_status text NOT NULL CHECK (reward_status IN ('granted','rejected','review')),
    reject_reason text,
    idempotency_key text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (game_id, session_id, player_id) REFERENCES ads.ad_sessions (game_id, id, player_id),
    UNIQUE (game_id, id),
    UNIQUE (game_id, session_id) -- a session can be claimed at most once
);

CREATE TABLE ads.ad_daily_limits (
    game_id uuid NOT NULL,
    player_id uuid NOT NULL,
    placement_id uuid NOT NULL,
    limit_date date NOT NULL, -- day boundary in the game's configured reset timezone
    claim_count integer NOT NULL DEFAULT 0 CHECK (claim_count >= 0),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (game_id, player_id, placement_id, limit_date),
    FOREIGN KEY (game_id, player_id) REFERENCES player.players (game_id, id),
    FOREIGN KEY (game_id, placement_id) REFERENCES ads.ad_placements (game_id, id)
);

-- ---------------------------------------------------------------------------
-- H. operation — 公告、邮件、活动、批量奖励任务
-- ---------------------------------------------------------------------------

CREATE TABLE operation.announcements (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    scope text NOT NULL DEFAULT 'game' CHECK (scope IN ('global','game')),
    game_id uuid REFERENCES platform.games(id),
    title text NOT NULL,
    content text NOT NULL,
    priority integer NOT NULL DEFAULT 0,
    status text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','published','archived')),
    start_at timestamptz NOT NULL,
    end_at timestamptz NOT NULL,
    created_by uuid REFERENCES admin.admin_users(id),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CHECK ((scope = 'global' AND game_id IS NULL) OR (scope = 'game' AND game_id IS NOT NULL)),
    CHECK (end_at > start_at)
);
CREATE INDEX announcements_game_window_idx ON operation.announcements (game_id, start_at, end_at)
    WHERE status = 'published';

CREATE TABLE operation.mail_messages (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    game_id uuid NOT NULL REFERENCES platform.games(id),
    title text NOT NULL,
    content text NOT NULL,
    target_type text NOT NULL CHECK (target_type IN ('all_players','player_list','segment')),
    target_filter jsonb NOT NULL DEFAULT '{}'::jsonb,
    status text NOT NULL DEFAULT 'draft' CHECK (status IN
        ('draft','scheduled','sending','sent','cancelled','failed')),
    send_at timestamptz,
    expires_at timestamptz,
    created_by uuid REFERENCES admin.admin_users(id),
    created_at timestamptz NOT NULL DEFAULT now(),
    sent_at timestamptz,
    UNIQUE (game_id, id)
);

CREATE TABLE operation.mail_attachments (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    game_id uuid NOT NULL,
    mail_id uuid NOT NULL,
    reward_type text NOT NULL CHECK (reward_type IN ('currency','item')),
    reward_id text NOT NULL, -- currency_code or item_id, validated by the application service
    quantity bigint NOT NULL CHECK (quantity > 0),
    FOREIGN KEY (game_id, mail_id) REFERENCES operation.mail_messages (game_id, id),
    UNIQUE (game_id, mail_id, reward_type, reward_id)
);

CREATE TABLE operation.player_mail (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    game_id uuid NOT NULL,
    player_id uuid NOT NULL,
    mail_id uuid NOT NULL,
    read_at timestamptz,
    claimed_at timestamptz,
    deleted_at timestamptz,
    expires_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (game_id, player_id) REFERENCES player.players (game_id, id),
    FOREIGN KEY (game_id, mail_id) REFERENCES operation.mail_messages (game_id, id),
    UNIQUE (game_id, id),
    UNIQUE (game_id, mail_id, player_id) -- one delivery per player; re-delivery is idempotent
);
CREATE INDEX player_mail_inbox_idx ON operation.player_mail (game_id, player_id, created_at DESC)
    WHERE deleted_at IS NULL;

CREATE TABLE operation.activities (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    game_id uuid NOT NULL REFERENCES platform.games(id),
    activity_code text NOT NULL,
    activity_type text NOT NULL,
    name text NOT NULL,
    config jsonb NOT NULL DEFAULT '{}'::jsonb, -- tasks and reward table of the activity
    status text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','published','disabled','ended')),
    start_at timestamptz NOT NULL,
    end_at timestamptz NOT NULL,
    created_by uuid REFERENCES admin.admin_users(id),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (game_id, id),
    UNIQUE (game_id, activity_code),
    CHECK (end_at > start_at)
);

CREATE TABLE operation.activity_claims (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    game_id uuid NOT NULL,
    player_id uuid NOT NULL,
    activity_id uuid NOT NULL,
    reward_id text NOT NULL, -- reward entry inside the activity config
    rewards jsonb NOT NULL DEFAULT '[]'::jsonb,
    idempotency_key text NOT NULL,
    claimed_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (game_id, player_id) REFERENCES player.players (game_id, id),
    FOREIGN KEY (game_id, activity_id) REFERENCES operation.activities (game_id, id),
    UNIQUE (game_id, id),
    UNIQUE (game_id, activity_id, player_id, reward_id)
);

-- 批量发放或群发邮件的业务记录；任务由 system.background_jobs
-- 承载并由 game-worker 执行，绝不在 GM HTTP 请求中处理。
CREATE TABLE operation.reward_jobs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    game_id uuid NOT NULL REFERENCES platform.games(id),
    job_type text NOT NULL CHECK (job_type IN ('mail_delivery','batch_reward','compensation')),
    status text NOT NULL DEFAULT 'pending' CHECK (status IN
        ('pending','running','succeeded','failed','cancelled')),
    payload jsonb NOT NULL DEFAULT '{}'::jsonb,
    mail_id uuid,
    reason text NOT NULL,
    ticket_id text,
    target_count bigint NOT NULL DEFAULT 0 CHECK (target_count >= 0),
    processed_count bigint NOT NULL DEFAULT 0 CHECK (processed_count >= 0),
    failed_count bigint NOT NULL DEFAULT 0 CHECK (failed_count >= 0),
    background_job_id uuid REFERENCES system.background_jobs(id),
    created_by uuid REFERENCES admin.admin_users(id),
    created_at timestamptz NOT NULL DEFAULT now(),
    started_at timestamptz,
    finished_at timestamptz,
    FOREIGN KEY (game_id, mail_id) REFERENCES operation.mail_messages (game_id, id),
    UNIQUE (game_id, id)
);
CREATE INDEX reward_jobs_game_idx ON operation.reward_jobs (game_id, created_at DESC);

-- ---------------------------------------------------------------------------
-- I. ranking — PostgreSQL 为权威数据源；Redis 仅用于加速读取
-- ---------------------------------------------------------------------------

CREATE TABLE ranking.leaderboards (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    game_id uuid NOT NULL REFERENCES platform.games(id),
    board_code text NOT NULL,
    name text NOT NULL,
    period text NOT NULL DEFAULT 'all_time' CHECK (period IN
        ('all_time','daily','weekly','monthly','season')),
    ranking_rule jsonb NOT NULL DEFAULT '{}'::jsonb, -- sort order, tie-break, score update policy
    status text NOT NULL DEFAULT 'active' CHECK (status IN ('active','disabled')),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (game_id, id),
    UNIQUE (game_id, board_code)
);

CREATE TABLE ranking.leaderboard_entries (
    game_id uuid NOT NULL,
    board_id uuid NOT NULL,
    period_key text NOT NULL DEFAULT 'all_time', -- e.g. 2026-11-23, 2026-W48, season-3
    player_id uuid NOT NULL,
    score bigint NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (game_id, board_id, period_key, player_id),
    FOREIGN KEY (game_id, board_id) REFERENCES ranking.leaderboards (game_id, id),
    FOREIGN KEY (game_id, player_id) REFERENCES player.players (game_id, id)
);
CREATE INDEX leaderboard_entries_rank_idx
    ON ranking.leaderboard_entries (game_id, board_id, period_key, score DESC, updated_at);

CREATE TABLE ranking.leaderboard_snapshots (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    game_id uuid NOT NULL,
    board_id uuid NOT NULL,
    period_key text NOT NULL,
    snapshot_data jsonb NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (game_id, board_id) REFERENCES ranking.leaderboards (game_id, id),
    UNIQUE (game_id, board_id, period_key)
);

-- ---------------------------------------------------------------------------
-- K. audit — 只追加的审计记录
-- ---------------------------------------------------------------------------

CREATE TABLE audit.admin_audit_logs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    admin_id uuid REFERENCES admin.admin_users(id),
    game_id uuid REFERENCES platform.games(id), -- NULL for platform-level actions
    action text NOT NULL, -- permission code of the operation, e.g. economy.grant
    target_type text NOT NULL,
    target_id text,
    before_data jsonb, -- redacted: no passwords, tokens or secrets
    after_data jsonb,
    reason text,
    ticket_id text,
    request_id text NOT NULL,
    ip inet,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX admin_audit_logs_game_time_idx ON audit.admin_audit_logs (game_id, created_at DESC);
CREATE INDEX admin_audit_logs_actor_time_idx ON audit.admin_audit_logs (admin_id, created_at DESC);
CREATE INDEX admin_audit_logs_target_idx ON audit.admin_audit_logs (target_type, target_id);
CREATE TRIGGER admin_audit_logs_append_only
    BEFORE UPDATE OR DELETE ON audit.admin_audit_logs
    FOR EACH ROW EXECUTE FUNCTION system.reject_mutation();

CREATE TABLE audit.service_audit_logs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    service_id uuid REFERENCES system.service_identities(id),
    game_id uuid REFERENCES platform.games(id),
    action text NOT NULL,
    target_type text,
    target_id text,
    result text NOT NULL DEFAULT 'success' CHECK (result IN ('success','denied','failed')),
    request_id text NOT NULL,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX service_audit_logs_service_time_idx
    ON audit.service_audit_logs (service_id, created_at DESC);
CREATE INDEX service_audit_logs_game_time_idx
    ON audit.service_audit_logs (game_id, created_at DESC);
CREATE TRIGGER service_audit_logs_append_only
    BEFORE UPDATE OR DELETE ON audit.service_audit_logs
    FOR EACH ROW EXECUTE FUNCTION system.reject_mutation();

-- ---------------------------------------------------------------------------
-- L. analytics — 事件和每日聚合数据（仅用于报告，不具权威性）
-- ---------------------------------------------------------------------------

CREATE TABLE analytics.game_events (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    game_id uuid NOT NULL REFERENCES platform.games(id),
    player_id uuid,
    event_id text NOT NULL, -- client-generated id used for deduplication
    event_type text NOT NULL,
    payload jsonb NOT NULL DEFAULT '{}'::jsonb,
    occurred_at timestamptz NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (game_id, player_id) REFERENCES player.players (game_id, id),
    UNIQUE (game_id, event_id)
);
CREATE INDEX game_events_type_time_idx
    ON analytics.game_events (game_id, event_type, occurred_at DESC);

CREATE TABLE analytics.daily_player_stats (
    game_id uuid NOT NULL,
    stat_date date NOT NULL,
    player_id uuid NOT NULL,
    metrics jsonb NOT NULL DEFAULT '{}'::jsonb,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (game_id, stat_date, player_id),
    FOREIGN KEY (game_id, player_id) REFERENCES player.players (game_id, id)
);

CREATE TABLE analytics.daily_game_stats (
    game_id uuid NOT NULL REFERENCES platform.games(id),
    stat_date date NOT NULL,
    metrics jsonb NOT NULL DEFAULT '{}'::jsonb, -- dau, new_players, runs, settlements, ad_claims, ...
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (game_id, stat_date)
);

-- ---------------------------------------------------------------------------
-- RBAC 基线种子数据：权限代码和系统角色。
-- 超出设计文档示例的权限代码标记为“（扩展）”；
-- 角色到权限的映射待定，详见 docs/security/rbac-matrix.md。
-- ---------------------------------------------------------------------------

INSERT INTO admin.permissions (code, description) VALUES
    ('game.read',            'View games and platform app configuration (extension)'),
    ('game.manage',          'Create and configure games, platform apps, environments (extension)'),
    ('player.read',          'Search and view players'),
    ('player.ban',           'Ban a player'),
    ('player.unban',         'Lift a player ban'),
    ('player.save.restore',  'Restore a player save from a snapshot (extension)'),
    ('economy.read',         'View wallets, items and ledgers'),
    ('economy.grant',        'Manually credit currency or items'),
    ('economy.deduct',       'Manually debit currency or items (extension)'),
    ('config.read',          'View configs, versions and releases'),
    ('config.edit',          'Create configs and draft versions, run validation'),
    ('config.publish',       'Publish or roll back a config release'),
    ('mail.create',          'Create mail drafts'),
    ('mail.send',            'Send mail to players'),
    ('activity.manage',      'Create and manage activities (extension)'),
    ('announcement.manage',  'Create and manage announcements (extension)'),
    ('ranking.read',         'View leaderboards (extension)'),
    ('ranking.manage',       'Manage and rebuild leaderboards (extension)'),
    ('analytics.read',       'View dashboards and analytics (extension)'),
    ('admin.read',           'View administrators and roles (extension)'),
    ('admin.manage',         'Create and manage administrators (extension)'),
    ('rbac.manage',          'Change role permissions and role assignments (extension)'),
    ('audit.read',           'Query audit logs');

INSERT INTO admin.roles (code, name, description, is_system) VALUES
    ('super_admin',      'Super Admin',      'Platform-wide administration', true),
    ('game_admin',       'Game Admin',       'Administration of assigned games', true),
    ('operator',         'Operator',         'Mail, announcements and activities', true),
    ('config_manager',   'Config Manager',   'Config editing and publishing', true),
    ('customer_support', 'Customer Support', 'Player lookup and support operations', true),
    ('analyst',          'Analyst',          'Read-only analytics', true),
    ('auditor',          'Auditor',          'Read-only audit access', true);

COMMIT;

-- 生产加固检查清单（通过独立迁移/运维手册完成，任务 T03 和 T21）：
-- 1. 创建 NOLOGIN 所有者角色，并分别创建 LOGIN 角色 game_api_runtime、gm_api_runtime、
--    game_worker_runtime；另创建仅供部署使用的 game_migrator。
-- 2. 对 PUBLIC 执行 REVOKE ALL；按运行时角色显式授予 Schema/数据表权限。
--    game_api_runtime 不得访问 admin Schema；gm_api_runtime 不得绕过 ADR-0007 选定的钱包流水写入路径
--    直接 UPDATE economy.wallets。
-- 3. 审计和流水表：运行时角色仅授予 INSERT/SELECT（不得 UPDATE/DELETE/TRUNCATE）。
-- 4. 仅在记录事务级游戏范围并测试角色模型后才启用 RLS；
--    使用真实 LOGIN 角色测试，不使用所有者角色。
-- 5. 迁移凭据不得进入应用部署环境。
-- 6. 在测得数据量并明确保留要求后，为 analytics.game_events、auth.login_records、审计日志和
--    流水增加分区和保留策略。
