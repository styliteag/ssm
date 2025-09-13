-- Reverse migration: revert name back to comment and remove extra_comment

-- Create new table with original schema
CREATE TABLE user_key_new (
    id INTEGER PRIMARY KEY NOT NULL,
    key_type TEXT NOT NULL,
    key_base64 TEXT NOT NULL,
    comment TEXT,  -- Revert name back to comment
    user_id INTEGER NOT NULL,
    FOREIGN KEY (user_id) REFERENCES user(id)
);

-- Copy data from current table to new table
-- Note: extra_comment data will be lost as we're reverting
INSERT INTO user_key_new (id, key_type, key_base64, comment, user_id)
SELECT id, key_type, key_base64, name, user_id FROM user_key;

-- Drop current table
DROP TABLE user_key;

-- Rename new table to original name
ALTER TABLE user_key_new RENAME TO user_key;
