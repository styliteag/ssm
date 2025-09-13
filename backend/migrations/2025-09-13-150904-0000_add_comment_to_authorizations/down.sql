-- Recreate authorization table without comment column
CREATE TABLE authorization_backup AS SELECT id, host_id, user_id, login, options FROM authorization;
DROP TABLE authorization;
CREATE TABLE authorization (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    host_id INTEGER NOT NULL,
    user_id INTEGER NOT NULL,
    login TEXT NOT NULL,
    options TEXT
);
INSERT INTO authorization (id, host_id, user_id, login, options)
SELECT id, host_id, user_id, login, options FROM authorization_backup;
DROP TABLE authorization_backup;
