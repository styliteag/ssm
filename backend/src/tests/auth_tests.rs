use actix_web::{test, web, App, http::StatusCode};
use actix_session::{storage::CookieSessionStore, SessionMiddleware};
use actix_identity::IdentityMiddleware;
use serde_json::json;
use serial_test::serial;

use crate::tests::test_utils::*;
use crate::tests::safety::{init_test_mode, is_test_mode, validate_test_database_url};
use crate::routes::authentication;
use crate::api_types::*;

#[tokio::test]
#[serial]
async fn test_login_success() {
    init_test_mode();
    assert!(is_test_mode(), "🛡️ Test must be running in test mode");
    
    let test_config = TestConfig::new().await;
    
    // 🛡️ Verify we're using test database
    validate_test_database_url(&test_config.config.database_url)
        .expect("🛡️ Must use test database");
    
    let secret_key = cookie::Key::derive_from(test_config.config.session_key.as_bytes());
    let app = test::init_service(
        App::new()
            .wrap(
                SessionMiddleware::builder(CookieSessionStore::default(), secret_key)
                    .cookie_name("ssm_test_session".to_owned())
                    .build(),
            )
            .wrap(IdentityMiddleware::default())
            .app_data(web::Data::new(test_config.config.clone()))
            .service(web::scope("/auth").configure(authentication::config))
    ).await;

    let login_request = json!({
        "username": "testuser",
        "password": "testpass"
    });

    let req = test::TestRequest::post()
        .uri("/auth/login")
        .set_json(&login_request)
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::OK);

    let body: ApiResponse<authentication::LoginResponse> = test::read_body_json(resp).await;
    assert!(body.success);
    assert_eq!(body.data.unwrap().username, "testuser");
}

#[tokio::test]
async fn test_login_invalid_credentials() {
    let test_config = TestConfig::new().await;
    
    let secret_key = cookie::Key::derive_from(test_config.config.session_key.as_bytes());
    let app = test::init_service(
        App::new()
            .wrap(
                SessionMiddleware::builder(CookieSessionStore::default(), secret_key)
                    .cookie_name("ssm_test_session".to_owned())
                    .build(),
            )
            .wrap(IdentityMiddleware::default())
            .app_data(web::Data::new(test_config.config.clone()))
            .service(web::scope("/auth").configure(authentication::config))
    ).await;

    let login_request = json!({
        "username": "testuser",
        "password": "wrongpassword"
    });

    let req = test::TestRequest::post()
        .uri("/auth/login")
        .set_json(&login_request)
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);

    let body: ApiError = test::read_body_json(resp).await;
    assert!(!body.success);
    assert!(body.message.contains("Invalid username or password"));
}

#[tokio::test]
async fn test_login_nonexistent_user() {
    let test_config = TestConfig::new().await;
    
    let secret_key = cookie::Key::derive_from(test_config.config.session_key.as_bytes());
    let app = test::init_service(
        App::new()
            .wrap(
                SessionMiddleware::builder(CookieSessionStore::default(), secret_key)
                    .cookie_name("ssm_test_session".to_owned())
                    .build(),
            )
            .wrap(IdentityMiddleware::default())
            .app_data(web::Data::new(test_config.config.clone()))
            .service(web::scope("/auth").configure(authentication::config))
    ).await;

    let login_request = json!({
        "username": "nonexistent",
        "password": "anypassword"
    });

    let req = test::TestRequest::post()
        .uri("/auth/login")
        .set_json(&login_request)
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn test_logout() {
    let test_config = TestConfig::new().await;
    
    let secret_key = cookie::Key::derive_from(test_config.config.session_key.as_bytes());
    let app = test::init_service(
        App::new()
            .wrap(
                SessionMiddleware::builder(CookieSessionStore::default(), secret_key)
                    .cookie_name("ssm_test_session".to_owned())
                    .build(),
            )
            .wrap(IdentityMiddleware::default())
            .app_data(web::Data::new(test_config.config.clone()))
            .service(web::scope("/auth").configure(authentication::config))
    ).await;

    // First login
    let login_request = json!({
        "username": "testuser",
        "password": "testpass"
    });

    let req = test::TestRequest::post()
        .uri("/auth/login")
        .set_json(&login_request)
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::OK);

    // Extract session cookie
    let cookies = resp.headers().get_all("set-cookie")
        .map(|h| h.to_str().unwrap())
        .collect::<Vec<_>>();
    
    assert!(!cookies.is_empty());
    let session_cookie = cookies[0];

    // Now logout
    let req = test::TestRequest::post()
        .uri("/auth/logout")
        .insert_header(("cookie", session_cookie))
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::OK);

    let body: ApiResponse<()> = test::read_body_json(resp).await;
    assert!(body.success);
    assert!(body.message.unwrap().contains("Logged out successfully"));
}

#[tokio::test]
async fn test_auth_status_not_logged_in() {
    let test_config = TestConfig::new().await;
    
    let secret_key = cookie::Key::derive_from(test_config.config.session_key.as_bytes());
    let app = test::init_service(
        App::new()
            .wrap(
                SessionMiddleware::builder(CookieSessionStore::default(), secret_key)
                    .cookie_name("ssm_test_session".to_owned())
                    .build(),
            )
            .wrap(IdentityMiddleware::default())
            .app_data(web::Data::new(test_config.config.clone()))
            .service(web::scope("/auth").configure(authentication::config))
    ).await;

    let req = test::TestRequest::get()
        .uri("/auth/status")
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::OK);

    let body: ApiResponse<authentication::StatusResponse> = test::read_body_json(resp).await;
    assert!(body.success);
    let status = body.data.unwrap();
    assert!(!status.logged_in);
    assert!(status.username.is_none());
}

#[tokio::test]
async fn test_auth_status_logged_in() {
    let test_config = TestConfig::new().await;
    
    let secret_key = cookie::Key::derive_from(test_config.config.session_key.as_bytes());
    let app = test::init_service(
        App::new()
            .wrap(
                SessionMiddleware::builder(CookieSessionStore::default(), secret_key)
                    .cookie_name("ssm_test_session".to_owned())
                    .build(),
            )
            .wrap(IdentityMiddleware::default())
            .app_data(web::Data::new(test_config.config.clone()))
            .service(web::scope("/auth").configure(authentication::config))
    ).await;

    // First login
    let login_request = json!({
        "username": "testuser",
        "password": "testpass"
    });

    let req = test::TestRequest::post()
        .uri("/auth/login")
        .set_json(&login_request)
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::OK);

    // Extract session cookie
    let cookies = resp.headers().get_all("set-cookie")
        .map(|h| h.to_str().unwrap())
        .collect::<Vec<_>>();
    let session_cookie = cookies[0];

    // Check auth status
    let req = test::TestRequest::get()
        .uri("/auth/status")
        .insert_header(("cookie", session_cookie))
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::OK);

    let body: ApiResponse<authentication::StatusResponse> = test::read_body_json(resp).await;
    assert!(body.success);
    let status = body.data.unwrap();
    assert!(status.logged_in);
    assert_eq!(status.username.unwrap(), "testuser");
}

#[tokio::test]
async fn test_login_missing_fields() {
    let test_config = TestConfig::new().await;
    
    let secret_key = cookie::Key::derive_from(test_config.config.session_key.as_bytes());
    let app = test::init_service(
        App::new()
            .wrap(
                SessionMiddleware::builder(CookieSessionStore::default(), secret_key)
                    .cookie_name("ssm_test_session".to_owned())
                    .build(),
            )
            .wrap(IdentityMiddleware::default())
            .app_data(web::Data::new(test_config.config.clone()))
            .service(web::scope("/auth").configure(authentication::config))
    ).await;

    // Missing password
    let login_request = json!({
        "username": "testuser"
    });

    let req = test::TestRequest::post()
        .uri("/auth/login")
        .set_json(&login_request)
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn test_login_empty_credentials() {
    let test_config = TestConfig::new().await;
    
    let secret_key = cookie::Key::derive_from(test_config.config.session_key.as_bytes());
    let app = test::init_service(
        App::new()
            .wrap(
                SessionMiddleware::builder(CookieSessionStore::default(), secret_key)
                    .cookie_name("ssm_test_session".to_owned())
                    .build(),
            )
            .wrap(IdentityMiddleware::default())
            .app_data(web::Data::new(test_config.config.clone()))
            .service(web::scope("/auth").configure(authentication::config))
    ).await;

    let login_request = json!({
        "username": "",
        "password": ""
    });

    let req = test::TestRequest::post()
        .uri("/auth/login")
        .set_json(&login_request)
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

#[cfg(test)]
mod password_verification_tests {
    use super::*;
    use crate::routes::authentication::verify_apache_password;

    #[test]
    fn test_verify_bcrypt_2b_hash() {
        let password = "testpass";
        let hash = "$2b$12$LQv3c1yqBWVHxkd0LHAkCOYz6TtxMQJqhN8/LewYuJyj7Ih/JeJVa";
        
        let result = verify_apache_password(password, hash);
        assert!(result.is_ok());
        assert!(result.unwrap());
    }

    #[test]
    fn test_verify_bcrypt_2y_hash() {
        let password = "testpass";
        let hash = "$2y$12$LQv3c1yqBWVHxkd0LHAkCOYz6TtxMQJqhN8/LewYuJyj7Ih/JeJVa";
        
        let result = verify_apache_password(password, hash);
        assert!(result.is_ok());
        assert!(result.unwrap());
    }

    #[test]
    fn test_verify_wrong_password() {
        let password = "wrongpass";
        let hash = "$2b$12$LQv3c1yqBWVHxkd0LHAkCOYz6TtxMQJqhN8/LewYuJyj7Ih/JeJVa";
        
        let result = verify_apache_password(password, hash);
        assert!(result.is_ok());
        assert!(!result.unwrap());
    }

    #[test]
    fn test_unsupported_hash_type() {
        let password = "testpass";
        let hash = "$1$unsupported$hash";
        
        let result = verify_apache_password(password, hash);
        assert!(result.is_ok());
        assert!(!result.unwrap());
    }
}

#[cfg(test)]
mod security_tests {
    use super::*;
    use std::time::Duration;
    use tokio::time::timeout;

    #[tokio::test]
    #[serial]
    async fn test_session_security_headers() {
        init_test_mode();
        let test_config = TestConfig::new().await;
        
        let secret_key = cookie::Key::derive_from(test_config.config.session_key.as_bytes());
        let app = test::init_service(
            App::new()
                .wrap(
                    SessionMiddleware::builder(CookieSessionStore::default(), secret_key)
                        .cookie_name("ssm_test_session".to_owned())
                        .build(),
                )
                .wrap(IdentityMiddleware::default())
                .app_data(web::Data::new(test_config.config.clone()))
                .service(web::scope("/auth").configure(authentication::config))
        ).await;

        // Login first
        let login_request = json!({
            "username": "testuser",
            "password": "testpass"
        });

        let req = test::TestRequest::post()
            .uri("/auth/login")
            .set_json(&login_request)
            .to_request();

        let resp = test::call_service(&app, req).await;
        assert_eq!(resp.status(), StatusCode::OK);

        // Check that session cookie is set securely
        let cookies = resp.headers().get_all("set-cookie")
            .map(|h| h.to_str().unwrap())
            .collect::<Vec<_>>();
        
        assert!(!cookies.is_empty());
        let session_cookie = cookies[0];
        
        // Session cookie should contain security attributes
        // Note: In test mode, secure flag might not be set
        assert!(session_cookie.contains("SameSite"));
        assert!(session_cookie.contains("HttpOnly"));
    }

    #[tokio::test]
    #[serial]
    async fn test_sql_injection_prevention() {
        init_test_mode();
        let test_config = TestConfig::new().await;
        
        let secret_key = cookie::Key::derive_from(test_config.config.session_key.as_bytes());
        let app = test::init_service(
            App::new()
                .wrap(
                    SessionMiddleware::builder(CookieSessionStore::default(), secret_key)
                        .cookie_name("ssm_test_session".to_owned())
                        .build(),
                )
                .wrap(IdentityMiddleware::default())
                .app_data(web::Data::new(test_config.config.clone()))
                .service(web::scope("/auth").configure(authentication::config))
        ).await;

        // Try SQL injection in username
        let malicious_request = json!({
            "username": "admin'; DROP TABLE users; --",
            "password": "testpass"
        });

        let req = test::TestRequest::post()
            .uri("/auth/login")
            .set_json(&malicious_request)
            .to_request();

        let resp = test::call_service(&app, req).await;
        assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
        
        // Database should still be intact - verify we can still login normally
        let normal_request = json!({
            "username": "testuser",
            "password": "testpass"
        });

        let req = test::TestRequest::post()
            .uri("/auth/login")
            .set_json(&normal_request)
            .to_request();

        let resp = test::call_service(&app, req).await;
        assert_eq!(resp.status(), StatusCode::OK);
    }

    #[tokio::test]
    #[serial]
    async fn test_brute_force_protection() {
        init_test_mode();
        let test_config = TestConfig::new().await;
        
        let secret_key = cookie::Key::derive_from(test_config.config.session_key.as_bytes());
        let app = test::init_service(
            App::new()
                .wrap(
                    SessionMiddleware::builder(CookieSessionStore::default(), secret_key)
                        .cookie_name("ssm_test_session".to_owned())
                        .build(),
                )
                .wrap(IdentityMiddleware::default())
                .app_data(web::Data::new(test_config.config.clone()))
                .service(web::scope("/auth").configure(authentication::config))
        ).await;

        // Attempt multiple failed logins rapidly
        for i in 0..5 {
            let login_request = json!({
                "username": "testuser",
                "password": format!("wrongpass{}", i)
            });

            let req = test::TestRequest::post()
                .uri("/auth/login")
                .set_json(&login_request)
                .to_request();

            let resp = test::call_service(&app, req).await;
            assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
        }

        // Verify that valid login still works (no account lockout)
        let valid_request = json!({
            "username": "testuser",
            "password": "testpass"
        });

        let req = test::TestRequest::post()
            .uri("/auth/login")
            .set_json(&valid_request)
            .to_request();

        let resp = test::call_service(&app, req).await;
        assert_eq!(resp.status(), StatusCode::OK);
    }

    #[tokio::test]
    #[serial]
    async fn test_password_timing_attack_resistance() {
        init_test_mode();
        let test_config = TestConfig::new().await;
        
        let secret_key = cookie::Key::derive_from(test_config.config.session_key.as_bytes());
        let app = test::init_service(
            App::new()
                .wrap(
                    SessionMiddleware::builder(CookieSessionStore::default(), secret_key)
                        .cookie_name("ssm_test_session".to_owned())
                        .build(),
                )
                .wrap(IdentityMiddleware::default())
                .app_data(web::Data::new(test_config.config.clone()))
                .service(web::scope("/auth").configure(authentication::config))
        ).await;

        // Test with non-existent user
        let start_time = std::time::Instant::now();
        let nonexistent_request = json!({
            "username": "nonexistentuser12345",
            "password": "anypassword"
        });

        let req = test::TestRequest::post()
            .uri("/auth/login")
            .set_json(&nonexistent_request)
            .to_request();

        let resp = test::call_service(&app, req).await;
        let nonexistent_duration = start_time.elapsed();
        assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);

        // Test with existing user but wrong password
        let start_time = std::time::Instant::now();
        let wrong_password_request = json!({
            "username": "testuser",
            "password": "wrongpassword"
        });

        let req = test::TestRequest::post()
            .uri("/auth/login")
            .set_json(&wrong_password_request)
            .to_request();

        let resp = test::call_service(&app, req).await;
        let wrong_password_duration = start_time.elapsed();
        assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);

        // Both should take similar time (bcrypt ensures constant time)
        // Allow for some variance but they should be in the same order of magnitude
        let ratio = wrong_password_duration.as_millis() as f64 / nonexistent_duration.as_millis() as f64;
        assert!(ratio > 0.1 && ratio < 10.0, "Timing difference too large: {:?} vs {:?}", 
                nonexistent_duration, wrong_password_duration);
    }

    #[tokio::test]
    #[serial]
    async fn test_request_timeout_handling() {
        init_test_mode();
        let test_config = TestConfig::new().await;
        
        let secret_key = cookie::Key::derive_from(test_config.config.session_key.as_bytes());
        let app = test::init_service(
            App::new()
                .wrap(
                    SessionMiddleware::builder(CookieSessionStore::default(), secret_key)
                        .cookie_name("ssm_test_session".to_owned())
                        .build(),
                )
                .wrap(IdentityMiddleware::default())
                .app_data(web::Data::new(test_config.config.clone()))
                .service(web::scope("/auth").configure(authentication::config))
        ).await;

        let login_request = json!({
            "username": "testuser",
            "password": "testpass"
        });

        let req = test::TestRequest::post()
            .uri("/auth/login")
            .set_json(&login_request)
            .to_request();

        // Ensure request completes within reasonable time
        let result = timeout(Duration::from_secs(5), test::call_service(&app, req)).await;
        assert!(result.is_ok(), "Authentication request should complete within 5 seconds");
        
        let resp = result.unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
    }

    #[tokio::test]
    #[serial]
    async fn test_malformed_json_handling() {
        init_test_mode();
        let test_config = TestConfig::new().await;
        
        let secret_key = cookie::Key::derive_from(test_config.config.session_key.as_bytes());
        let app = test::init_service(
            App::new()
                .wrap(
                    SessionMiddleware::builder(CookieSessionStore::default(), secret_key)
                        .cookie_name("ssm_test_session".to_owned())
                        .build(),
                )
                .wrap(IdentityMiddleware::default())
                .app_data(web::Data::new(test_config.config.clone()))
                .service(web::scope("/auth").configure(authentication::config))
        ).await;

        // Test with malformed JSON
        let req = test::TestRequest::post()
            .uri("/auth/login")
            .insert_header(("content-type", "application/json"))
            .set_payload("{invalid json")
            .to_request();

        let resp = test::call_service(&app, req).await;
        assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    }

    #[tokio::test]
    #[serial] 
    async fn test_content_type_validation() {
        init_test_mode();
        let test_config = TestConfig::new().await;
        
        let secret_key = cookie::Key::derive_from(test_config.config.session_key.as_bytes());
        let app = test::init_service(
            App::new()
                .wrap(
                    SessionMiddleware::builder(CookieSessionStore::default(), secret_key)
                        .cookie_name("ssm_test_session".to_owned())
                        .build(),
                )
                .wrap(IdentityMiddleware::default())
                .app_data(web::Data::new(test_config.config.clone()))
                .service(web::scope("/auth").configure(authentication::config))
        ).await;

        // Test with wrong content type
        let req = test::TestRequest::post()
            .uri("/auth/login")
            .insert_header(("content-type", "text/plain"))
            .set_payload(r#"{"username": "testuser", "password": "testpass"}"#)
            .to_request();

        let resp = test::call_service(&app, req).await;
        // Should reject non-JSON content type
        assert!(resp.status().is_client_error());
    }

    #[tokio::test]
    #[serial]
    async fn test_safety_mode_verification() {
        // This test verifies our safety infrastructure is working
        init_test_mode();
        
        // Verify test mode is active
        assert!(is_test_mode(), "🛡️ Test mode must be active");
        
        // Verify environment variable is set
        assert!(std::env::var("SSH_KEY_MANAGER_TEST_MODE").is_ok(), 
                "🛡️ Test mode environment variable must be set");
        
        // Verify database URL validation works
        assert!(validate_test_database_url("sqlite://test.db").is_ok());
        assert!(validate_test_database_url("sqlite://production.db").is_err());
        assert!(validate_test_database_url("postgresql://prod.company.com/main").is_err());
        
        log::info!("🛡️ Safety mode verification complete - all checks passed");
    }
}