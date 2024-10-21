CREATE TABLE host (
	id INTEGER NOT NULL PRIMARY KEY,
	name TEXT UNIQUE NOT NULL,
	username TEXT NOT NULL,
	hostname TEXT UNIQUE NOT NULL,
	port INTEGER NOT NULL,
	key_fingerprint TEXT UNIQUE NOT NULL,
	jump_via INTEGER,
	FOREIGN KEY (jump_via) REFERENCES hosts(id)
);

CREATE TABLE user (
	id INTEGER NOT NULL PRIMARY KEY,
	username TEXT UNIQUE NOT NULL,
	enabled  BOOLEAN NOT NULL CHECK (enabled IN (0, 1)) DEFAULT 1
);

CREATE TABLE user_in_host (
	id INTEGER NOT NULL PRIMARY KEY,
	host_id INTEGER NOT NULL,
	user_id INTEGER NOT NULL,
	user TEXT NOT NULL,
	options TEXT,
	UNIQUE(user_id, user),
	FOREIGN KEY (host_id) REFERENCES hosts(id),
	FOREIGN KEY (user_id) REFERENCES users(id)
);

CREATE TABLE user_key (
	id INTEGER NOT NULL PRIMARY KEY,
	key_type TEXT NOT NULL,
	key_base64 TEXT UNIQUE NOT NULL,
	comment TEXT,
	user_id INTEGER NOT NULL,
	FOREIGN KEY (user_id) REFERENCES users(id)
);
