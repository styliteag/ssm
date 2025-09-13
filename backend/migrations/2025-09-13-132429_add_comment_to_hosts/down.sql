-- SQLite doesn't support DROP COLUMN directly, so we need to recreate the table
-- This is the down migration to remove the comment column
CREATE TABLE host_new (
    id INTEGER PRIMARY KEY NOT NULL,
    name TEXT NOT NULL,
    username TEXT NOT NULL,
    address TEXT NOT NULL,
    port INTEGER NOT NULL,
    key_fingerprint TEXT,
    jump_via INTEGER,
    disabled BOOLEAN NOT NULL DEFAULT 0
);

INSERT INTO host_new SELECT id, name, username, address, port, key_fingerprint, jump_via, disabled FROM host;

DROP TABLE host;

ALTER TABLE host_new RENAME TO host;
