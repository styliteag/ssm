/// HTTP Test Utilities - Complete isolation from production
/// 
/// This module provides utilities for testing HTTP API endpoints
/// with complete isolation:
/// - Temporary test database (in-memory or temp file)
/// - Test configuration file
/// - Dummy SSH keys that never connect anywhere
/// - Mock SSH client to prevent any real connections

use actix_web::{test, web, App, dev::ServiceResponse, http::StatusCode, middleware, body::MessageBody};
use actix_session::{SessionMiddleware, storage::CookieSessionStore};
use actix_web::cookie::Key;
use actix_identity::IdentityMiddleware;
use serde_json::Value;
use tempfile::TempDir;
use std::sync::Arc;
use diesel::r2d2::{self, ConnectionManager};
use diesel::SqliteConnection;

use crate::{
    Configuration, ConnectionPool, SshConfig,
    ssh::{SshClient, CachingSshClient},
    tests::{safety::init_test_mode, mock_ssh::MockSshClient},
};

/// HTTP Test context with complete isolation
pub struct HttpTestContext {
    pub pool: ConnectionPool,
    pub config: Configuration,
    pub temp_dir: TempDir,
    pub session_cookie: Option<String>,
}

impl HttpTestContext {
    /// Create a new isolated HTTP test context
    pub async fn new() -> Self {
        // Initialize test safety mode
        init_test_mode();
        
        // Create temporary directory for all test files
        let temp_dir = TempDir::new().expect("Failed to create temp dir");
        
        // Create test database path
        let db_path = temp_dir.path().join("test_http.db");
        let database_url = format!("sqlite://{}", db_path.display());
        
        // Create dummy SSH key (never used for real connections)
        let ssh_key_path = temp_dir.path().join("test_ssh_key");
        std::fs::write(&ssh_key_path, 
            "-----BEGIN OPENSSH PRIVATE KEY-----\n\
             TEST_KEY_NEVER_USED_FOR_REAL_CONNECTIONS\n\
             -----END OPENSSH PRIVATE KEY-----"
        ).expect("Failed to write test SSH key");
        
        // Create dummy htpasswd file with test user
        // Password: "testpass" with bcrypt hash
        let htpasswd_path = temp_dir.path().join("test.htpasswd");
        std::fs::write(&htpasswd_path,
            "testuser:$2y$10$kL1e9vLxmm3Gt6zHRnGvNeR5cF0y0W2PS9j9VvLpY7L9CIAMvPzMW\n\
             admin:$2y$10$kL1e9vLxmm3Gt6zHRnGvNeR5cF0y0W2PS9j9VvLpY7L9CIAMvPzMW"
        ).expect("Failed to write test htpasswd");
        
        // Create test configuration
        let config = Configuration {
            database_url: database_url.clone(),
            listen: "127.0.0.1".parse().unwrap(),
            port: 0, // Let OS assign port
            loglevel: "debug".to_string(),
            session_key: "test-session-key-for-http-tests-only-32bytes!!!".to_string(),
            htpasswd_path,
            ssh: SshConfig {
                private_key_file: ssh_key_path,
                private_key_passphrase: None,
                check_schedule: None,
                update_schedule: None,
                timeout: std::time::Duration::from_secs(30),
            },
        };
        
        // Create connection pool
        let manager = ConnectionManager::<SqliteConnection>::new(&database_url);
        let pool = r2d2::Pool::builder()
            .build(manager)
            .expect("Failed to create pool");
        
        // Run migrations on test database
        {
            use diesel_migrations::MigrationHarness;
            use diesel::RunQueryDsl;
            let mut conn = pool.get().expect("Failed to get connection");
            
            // Enable foreign keys for SQLite
            diesel::sql_query("PRAGMA foreign_keys = ON")
                .execute(&mut conn)
                .expect("Failed to enable foreign keys");
            
            // Run all migrations
            conn.run_pending_migrations(crate::MIGRATIONS)
                .expect("Failed to run migrations");
        }
        
        Self {
            pool,
            config,
            temp_dir,
            session_cookie: None,
        }
    }
    
    /// Create the test app
    fn create_app(&self) -> App<
        impl actix_web::dev::ServiceFactory<
            actix_web::dev::ServiceRequest,
            Config = (),
            Response = actix_web::dev::ServiceResponse,
            Error = actix_web::Error,
            InitError = (),
        >,
    > {
        let mock_ssh = MockSshClient::new(self.pool.clone(), self.config.ssh.clone());
        let caching_ssh = CachingSshClient::new(MockSshClient::new(self.pool.clone(), self.config.ssh.clone()));
        
        App::new()
            .app_data(web::Data::new(self.pool.clone()))
            .app_data(web::Data::new(Arc::new(self.config.clone())))
            .app_data(web::Data::new(mock_ssh))
            .app_data(web::Data::new(caching_ssh))
            .wrap(IdentityMiddleware::default())
            .wrap(
                SessionMiddleware::builder(
                    CookieSessionStore::default(),
                    Key::from(self.config.session_key.as_bytes()),
                )
                .cookie_secure(false)
                .build(),
            )
            .wrap(middleware::Logger::default())
            .configure(crate::routes::route_config)
    }
    
    /// Login as test user and store session cookie
    pub async fn login(&mut self, username: &str, password: &str) -> Result<(), String> {
        let app = test::init_service(self.create_app()).await;
        
        let req = test::TestRequest::post()
            .uri("/api/auth/login")
            .set_json(&serde_json::json!({
                "username": username,
                "password": password
            }))
            .to_request();
        
        let resp = test::call_service(&app, req).await;
        
        if resp.status() != StatusCode::OK {
            return Err(format!("Login failed with status: {}", resp.status()));
        }
        
        // Extract session cookie from response
        if let Some(cookie) = resp.response().cookies().find(|c| c.name() == "id") {
            self.session_cookie = Some(format!("{}={}", cookie.name(), cookie.value()));
        }
        
        Ok(())
    }
    
    /// Make authenticated GET request
    pub async fn get(&self, uri: &str) -> ServiceResponse {
        let app = test::init_service(self.create_app()).await;
        let mut req = test::TestRequest::get().uri(uri);
        
        if let Some(ref cookie) = self.session_cookie {
            req = req.append_header(("Cookie", cookie.as_str()));
        }
        
        test::call_service(&app, req.to_request()).await
    }
    
    /// Make authenticated POST request with JSON body
    pub async fn post_json(&self, uri: &str, json: Value) -> ServiceResponse {
        let app = test::init_service(self.create_app()).await;
        let mut req = test::TestRequest::post()
            .uri(uri)
            .set_json(&json);
        
        if let Some(ref cookie) = self.session_cookie {
            req = req.append_header(("Cookie", cookie.as_str()));
        }
        
        test::call_service(&app, req.to_request()).await
    }
    
    /// Make authenticated PUT request with JSON body
    pub async fn put_json(&self, uri: &str, json: Value) -> ServiceResponse {
        let app = test::init_service(self.create_app()).await;
        let mut req = test::TestRequest::put()
            .uri(uri)
            .set_json(&json);
        
        if let Some(ref cookie) = self.session_cookie {
            req = req.append_header(("Cookie", cookie.as_str()));
        }
        
        test::call_service(&app, req.to_request()).await
    }
    
    /// Make authenticated DELETE request
    pub async fn delete(&self, uri: &str) -> ServiceResponse {
        let app = test::init_service(self.create_app()).await;
        let mut req = test::TestRequest::delete().uri(uri);
        
        if let Some(ref cookie) = self.session_cookie {
            req = req.append_header(("Cookie", cookie.as_str()));
        }
        
        test::call_service(&app, req.to_request()).await
    }
    
    /// Make authenticated DELETE request with JSON body
    pub async fn delete_json(&self, uri: &str, json: Value) -> ServiceResponse {
        let app = test::init_service(self.create_app()).await;
        let mut req = test::TestRequest::delete()
            .uri(uri)
            .set_json(&json);
        
        if let Some(ref cookie) = self.session_cookie {
            req = req.append_header(("Cookie", cookie.as_str()));
        }
        
        test::call_service(&app, req.to_request()).await
    }
    
    /// Extract JSON response body
    pub async fn extract_json(resp: ServiceResponse) -> Value {
        let body = test::read_body(resp).await;
        serde_json::from_slice(&body).expect("Failed to parse JSON response")
    }
    
    /// Assert response has success status and extract data
    pub async fn assert_success(&self, resp: ServiceResponse) -> Value {
        assert_eq!(resp.status(), StatusCode::OK, "Response should be 200 OK");
        let json = Self::extract_json(resp).await;
        assert_eq!(json["status"], "success", "Response status should be success");
        json["data"].clone()
    }
    
    /// Create a test user in the database
    pub async fn create_test_user(&self, username: &str) -> i32 {
        use crate::models::{User, NewUser};
        let mut conn = self.pool.get().unwrap();
        User::add_user(&mut conn, NewUser { username: username.to_string() })
            .expect("Failed to create test user");
        User::get_user(&mut conn, username.to_string())
            .expect("Failed to get test user")
            .id
    }
    
    /// Create a test host in the database
    pub async fn create_test_host(&self, name: &str, address: &str) -> i32 {
        use crate::models::{Host, NewHost};
        let mut conn = self.pool.get().unwrap();
        Host::add_host(&mut conn, &NewHost {
            name: name.to_string(),
            address: address.to_string(),
            port: 22,
            username: "ubuntu".to_string(),
            key_fingerprint: Some("TEST_FINGERPRINT".to_string()),
            jump_via: None,
        }).expect("Failed to create test host")
    }
}

/// Macro to quickly setup test context with login
#[macro_export]
macro_rules! setup_http_test {
    () => {{
        let mut ctx = HttpTestContext::new().await;
        ctx.login("testuser", "testpass").await
            .expect("Failed to login");
        ctx
    }};
}

#[cfg(test)]
mod tests {
    use super::*;
    
    #[actix_web::test]
    async fn test_http_context_creation() {
        let ctx = HttpTestContext::new().await;
        assert!(ctx.temp_dir.path().exists());
        assert!(ctx.config.ssh.private_key_file.exists());
        assert!(ctx.config.htpasswd_path.exists());
    }
    
    #[actix_web::test]
    async fn test_login() {
        let mut ctx = HttpTestContext::new().await;
        let result = ctx.login("testuser", "testpass").await;
        assert!(result.is_ok());
        assert!(ctx.session_cookie.is_some());
    }
    
    #[actix_web::test]
    async fn test_isolation() {
        // Create two separate contexts
        let ctx1 = HttpTestContext::new().await;
        let ctx2 = HttpTestContext::new().await;
        
        // They should have different temp directories
        assert_ne!(ctx1.temp_dir.path(), ctx2.temp_dir.path());
        
        // Create user in ctx1
        let user_id = ctx1.create_test_user("isolated_user").await;
        assert!(user_id > 0);
        
        // User should not exist in ctx2
        use crate::models::User;
        let mut conn2 = ctx2.pool.get().unwrap();
        let user2 = User::get_user(&mut conn2, "isolated_user".to_string());
        assert!(user2.is_err(), "User should not exist in second context");
    }
}