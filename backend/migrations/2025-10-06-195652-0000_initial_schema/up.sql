-- Initial schema for SSM 1.0.0
-- This migration creates all tables with their final schema

CREATE TABLE host (
    id INTEGER NOT NULL PRIMARY KEY,
    name TEXT UNIQUE NOT NULL,
    username TEXT NOT NULL,
    address TEXT NOT NULL,
    port INTEGER NOT NULL,
    key_fingerprint TEXT,
    jump_via INTEGER,
    disabled BOOLEAN NOT NULL DEFAULT 0,
    comment TEXT,
    CONSTRAINT unique_address_port UNIQUE (address, port),
    FOREIGN KEY (jump_via) REFERENCES host(id) ON DELETE CASCADE
);

CREATE TABLE user (
    id INTEGER NOT NULL PRIMARY KEY,
    username TEXT UNIQUE NOT NULL,
    enabled BOOLEAN NOT NULL CHECK (enabled IN (0, 1)) DEFAULT 1,
    comment TEXT
);

CREATE TABLE authorization (
    id INTEGER NOT NULL PRIMARY KEY,
    host_id INTEGER NOT NULL,
    user_id INTEGER NOT NULL,
    login TEXT NOT NULL,
    options TEXT,
    comment TEXT,
    UNIQUE(user_id, host_id, login),
    FOREIGN KEY (host_id) REFERENCES host(id) ON DELETE CASCADE,
    FOREIGN KEY (user_id) REFERENCES user(id) ON DELETE CASCADE
);

CREATE TABLE user_key (
    id INTEGER NOT NULL PRIMARY KEY,
    key_type TEXT NOT NULL,
    key_base64 TEXT UNIQUE NOT NULL,
    name TEXT,
    extra_comment TEXT,
    user_id INTEGER NOT NULL,
    FOREIGN KEY (user_id) REFERENCES user(id) ON DELETE CASCADE
);