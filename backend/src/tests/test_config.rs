/// Minimal Test Configuration
/// 
/// Just what we need to make tests work

use diesel::r2d2::{ConnectionManager, Pool};
use crate::{ConnectionPool, DbConnection};

/// Create a test database pool
pub async fn create_test_db_pool() -> ConnectionPool {
    // Use in-memory SQLite for tests
    let database_url = ":memory:";
    let manager = ConnectionManager::<DbConnection>::new(database_url);
    
    Pool::builder()
        .max_size(1)
        .build(manager)
        .expect("Failed to create test database pool")
}

/// Test app configuration  
#[derive(Clone)]
pub struct TestAppConfig {
    pub session_key: String,
}

impl TestAppConfig {
    pub fn new() -> Self {
        // Key must be exactly 64 bytes for cookie middleware
        let key = [0u8; 64];
        Self {
            session_key: String::from_utf8_lossy(&key).to_string(),
        }
    }
}