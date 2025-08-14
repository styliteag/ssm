CREATE TABLE user_in_host (
	id INTEGER NOT NULL PRIMARY KEY,
	host_id INTEGER NOT NULL,
	user_id INTEGER NOT NULL,
	user TEXT NOT NULL,
	options TEXT,
	UNIQUE(user_id, host_id, user),
	FOREIGN KEY (host_id) REFERENCES host(id) ON DELETE CASCADE,
	FOREIGN KEY (user_id) REFERENCES user(id) ON DELETE CASCADE
);

INSERT INTO user_in_host (id, host_id, user_id, user, options)
	SELECT id, host_id, user_id, login, options FROM authorization;

DROP TABLE authorization;
