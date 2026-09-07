-- +migrate Up
CREATE TABLE IF NOT EXISTS users (
    id TEXT PRIMARY KEY,
    username TEXT NOT NULL UNIQUE,
    password_hash TEXT,
    phone TEXT UNIQUE,
    display_name TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL DEFAULT 'active',
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS sessions (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id),
    access_token_hash TEXT NOT NULL UNIQUE,
    refresh_token_hash TEXT UNIQUE,
    expires_at TEXT NOT NULL,
    refresh_expires_at TEXT,
    revoked_at TEXT,
    created_at TEXT NOT NULL,
    user_agent TEXT,
    device_id TEXT
);

CREATE INDEX IF NOT EXISTS idx_sessions_user ON sessions(user_id);

CREATE TABLE IF NOT EXISTS devices (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id),
    name TEXT NOT NULL DEFAULT '',
    platform TEXT NOT NULL DEFAULT 'ios',
    client_device_key TEXT,
    last_seen_at TEXT,
    revoked_at TEXT,
    created_at TEXT NOT NULL,
    UNIQUE(user_id, client_device_key)
);

CREATE TABLE IF NOT EXISTS invite_codes (
    code TEXT PRIMARY KEY,
    max_uses INTEGER NOT NULL DEFAULT 1,
    used_count INTEGER NOT NULL DEFAULT 0,
    expires_at TEXT,
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS media (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id),
    content_hash TEXT NOT NULL,
    mime_type TEXT NOT NULL DEFAULT '',
    media_type TEXT NOT NULL DEFAULT 'photo',
    size_bytes INTEGER NOT NULL DEFAULT 0,
    width INTEGER,
    height INTEGER,
    duration_ms INTEGER,
    taken_at TEXT,
    original_path TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'stored',
    source_device_id TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    UNIQUE(user_id, content_hash)
);

CREATE INDEX IF NOT EXISTS idx_media_user_taken ON media(user_id, taken_at DESC, id DESC);

CREATE TABLE IF NOT EXISTS media_derivatives (
    id TEXT PRIMARY KEY,
    media_id TEXT NOT NULL REFERENCES media(id) ON DELETE CASCADE,
    kind TEXT NOT NULL,
    path TEXT NOT NULL,
    width INTEGER,
    height INTEGER,
    size_bytes INTEGER,
    UNIQUE(media_id, kind)
);

CREATE TABLE IF NOT EXISTS upload_sessions (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id),
    device_id TEXT,
    content_hash TEXT NOT NULL,
    size_bytes INTEGER NOT NULL,
    received_bytes INTEGER NOT NULL DEFAULT 0,
    tmp_dir TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'open',
    meta_json TEXT,
    expires_at TEXT NOT NULL,
    media_id TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_upload_open ON upload_sessions(status, expires_at);

CREATE TABLE IF NOT EXISTS share_links (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id),
    token_hash TEXT NOT NULL UNIQUE,
    title TEXT NOT NULL DEFAULT '',
    scope_type TEXT NOT NULL,
    scope_payload TEXT NOT NULL,
    password_hash TEXT,
    expires_at TEXT,
    revoked_at TEXT,
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS jobs (
    id TEXT PRIMARY KEY,
    type TEXT NOT NULL,
    payload TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending',
    attempts INTEGER NOT NULL DEFAULT 0,
    available_at TEXT NOT NULL,
    last_error TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_jobs_poll ON jobs(status, available_at);

-- +migrate Down
DROP TABLE IF EXISTS jobs;
DROP TABLE IF EXISTS share_links;
DROP TABLE IF EXISTS upload_sessions;
DROP TABLE IF EXISTS media_derivatives;
DROP TABLE IF EXISTS media;
DROP TABLE IF EXISTS invite_codes;
DROP TABLE IF EXISTS devices;
DROP TABLE IF EXISTS sessions;
DROP TABLE IF EXISTS users;
