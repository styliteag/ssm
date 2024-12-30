PRAGMA foreign_keys=on;

CREATE TABLE host_new (
	id INTEGER NOT NULL PRIMARY KEY,
	name TEXT UNIQUE NOT NULL,
	username TEXT NOT NULL,
	address TEXT NOT NULL,
	port INTEGER NOT NULL,
	key_fingerprint TEXT,
	jump_via INTEGER,
	FOREIGN KEY (jump_via) REFERENCES host_new(id),
	CONSTRAINT unique_address_port UNIQUE (address, port)
);

INSERT INTO host_new (id, name, username, address, port, key_fingerprint, jump_via)
               SELECT id, name, username, address, port, key_fingerprint, jump_via FROM host;

DROP TABLE host;
ALTER TABLE host_new RENAME TO host;
