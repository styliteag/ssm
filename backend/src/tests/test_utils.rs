use std::fs;
use std::path::PathBuf;
use std::sync::Arc;
use actix_web::test::{self, TestRequest};
use actix_web::{web, App, HttpServer};
use actix_session::{storage::CookieSessionStore, SessionMiddleware};
use actix_identity::IdentityMiddleware;
use diesel::r2d2::{ConnectionManager, Pool};
use diesel::SqliteConnection;
use diesel_migrations::MigrationHarness;
use tempfile::TempDir;
use tokio::sync::OnceCell;
use uuid::Uuid;

use crate::{Configuration, ConnectionPool, DbConnection, MIGRATIONS, SshConfig, ssh::{SshClient, CachingSshClient}};
use crate::routes;

static INIT: OnceCell<()> = OnceCell::const_new();

/// Test configuration for consistent test environment
pub struct TestConfig {
    pub config: Configuration,
    pub temp_dir: TempDir,
    pub db_pool: ConnectionPool,
    pub htpasswd_path: PathBuf,
}

impl TestConfig {
    /// Create a new test configuration with isolated database and auth files
    pub async fn new() -> Self {
        INIT.get_or_init(|| {
            env_logger::builder()
                .filter_level(log::LevelFilter::Debug)
                .init();
        }).await;

        let temp_dir = tempfile::tempdir().expect("Failed to create temp directory");
        let db_path = temp_dir.path().join("test.db");
        let htpasswd_path = temp_dir.path().join(".htpasswd");
        
        // Create test htpasswd file
        let test_htpasswd = "testuser:$2b$12$LQv3c1yqBWVHxkd0LHAkCOYz6TtxMQJqhN8/LewYuJyj7Ih/JeJVa"; // password: testpass
        fs::write(&htpasswd_path, test_htpasswd).expect("Failed to write htpasswd file");

        // Create test SSH private key (dummy key for testing)
        let ssh_key_path = temp_dir.path().join("test_key");
        let test_private_key = r#"-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAFwAAAAdzc2gtcn
NhAAAAAwEAAQAAAQEAy5N5pL7bqGI8yt7xNJmjzR4rB8KYL3r8C1ZK8GvD8wQ4R5pL7b
qGI8yt7xNJmjzR4rB8KYL3r8C1ZK8GvD8wQ4R5pL7bqGI8yt7xNJmjzR4rB8KYL3r8C1
ZK8GvD8wQ4R5pL7bqGI8yt7xNJmjzR4rB8KYL3r8C1ZK8GvD8wQ4R5pL7bqGI8yt7xNJ
mjzR4rB8KYL3r8C1ZK8GvD8wQ4R5pL7bqGI8yt7xNJmjzR4rB8KYL3r8C1ZK8GvD8wQ4
R5pL7bqGI8yt7xNJmjzR4rB8KYL3r8C1ZK8GvD8wQ4R5pL7bqGI8yt7xNJmjzR4rB8KY
L3r8C1ZK8GvD8wQ4AAAA8g8MfAPPDHwDwAAAAdzc2gtcnNhAAABAQDLk3mkvtuoYjzK
3vE0maPNHisHwpgvevwLVkrwa8PzBDhHmkvtuoYjzK3vE0maPNHisHwpgvevwLVkrwa8
PzBDhHmkvtuoYjzK3vE0maPNHisHwpgvevwLVkrwa8PzBDhHmkvtuoYjzK3vE0maPNHi
sHwpgvevwLVkrwa8PzBDhHmkvtuoYjzK3vE0maPNHisHwpgvevwLVkrwa8PzBDhHmkv
tuoYjzK3vE0maPNHisHwpgvevwLVkrwa8PzBDhHmkvtuoYjzK3vE0maPNHisHwpgvev
wLVkrwa8PzBDhHmkvtuoYjzK3vE0maPNHisHwpgvevwLVkrwa8PzBDAAAAAwEAAQAAAQ
AAAAAAAAAsJWMfAPDEAAEAAAAdzc2gtcnNhAAAAeP///
-----END OPENSSH PRIVATE KEY-----"#;
        fs::write(&ssh_key_path, test_private_key).expect("Failed to write SSH key file");

        let database_url = format!("sqlite://{}", db_path.display());
        
        // Create database connection pool
        let manager = ConnectionManager::<DbConnection>::new(database_url.clone());
        let pool = Pool::builder()
            .max_size(5)
            .build(manager)
            .expect("Failed to create connection pool");
        
        // Run migrations
        {
            let mut conn = pool.get().expect("Failed to get connection");
            conn.run_pending_migrations(MIGRATIONS)
                .expect("Failed to run migrations");
        }

        let config = Configuration {
            ssh: SshConfig {
                check_schedule: None,
                update_schedule: None,
                private_key_file: ssh_key_path,
                private_key_passphrase: None,
                timeout: std::time::Duration::from_secs(30),
            },
            database_url,
            listen: std::net::IpAddr::V6(std::net::Ipv6Addr::LOCALHOST),
            port: 0, // Let the OS assign a port
            loglevel: "debug".to_string(),
            session_key: "test-secret-key-for-testing-only".to_string(),
            htpasswd_path: htpasswd_path.clone(),
        };

        Self {
            config,
            temp_dir,
            db_pool: pool,
            htpasswd_path,
        }
    }

    /// Create a test app for testing
    pub fn create_test_app(&self) -> App<impl actix_web::dev::ServiceFactory<
        actix_web::dev::ServiceRequest,
        Config = (),
        Response = actix_web::dev::ServiceResponse,
        Error = actix_web::Error,
        InitError = (),
    >> {
        let config = web::Data::new(self.config.clone());
        let pool = web::Data::new(self.db_pool.clone());
        let secret_key = cookie::Key::derive_from(self.config.session_key.as_bytes());

        App::new()
            .wrap(
                SessionMiddleware::builder(CookieSessionStore::default(), secret_key)
                    .cookie_name("ssm_test_session".to_owned())
                    .build(),
            )
            .wrap(IdentityMiddleware::default())
            .app_data(config)
            .app_data(pool)
            .configure(routes::route_config)
    }
}

/// Mock SSH client for testing without real SSH connections
pub struct MockSshClient;

impl MockSshClient {
    pub fn new() -> Self {
        Self
    }

    pub async fn mock_key_diff(&self, _content: &str, _host: String, _login: String) -> Result<Vec<String>, String> {
        Ok(vec!["+ ssh-rsa AAAAB3... test@example.com".to_string()])
    }

    pub async fn mock_set_authorized_keys(&self, _host: String, _login: String, _content: String) -> Result<(), String> {
        Ok(())
    }

    pub async fn mock_get_logins(&self, _host_id: i32) -> Result<Vec<String>, String> {
        Ok(vec!["root".to_string(), "ubuntu".to_string()])
    }
}

/// Generate a random test string for unique identifiers
pub fn random_string() -> String {
    Uuid::new_v4().to_string()
}

/// Create a test request with JSON payload
pub fn test_request_with_json<T: serde::Serialize>(payload: &T) -> TestRequest {
    TestRequest::post()
        .insert_header(("content-type", "application/json"))
        .set_json(payload)
}

/// Create a test GET request with authentication
pub fn authenticated_get_request(path: &str) -> TestRequest {
    TestRequest::get()
        .uri(path)
        .insert_header(("content-type", "application/json"))
}

/// Helper for creating test hosts
pub fn create_test_host_data(name: Option<String>) -> serde_json::Value {
    let name = name.unwrap_or_else(|| format!("test-host-{}", random_string()));
    serde_json::json!({
        "name": name,
        "address": "192.168.1.100",
        "port": 22,
        "username": "ubuntu",
        "key_fingerprint": "SHA256:test_fingerprint",
        "jump_via": null
    })
}

/// Helper for creating test users
pub fn create_test_user_data(username: Option<String>) -> serde_json::Value {
    let username = username.unwrap_or_else(|| format!("test-user-{}", random_string()));
    serde_json::json!({
        "username": username
    })
}

/// Helper for creating test SSH keys
pub fn create_test_key_data() -> serde_json::Value {
    serde_json::json!({
        "key_type": "ssh-rsa",
        "key_base64": "AAAAB3NzaC1yc2EAAAADAQABAAABgQC7vbqajDw5XJjfsQM1dLDEeuxWiZQ",
        "comment": "test@example.com"
    })
}

/// Helper for creating authorization test data
pub fn create_test_authorization_data(host_id: i32, user_id: i32) -> serde_json::Value {
    serde_json::json!({
        "host_id": host_id,
        "user_id": user_id,
        "login": "ubuntu",
        "options": null
    })
}

/// Add test data to database
pub async fn insert_test_host(pool: &ConnectionPool, name: &str) -> Result<i32, diesel::result::Error> {
    use crate::models::NewHost;
    use crate::db::host::Host;
    
    let new_host = NewHost {
        name: name.to_string(),
        address: "192.168.1.100".to_string(),
        port: 22,
        username: "ubuntu".to_string(),
        key_fingerprint: "SHA256:test_fingerprint".to_string(),
        jump_via: None,
    };
    
    let mut conn = pool.get().unwrap();
    Host::add_host(&mut conn, &new_host)
}

pub async fn insert_test_user(pool: &ConnectionPool, username: &str) -> Result<i32, diesel::result::Error> {
    use crate::models::NewUser;
    use crate::db::user::User;
    
    let new_user = NewUser {
        username: username.to_string(),
    };
    
    let mut conn = pool.get().unwrap();
    User::add_user(&mut conn, &new_user)
}

pub async fn insert_test_key(pool: &ConnectionPool, user_id: i32) -> Result<i32, diesel::result::Error> {
    use crate::models::NewPublicUserKey;
    use crate::db::key::PublicUserKey;
    
    let new_key = NewPublicUserKey::new(
        russh::keys::Algorithm::Rsa { hash: russh::keys::AlgHash::Sha2_256 },
        "AAAAB3NzaC1yc2EAAAADAQABAAABgQC7vbqajDw5XJjfsQM1dLDEeuxWiZQ".to_string(),
        Some("test@example.com".to_string()),
        user_id,
    );
    
    let mut conn = pool.get().unwrap();
    PublicUserKey::add_public_key(&mut conn, &new_key)
}

/// Clean up test data
pub async fn cleanup_test_data(pool: &ConnectionPool) {
    let mut conn = pool.get().unwrap();
    
    // Clean up in reverse order of dependencies
    use diesel::prelude::*;
    use crate::schema::{authorization, user_key, user, host};
    
    let _ = diesel::delete(authorization::table).execute(&mut conn);
    let _ = diesel::delete(user_key::table).execute(&mut conn);
    let _ = diesel::delete(user::table).execute(&mut conn);
    let _ = diesel::delete(host::table).execute(&mut conn);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_config_creation() {
        let config = TestConfig::new().await;
        assert!(config.htpasswd_path.exists());
        assert!(!config.config.database_url.is_empty());
    }

    #[test]
    fn test_random_string() {
        let s1 = random_string();
        let s2 = random_string();
        assert_ne!(s1, s2);
        assert!(!s1.is_empty());
    }
}