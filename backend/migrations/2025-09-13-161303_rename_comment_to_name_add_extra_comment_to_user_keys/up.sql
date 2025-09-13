-- SQLite doesn't support RENAME COLUMN directly, so we need to recreate the table
-- Rename comment to name and add extra_comment column

-- Create new table with updated schema
CREATE TABLE user_key_new (
    id INTEGER PRIMARY KEY NOT NULL,
    key_type TEXT NOT NULL,
    key_base64 TEXT NOT NULL,
    name TEXT,  -- Renamed from comment
    extra_comment TEXT,  -- New field
    user_id INTEGER NOT NULL,
    FOREIGN KEY (user_id) REFERENCES user(id)
);

-- Copy data from old table to new table
INSERT INTO user_key_new (id, key_type, key_base64, name, user_id)
SELECT id, key_type, key_base64, comment, user_id FROM user_key;

-- Drop old table
DROP TABLE user_key;

-- Rename new table to original name
ALTER TABLE user_key_new RENAME TO user_key;
