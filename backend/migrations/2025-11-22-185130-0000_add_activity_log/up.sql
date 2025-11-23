-- Create activity_log table to track all system actions
CREATE TABLE IF NOT EXISTS activity_log (
    id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
    activity_type TEXT NOT NULL CHECK (activity_type IN ('key', 'host', 'user', 'auth')),
    action TEXT NOT NULL,
    target TEXT NOT NULL,
    user_id INTEGER,
    actor_username TEXT NOT NULL,
    timestamp INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
    metadata TEXT,
    FOREIGN KEY (user_id) REFERENCES user(id) ON DELETE SET NULL
);

-- Create index on timestamp for efficient querying of recent activities
CREATE INDEX IF NOT EXISTS idx_activity_log_timestamp ON activity_log(timestamp DESC);

-- Create index on activity_type for filtering
CREATE INDEX IF NOT EXISTS idx_activity_log_type ON activity_log(activity_type);
