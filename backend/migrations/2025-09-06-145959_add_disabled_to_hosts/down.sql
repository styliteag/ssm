-- SQLite doesn't support DROP COLUMN directly, so we need to recreate the table
-- This is the down migration to remove the disabled column
CREATE TABLE host_new (
    id INTEGER PRIMARY KEY NOT NULL,
    name TEXT NOT NULL,
    username TEXT NOT NULL,
    address TEXT NOT NULL,
    port INTEGER NOT NULL,
    key_fingerprint TEXT,
    jump_via INTEGER
);

INSERT INTO host_new SELECT id, name, username, address, port, key_fingerprint, jump_via FROM host;

DROP TABLE host;

ALTER TABLE host_new RENAME TO host;