-- SQLite doesn't support DROP COLUMN directly, so we need to recreate the table
-- This is the down migration to remove the comment column
CREATE TABLE user_new (
    id INTEGER PRIMARY KEY NOT NULL,
    username TEXT NOT NULL,
    enabled BOOLEAN NOT NULL DEFAULT 1
);

INSERT INTO user_new SELECT id, username, enabled FROM user;

DROP TABLE user;

ALTER TABLE user_new RENAME TO user;
