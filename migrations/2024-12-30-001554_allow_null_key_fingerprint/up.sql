PRAGMA foreign_keys=off;

CREATE TABLE host_new (
	id INTEGER NOT NULL PRIMARY KEY,
	name TEXT UNIQUE NOT NULL,
	username TEXT NOT NULL,
	address TEXT UNIQUE NOT NULL,
	port INTEGER NOT NULL,
	key_fingerprint TEXT,
	jump_via INTEGER
);

INSERT INTO host_new (id, name, username, address, port, key_fingerprint, jump_via)
               SELECT id, name, username, address, port, key_fingerprint, jump_via FROM host;

DROP TABLE host;
ALTER TABLE host_new RENAME TO host;

-- Add the foreign key constraint after all data is copied
CREATE TABLE host_temp AS SELECT * FROM host;
DROP TABLE host;
CREATE TABLE host (
	id INTEGER NOT NULL PRIMARY KEY,
	name TEXT UNIQUE NOT NULL,
	username TEXT NOT NULL,
	address TEXT UNIQUE NOT NULL,
	port INTEGER NOT NULL,
	key_fingerprint TEXT,
	jump_via INTEGER,
	FOREIGN KEY (jump_via) REFERENCES host(id) ON DELETE CASCADE
);
INSERT INTO host SELECT * FROM host_temp;
DROP TABLE host_temp;

PRAGMA foreign_keys=on;
