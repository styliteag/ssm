-- Rollback: This migration should not normally be run on production systems
-- as it removes all data. Only use for complete reset during development.
-- WARNING: This will delete all SSH key management data!

DROP TABLE IF EXISTS user_key;
DROP TABLE IF EXISTS authorization;
DROP TABLE IF EXISTS user;
DROP TABLE IF EXISTS host;