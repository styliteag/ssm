/// Test utilities for SSH Key Manager tests
///
/// Provides helper functions and test configuration for tests

use crate::{Configuration, ConnectionPool, SshConfig};
use diesel::r2d2::{ConnectionManager, Pool};
use diesel::prelude::*;
use diesel_migrations::MigrationHarness;
use std::env;
use std::path::PathBuf;
use tempfile::TempDir;
use uuid::Uuid;

/// Test configuration holder
pub struct TestConfig {
    pub db_pool: ConnectionPool,
    pub config: Configuration,
    pub _temp_dir: TempDir, // Keep temp dir alive
}

impl TestConfig {
    /// Create a new test configuration with isolated database
    pub async fn new() -> Self {
        // Initialize test mode
        crate::tests::safety::init_test_mode();
        
        // Create temporary directory for test data
        let temp_dir = TempDir::new().expect("Failed to create temp dir");
        let db_path = temp_dir.path().join(format!("test_{}.db", Uuid::new_v4()));
        
        // Validate the database URL is safe for testing
        let database_url = format!("sqlite://{}", db_path.display());
        crate::tests::safety::validate_test_database_url(&database_url)
            .expect("Test database URL should be safe");
        
        // Create connection pool
        let manager = ConnectionManager::<crate::DbConnection>::new(&database_url);
        let db_pool = Pool::builder()
            .build(manager)
            .expect("Failed to create test database pool");
        
        // Run migrations
        {
            let mut conn = db_pool.get().expect("Failed to get connection");
            conn.run_pending_migrations(crate::MIGRATIONS)
                .expect("Failed to run migrations");
            
            // Enable foreign keys for SQLite
            diesel::sql_query("PRAGMA foreign_keys = on")
                .execute(&mut conn)
                .expect("Failed to enable foreign keys");
        }
        
        // Create test SSH config
        let ssh_config = SshConfig {
            check_schedule: None,
            update_schedule: None,
            private_key_file: temp_dir.path().join("test_key"),
            private_key_passphrase: None,
            timeout: std::time::Duration::from_secs(30),
        };
        
        // Create test configuration
        let config = Configuration {
            ssh: ssh_config,
            database_url,
            listen: "127.0.0.1".parse().unwrap(),
            port: 8080,
            loglevel: "debug".to_string(),
            session_key: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef".to_string(),
            htpasswd_path: temp_dir.path().join(".htpasswd"),
        };
        
        // Create a dummy htpasswd file with a valid bcrypt hash for password "testpass"
        std::fs::write(&config.htpasswd_path, "testuser:$2b$12$QsNIPx3LLqyA/Wx2EGKnAe1PuXh1A5C.J/ztqwN9l67cqVJRwKoX6").unwrap();
        
        // Create a valid test SSH key file (Ed25519 private key in OpenSSH format)
        let test_ssh_key = "-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
QyNTUxOQAAACDy6FjzYoyVVFS7Nezy8UrI3+PUiv+IeJq+a+RZL1ntqwAAAJh889+FfPPf
hQAAAAtzc2gtZWQyNTUxOQAAACDy6FjzYoyVVFS7Nezy8UrI3+PUiv+IeJq+a+RZL1ntqw
AAAEBskm/mpb+k8F2Erdhg48hUe2TQbDNaLj967DNmn1pg5/LoWPNijJVUVLs17PLxSsjf
49SK/4h4mr5r5FkvWe2rAAAADnRlc3RfdXNlckB0ZXN0AQIDBAUGBw==
-----END OPENSSH PRIVATE KEY-----";
        std::fs::write(&config.ssh.private_key_file, test_ssh_key).unwrap();
        
        TestConfig {
            db_pool,
            config,
            _temp_dir: temp_dir,
        }
    }
}

/// Clean up test data from database
pub async fn cleanup_test_data(pool: &ConnectionPool) {
    let mut conn = pool.get().unwrap();
    
    // Delete all test data in reverse order of foreign key dependencies
    diesel::sql_query("DELETE FROM authorization").execute(&mut conn).ok();
    diesel::sql_query("DELETE FROM user_key").execute(&mut conn).ok();
    diesel::sql_query("DELETE FROM host").execute(&mut conn).ok();
    diesel::sql_query("DELETE FROM user").execute(&mut conn).ok();
}