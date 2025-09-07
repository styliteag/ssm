-- Example of PROPER SQLite migration for adding disabled column
-- This would replace the current 2025-09-06 migration

-- UP migration:
PRAGMA foreign_keys = OFF;

-- Create new table with all constraints
CREATE TABLE host_new (
    id INTEGER NOT NULL PRIMARY KEY,
    name TEXT UNIQUE NOT NULL,
    username TEXT NOT NULL,
    address TEXT NOT NULL,
    port INTEGER NOT NULL,
    key_fingerprint TEXT,
    jump_via INTEGER,
    disabled BOOLEAN NOT NULL DEFAULT 0,
    CONSTRAINT unique_address_port UNIQUE (address, port),
    FOREIGN KEY (jump_via) REFERENCES host(id) ON DELETE CASCADE
);

-- Copy data
INSERT INTO host_new (id, name, username, address, port, key_fingerprint, jump_via, disabled)
SELECT id, name, username, address, port, key_fingerprint, jump_via, 0 FROM host;

-- Replace table
DROP TABLE host;
ALTER TABLE host_new RENAME TO host;

PRAGMA foreign_keys = ON;

-- DOWN migration would reverse this properly:
PRAGMA foreign_keys = OFF;

CREATE TABLE host_new (
    id INTEGER NOT NULL PRIMARY KEY,
    name TEXT UNIQUE NOT NULL,
    username TEXT NOT NULL,
    address TEXT NOT NULL,
    port INTEGER NOT NULL,
    key_fingerprint TEXT,
    jump_via INTEGER,
    CONSTRAINT unique_address_port UNIQUE (address, port),
    FOREIGN KEY (jump_via) REFERENCES host(id) ON DELETE CASCADE
);

INSERT INTO host_new (id, name, username, address, port, key_fingerprint, jump_via)
SELECT id, name, username, address, port, key_fingerprint, jump_via FROM host;

DROP TABLE host;
ALTER TABLE host_new RENAME TO host;

PRAGMA foreign_keys = ON;