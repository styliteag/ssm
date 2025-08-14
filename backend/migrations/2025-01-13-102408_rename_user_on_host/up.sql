CREATE TABLE authorization (
	id INTEGER NOT NULL PRIMARY KEY,
	host_id INTEGER NOT NULL,
	user_id INTEGER NOT NULL,
	login TEXT NOT NULL,
	options TEXT,
	UNIQUE(user_id, host_id, login),
	FOREIGN KEY (host_id) REFERENCES host(id) ON DELETE CASCADE,
	FOREIGN KEY (user_id) REFERENCES user(id) ON DELETE CASCADE
);

INSERT INTO authorization (id, host_id, user_id, login, options)
	SELECT id, host_id, user_id, user, options FROM user_in_host;

DROP TABLE user_in_host;
