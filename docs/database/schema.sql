-- Game Platform initial PostgreSQL schema
-- Target: PostgreSQL 16+
-- Apply via a migration runner using a dedicated migration role.
-- Runtime roles are provisioned separately; do not run the application as owner/superuser.

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE SCHEMA IF NOT EXISTS platform;
CREATE SCHEMA IF NOT EXISTS auth;
CREATE SCHEMA IF NOT EXISTS player;
CREATE SCHEMA IF NOT EXISTS game;
CREATE SCHEMA IF NOT EXISTS gameplay;
CREATE SCHEMA IF NOT EXISTS economy;
CREATE SCHEMA IF NOT EXISTS ads;
CREATE SCHEMA IF NOT EXISTS operation;
CREATE SCHEMA IF NOT EXISTS admin;
CREATE SCHEMA IF NOT EXISTS audit;
CREATE SCHEMA IF NOT EXISTS system;

-- Platform registry
CREATE TABLE platform.games (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code text NOT NULL UNIQUE,
    name text NOT NULL,
    status text NOT NULL DEFAULT 'active' CHECK (status IN ('active','disabled','archived')),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE platform.game_apps (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    game_id uuid NOT NULL REFERENCES platform.games(id),
    platform text NOT NULL CHECK (platform IN ('wechat_mini_game','web','android','ios','other')),
    app_id text NOT NULL,
    credential_ref text NOT NULL, -- secret-manager reference, never the secret itself
    status text NOT NULL DEFAULT 'active' CHECK (status IN ('active','disabled')),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (game_id, id),
    UNIQUE (game_id, platform, app_id)
);

CREATE TABLE platform.game_settings (
    game_id uuid NOT NULL REFERENCES platform.games(id),
    setting_key text NOT NULL,
    setting_value jsonb NOT NULL DEFAULT '{}'::jsonb,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (game_id, setting_key)
);

-- Player identity and sessions
CREATE TABLE player.players (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    game_id uuid NOT NULL REFERENCES platform.games(id),
    display_name text,
    avatar_url text,
    status text NOT NULL DEFAULT 'active' CHECK (status IN ('active','banned','deleted')),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (game_id, id)
);

CREATE TABLE auth.player_identities (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    game_id uuid NOT NULL,
    player_id uuid NOT NULL,
    platform text NOT NULL,
    app_id text NOT NULL,
    openid text NOT NULL,
    unionid text,
    created_at timestamptz NOT NULL DEFAULT now(),
    last_login_at timestamptz,
    FOREIGN KEY (game_id, player_id) REFERENCES player.players(game_id, id),
    UNIQUE (game_id, platform, app_id, openid),
    UNIQUE (game_id, id)
);

CREATE INDEX player_identities_player_idx ON auth.player_identities(game_id, player_id);

CREATE TABLE auth.player_sessions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    game_id uuid NOT NULL,
    player_id uuid NOT NULL,
    refresh_token_hash bytea NOT NULL UNIQUE,
    device_id text,
    expires_at timestamptz NOT NULL,
    revoked_at timestamptz,
    rotated_from uuid,
    created_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (game_id, player_id) REFERENCES player.players(game_id, id),
    FOREIGN KEY (rotated_from) REFERENCES auth.player_sessions(id)
);
CREATE INDEX player_sessions_player_idx ON auth.player_sessions(game_id, player_id);
CREATE INDEX player_sessions_expiry_idx ON auth.player_sessions(expires_at) WHERE revoked_at IS NULL;

CREATE TABLE player.profiles (
    game_id uuid NOT NULL,
    player_id uuid NOT NULL,
    profile jsonb NOT NULL DEFAULT '{}'::jsonb,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (game_id, player_id),
    FOREIGN KEY (game_id, player_id) REFERENCES player.players(game_id, id)
);

CREATE TABLE player.saves (
    game_id uuid NOT NULL,
    player_id uuid NOT NULL,
    save_data jsonb NOT NULL DEFAULT '{}'::jsonb,
    schema_version integer NOT NULL DEFAULT 1 CHECK (schema_version > 0),
    save_version bigint NOT NULL DEFAULT 1 CHECK (save_version > 0),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (game_id, player_id),
    FOREIGN KEY (game_id, player_id) REFERENCES player.players(game_id, id)
);

CREATE TABLE player.save_snapshots (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    game_id uuid NOT NULL,
    player_id uuid NOT NULL,
    save_version bigint NOT NULL,
    save_data jsonb NOT NULL,
    created_by text NOT NULL DEFAULT 'system',
    created_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (game_id, player_id) REFERENCES player.players(game_id, id),
    UNIQUE (game_id, player_id, save_version)
);

-- Game configuration metadata; large payloads can be stored in object storage.
CREATE TABLE game.configs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    game_id uuid NOT NULL REFERENCES platform.games(id),
    config_key text NOT NULL,
    description text,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (game_id, id),
    UNIQUE (game_id, config_key)
);

CREATE TABLE game.config_versions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    game_id uuid NOT NULL,
    config_id uuid NOT NULL,
    version integer NOT NULL CHECK (version > 0),
    payload jsonb, -- optional inline payload; otherwise object_key is required
    object_key text,
    checksum_sha256 text NOT NULL,
    schema_version integer NOT NULL DEFAULT 1,
    state text NOT NULL CHECK (state IN ('draft','validated','published','superseded','rolled_back')),
    created_by uuid,
    created_at timestamptz NOT NULL DEFAULT now(),
    CHECK (payload IS NOT NULL OR object_key IS NOT NULL),
    FOREIGN KEY (game_id, config_id) REFERENCES game.configs(game_id, id),
    UNIQUE (game_id, config_id, version),
    UNIQUE (game_id, id)
);

CREATE TABLE game.config_releases (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    game_id uuid NOT NULL,
    config_id uuid NOT NULL,
    config_version_id uuid NOT NULL,
    channel text NOT NULL DEFAULT 'production',
    released_by uuid,
    released_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (game_id, config_id) REFERENCES game.configs(game_id, id),
    FOREIGN KEY (game_id, config_version_id) REFERENCES game.config_versions(game_id, id),
    UNIQUE (game_id, config_id, channel, released_at)
);
CREATE INDEX config_releases_latest_idx ON game.config_releases(game_id, config_id, channel, released_at DESC);

-- Gameplay run and one-time settlement
CREATE TABLE gameplay.runs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    game_id uuid NOT NULL,
    player_id uuid NOT NULL,
    mode text NOT NULL,
    level_id text,
    config_version text,
    status text NOT NULL DEFAULT 'started' CHECK (status IN ('started','submitted','settled','expired','rejected')),
    started_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    submitted_at timestamptz,
    result_digest text,
    FOREIGN KEY (game_id, player_id) REFERENCES player.players(game_id, id),
    UNIQUE (game_id, id)
);
CREATE INDEX gameplay_runs_player_idx ON gameplay.runs(game_id, player_id, started_at DESC);

CREATE TABLE gameplay.run_settlements (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    game_id uuid NOT NULL,
    run_id uuid NOT NULL,
    player_id uuid NOT NULL,
    result jsonb NOT NULL,
    reward jsonb NOT NULL DEFAULT '{}'::jsonb,
    validation_status text NOT NULL CHECK (validation_status IN ('accepted','rejected','review')),
    settled_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (game_id, run_id) REFERENCES gameplay.runs(game_id, id),
    FOREIGN KEY (game_id, player_id) REFERENCES player.players(game_id, id),
    UNIQUE (game_id, run_id),
    UNIQUE (game_id, id)
);

-- Economy ledger. Balance is a projection; transactions are immutable facts.
CREATE TABLE economy.wallets (
    game_id uuid NOT NULL,
    player_id uuid NOT NULL,
    currency_code text NOT NULL,
    balance bigint NOT NULL DEFAULT 0 CHECK (balance >= 0),
    version bigint NOT NULL DEFAULT 1,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (game_id, player_id, currency_code),
    FOREIGN KEY (game_id, player_id) REFERENCES player.players(game_id, id)
);

CREATE TABLE economy.wallet_transactions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    game_id uuid NOT NULL,
    player_id uuid NOT NULL,
    currency_code text NOT NULL,
    delta bigint NOT NULL CHECK (delta <> 0),
    balance_after bigint NOT NULL CHECK (balance_after >= 0),
    reason_code text NOT NULL,
    source_type text NOT NULL,
    source_id text NOT NULL,
    idempotency_key text NOT NULL,
    actor_type text NOT NULL CHECK (actor_type IN ('system','player','admin')),
    actor_id text,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (game_id, player_id) REFERENCES player.players(game_id, id),
    UNIQUE (game_id, id),
    UNIQUE (game_id, idempotency_key),
    UNIQUE (game_id, source_type, source_id, reason_code)
);
CREATE INDEX wallet_transactions_player_idx ON economy.wallet_transactions(game_id, player_id, created_at DESC);

CREATE TABLE economy.item_definitions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    game_id uuid NOT NULL REFERENCES platform.games(id),
    item_code text NOT NULL,
    name text NOT NULL,
    stackable boolean NOT NULL DEFAULT true,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    status text NOT NULL DEFAULT 'active' CHECK (status IN ('active','disabled')),
    UNIQUE (game_id, id),
    UNIQUE (game_id, item_code)
);

CREATE TABLE economy.player_items (
    game_id uuid NOT NULL,
    player_id uuid NOT NULL,
    item_id uuid NOT NULL,
    quantity bigint NOT NULL DEFAULT 0 CHECK (quantity >= 0),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (game_id, player_id, item_id),
    FOREIGN KEY (game_id, player_id) REFERENCES player.players(game_id, id),
    FOREIGN KEY (game_id, item_id) REFERENCES economy.item_definitions(game_id, id)
);

CREATE TABLE economy.item_transactions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    game_id uuid NOT NULL,
    player_id uuid NOT NULL,
    item_id uuid NOT NULL,
    delta bigint NOT NULL CHECK (delta <> 0),
    quantity_after bigint NOT NULL CHECK (quantity_after >= 0),
    source_type text NOT NULL,
    source_id text NOT NULL,
    idempotency_key text NOT NULL,
    actor_type text NOT NULL CHECK (actor_type IN ('system','player','admin')),
    actor_id text,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (game_id, player_id) REFERENCES player.players(game_id, id),
    FOREIGN KEY (game_id, item_id) REFERENCES economy.item_definitions(game_id, id),
    UNIQUE (game_id, idempotency_key)
);
CREATE INDEX item_transactions_player_idx ON economy.item_transactions(game_id, player_id, created_at DESC);

-- Ad reward sessions: client callback is evidence, not trusted proof.
CREATE TABLE ads.placements (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    game_id uuid NOT NULL REFERENCES platform.games(id),
    placement_code text NOT NULL,
    provider text NOT NULL,
    reward_rule jsonb NOT NULL DEFAULT '{}'::jsonb,
    daily_limit integer NOT NULL DEFAULT 0 CHECK (daily_limit >= 0),
    status text NOT NULL DEFAULT 'active' CHECK (status IN ('active','disabled')),
    UNIQUE (game_id, id),
    UNIQUE (game_id, placement_code)
);

CREATE TABLE ads.sessions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    game_id uuid NOT NULL,
    player_id uuid NOT NULL,
    placement_id uuid NOT NULL,
    status text NOT NULL DEFAULT 'prepared' CHECK (status IN ('prepared','claimed','expired','rejected')),
    expires_at timestamptz NOT NULL,
    client_completion_reported boolean NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (game_id, player_id) REFERENCES player.players(game_id, id),
    FOREIGN KEY (game_id, placement_id) REFERENCES ads.placements(game_id, id),
    UNIQUE (game_id, id)
);

CREATE TABLE ads.reward_claims (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    game_id uuid NOT NULL,
    session_id uuid NOT NULL,
    player_id uuid NOT NULL,
    reward jsonb NOT NULL,
    status text NOT NULL CHECK (status IN ('granted','rejected','review')),
    idempotency_key text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (game_id, session_id) REFERENCES ads.sessions(game_id, id),
    FOREIGN KEY (game_id, player_id) REFERENCES player.players(game_id, id),
    UNIQUE (game_id, session_id),
    UNIQUE (game_id, idempotency_key)
);

-- Operations: mail and activity claims
CREATE TABLE operation.mails (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    game_id uuid NOT NULL REFERENCES platform.games(id),
    title text NOT NULL,
    body jsonb NOT NULL,
    reward jsonb NOT NULL DEFAULT '{}'::jsonb,
    starts_at timestamptz,
    expires_at timestamptz,
    created_by uuid,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (game_id, id)
);

CREATE TABLE operation.player_mail (
    game_id uuid NOT NULL,
    mail_id uuid NOT NULL,
    player_id uuid NOT NULL,
    read_at timestamptz,
    claimed_at timestamptz,
    PRIMARY KEY (game_id, mail_id, player_id),
    FOREIGN KEY (game_id, mail_id) REFERENCES operation.mails(game_id, id),
    FOREIGN KEY (game_id, player_id) REFERENCES player.players(game_id, id)
);

CREATE TABLE operation.activities (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    game_id uuid NOT NULL REFERENCES platform.games(id),
    activity_code text NOT NULL,
    definition jsonb NOT NULL,
    starts_at timestamptz NOT NULL,
    ends_at timestamptz NOT NULL,
    status text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','published','disabled','ended')),
    UNIQUE (game_id, id),
    UNIQUE (game_id, activity_code),
    CHECK (ends_at > starts_at)
);

CREATE TABLE operation.activity_claims (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    game_id uuid NOT NULL,
    activity_id uuid NOT NULL,
    player_id uuid NOT NULL,
    reward jsonb NOT NULL,
    idempotency_key text NOT NULL,
    claimed_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (game_id, activity_id) REFERENCES operation.activities(game_id, id),
    FOREIGN KEY (game_id, player_id) REFERENCES player.players(game_id, id),
    UNIQUE (game_id, activity_id, player_id),
    UNIQUE (game_id, idempotency_key)
);

-- GM identities, RBAC and audit
CREATE TABLE admin.users (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    email text NOT NULL UNIQUE,
    password_hash text NOT NULL,
    mfa_enabled boolean NOT NULL DEFAULT false,
    status text NOT NULL DEFAULT 'active' CHECK (status IN ('active','disabled','locked')),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE admin.roles (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    role_code text NOT NULL UNIQUE,
    name text NOT NULL,
    description text
);

CREATE TABLE admin.permissions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    permission_code text NOT NULL UNIQUE,
    description text NOT NULL
);

CREATE TABLE admin.user_roles (
    admin_user_id uuid NOT NULL REFERENCES admin.users(id),
    role_id uuid NOT NULL REFERENCES admin.roles(id),
    game_id uuid REFERENCES platform.games(id), -- NULL means platform-wide only when explicitly granted
    granted_by uuid REFERENCES admin.users(id),
    granted_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (admin_user_id, role_id, game_id)
);

CREATE TABLE admin.role_permissions (
    role_id uuid NOT NULL REFERENCES admin.roles(id),
    permission_id uuid NOT NULL REFERENCES admin.permissions(id),
    PRIMARY KEY (role_id, permission_id)
);

CREATE TABLE audit.admin_logs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    admin_user_id uuid REFERENCES admin.users(id),
    game_id uuid REFERENCES platform.games(id),
    action text NOT NULL,
    target_type text NOT NULL,
    target_id text,
    reason text,
    ticket_ref text,
    request_id text NOT NULL,
    before_data jsonb,
    after_data jsonb,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX admin_logs_game_time_idx ON audit.admin_logs(game_id, created_at DESC);
CREATE INDEX admin_logs_actor_time_idx ON audit.admin_logs(admin_user_id, created_at DESC);

-- Idempotency and transactional outbox
CREATE TABLE system.idempotency_keys (
    scope text NOT NULL,
    idempotency_key text NOT NULL,
    request_hash text NOT NULL,
    response_status integer,
    response_body jsonb,
    state text NOT NULL DEFAULT 'processing' CHECK (state IN ('processing','completed','failed')),
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    PRIMARY KEY (scope, idempotency_key)
);

CREATE TABLE system.outbox_events (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    aggregate_type text NOT NULL,
    aggregate_id text NOT NULL,
    event_type text NOT NULL,
    payload jsonb NOT NULL,
    occurred_at timestamptz NOT NULL DEFAULT now(),
    published_at timestamptz,
    attempts integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    next_attempt_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX outbox_pending_idx ON system.outbox_events(next_attempt_at, occurred_at)
    WHERE published_at IS NULL;

COMMIT;

-- Production hardening checklist (separate migration/runbook):
-- 1. Create NOLOGIN owner roles and distinct game_api_runtime / gm_api_runtime / worker_runtime roles.
-- 2. Revoke PUBLIC privileges; grant schema/table/sequence/function privileges explicitly.
-- 3. Keep migration owner credentials out of application deployments.
-- 4. Add RLS only with a documented transaction-local game scope and role threat model.
-- 5. Make audit.admin_logs append-only for runtime roles (INSERT/SELECT only; no UPDATE/DELETE).
-- 6. Implement balance/item changes only through transactionally safe application services.
-- 7. Add partitioning/retention after measured volume and retention requirements are known.
