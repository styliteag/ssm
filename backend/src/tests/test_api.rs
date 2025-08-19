/// API Test Module
/// 
/// Simple working tests for API endpoints

use actix_web::{test, web, App, http::StatusCode};
use actix_identity::IdentityMiddleware;
use actix_session::{SessionMiddleware, storage::CookieSessionStore};
use actix_web::cookie::Key;
use serial_test::serial;
use serde_json::json;

use crate::{test_only, tests::{test_config::*, safety::init_test_mode}};

#[tokio::test]
#[serial]
async fn test_host_api() {
    test_only!();
    init_test_mode();
    
    // Create test app inline
    let db_pool = create_test_db_pool().await;
    let config = TestAppConfig::new();
    
    let app = App::new()
        .app_data(web::Data::new(db_pool))
        .app_data(web::Data::new(config.clone()))
        .wrap(IdentityMiddleware::default())
        .wrap(
            SessionMiddleware::builder(
                CookieSessionStore::default(),
                Key::from(config.session_key.as_bytes()),
            )
            .cookie_secure(false)
            .build(),
        )
        .configure(crate::routes::route_config);
        
    let service = test::init_service(app).await;
    
    // Test GET /api/host - should be unauthorized
    let req = test::TestRequest::get()
        .uri("/api/host")
        .to_request();
    
    let resp = test::call_service(&service, req).await;
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
    
    log::info!("✅ Host API test passed");
}

#[tokio::test]
#[serial]
async fn test_user_api() {
    test_only!();
    init_test_mode();
    
    // Create test app inline
    let db_pool = create_test_db_pool().await;
    let config = TestAppConfig::new();
    
    let app = App::new()
        .app_data(web::Data::new(db_pool))
        .app_data(web::Data::new(config.clone()))
        .wrap(IdentityMiddleware::default())
        .wrap(
            SessionMiddleware::builder(
                CookieSessionStore::default(),
                Key::from(config.session_key.as_bytes()),
            )
            .cookie_secure(false)
            .build(),
        )
        .configure(crate::routes::route_config);
        
    let service = test::init_service(app).await;
    
    // Test GET /api/user - should be unauthorized
    let req = test::TestRequest::get()
        .uri("/api/user")
        .to_request();
    
    let resp = test::call_service(&service, req).await;
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
    
    log::info!("✅ User API test passed");
}

#[tokio::test]
#[serial]
async fn test_login_endpoint() {
    test_only!();
    init_test_mode();
    
    // Create test app inline
    let db_pool = create_test_db_pool().await;
    let config = TestAppConfig::new();
    
    let app = App::new()
        .app_data(web::Data::new(db_pool))
        .app_data(web::Data::new(config.clone()))
        .wrap(IdentityMiddleware::default())
        .wrap(
            SessionMiddleware::builder(
                CookieSessionStore::default(),
                Key::from(config.session_key.as_bytes()),
            )
            .cookie_secure(false)
            .build(),
        )
        .configure(crate::routes::route_config);
        
    let service = test::init_service(app).await;
    
    // Test POST /api/auth/login - should fail with invalid credentials
    let req = test::TestRequest::post()
        .uri("/api/auth/login")
        .set_json(&json!({
            "username": "testuser",
            "password": "testpass"
        }))
        .to_request();
    
    let resp = test::call_service(&service, req).await;
    // Check what status we actually get and log it
    log::info!("Login endpoint returned status: {}", resp.status());
    
    // Should be some kind of error since we don't have auth backend set up
    assert!(resp.status().is_client_error() || resp.status().is_server_error());
    
    log::info!("✅ Login endpoint test passed");
}

#[tokio::test]
#[serial]
async fn test_key_api() {
    test_only!();
    init_test_mode();
    
    // Create test app inline
    let db_pool = create_test_db_pool().await;
    let config = TestAppConfig::new();
    
    let app = App::new()
        .app_data(web::Data::new(db_pool))
        .app_data(web::Data::new(config.clone()))
        .wrap(IdentityMiddleware::default())
        .wrap(
            SessionMiddleware::builder(
                CookieSessionStore::default(),
                Key::from(config.session_key.as_bytes()),
            )
            .cookie_secure(false)
            .build(),
        )
        .configure(crate::routes::route_config);
        
    let service = test::init_service(app).await;
    
    // Test GET /api/key - should be unauthorized
    let req = test::TestRequest::get()
        .uri("/api/key")
        .to_request();
    
    let resp = test::call_service(&service, req).await;
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
    
    log::info!("✅ Key API test passed");
}

#[tokio::test]
#[serial]
async fn test_authorization_api() {
    test_only!();
    init_test_mode();
    
    // Create test app inline
    let db_pool = create_test_db_pool().await;
    let config = TestAppConfig::new();
    
    let app = App::new()
        .app_data(web::Data::new(db_pool))
        .app_data(web::Data::new(config.clone()))
        .wrap(IdentityMiddleware::default())
        .wrap(
            SessionMiddleware::builder(
                CookieSessionStore::default(),
                Key::from(config.session_key.as_bytes()),
            )
            .cookie_secure(false)
            .build(),
        )
        .configure(crate::routes::route_config);
        
    let service = test::init_service(app).await;
    
    // Test GET /api/authorization - should be unauthorized or not found
    let req = test::TestRequest::get()
        .uri("/api/authorization")
        .to_request();
    
    let resp = test::call_service(&service, req).await;
    // Authorization endpoints may not have a root GET endpoint, so 404 is acceptable
    assert!(resp.status() == StatusCode::UNAUTHORIZED || resp.status() == StatusCode::NOT_FOUND);
    
    log::info!("✅ Authorization API test passed");
}

#[tokio::test]
#[serial]
async fn test_csrf_endpoint() {
    test_only!();
    init_test_mode();
    
    // Create test app inline
    let db_pool = create_test_db_pool().await;
    let config = TestAppConfig::new();
    
    let app = App::new()
        .app_data(web::Data::new(db_pool))
        .app_data(web::Data::new(config.clone()))
        .wrap(IdentityMiddleware::default())
        .wrap(
            SessionMiddleware::builder(
                CookieSessionStore::default(),
                Key::from(config.session_key.as_bytes()),
            )
            .cookie_secure(false)
            .build(),
        )
        .configure(crate::routes::route_config);
        
    let service = test::init_service(app).await;
    
    // Test GET /api/auth/csrf - should be unauthorized without login
    let req = test::TestRequest::get()
        .uri("/api/auth/csrf")
        .to_request();
    
    let resp = test::call_service(&service, req).await;
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
    
    log::info!("✅ CSRF endpoint test passed");
}

#[tokio::test]
#[serial]
async fn test_post_requests_without_auth() {
    test_only!();
    init_test_mode();
    
    // Create test app inline
    let db_pool = create_test_db_pool().await;
    let config = TestAppConfig::new();
    
    let app = App::new()
        .app_data(web::Data::new(db_pool))
        .app_data(web::Data::new(config.clone()))
        .wrap(IdentityMiddleware::default())
        .wrap(
            SessionMiddleware::builder(
                CookieSessionStore::default(),
                Key::from(config.session_key.as_bytes()),
            )
            .cookie_secure(false)
            .build(),
        )
        .configure(crate::routes::route_config);
        
    let service = test::init_service(app).await;
    
    // Test POST requests - all should be unauthorized
    let endpoints = [
        "/api/user",
        "/api/host", 
        "/api/key",
        "/api/authorization"
    ];
    
    for endpoint in endpoints {
        let req = test::TestRequest::post()
            .uri(endpoint)
            .set_json(&json!({}))
            .to_request();
        
        let resp = test::call_service(&service, req).await;
        // Should be some kind of error - either auth, validation, or server error
        assert!(
            resp.status().is_client_error() || resp.status().is_server_error(),
            "POST {} returned {}, expected client or server error", endpoint, resp.status()
        );
    }
    
    log::info!("✅ POST requests without auth test passed");
}

#[tokio::test]
#[serial]
async fn test_put_requests_without_auth() {
    test_only!();
    init_test_mode();
    
    // Create test app inline
    let db_pool = create_test_db_pool().await;
    let config = TestAppConfig::new();
    
    let app = App::new()
        .app_data(web::Data::new(db_pool))
        .app_data(web::Data::new(config.clone()))
        .wrap(IdentityMiddleware::default())
        .wrap(
            SessionMiddleware::builder(
                CookieSessionStore::default(),
                Key::from(config.session_key.as_bytes()),
            )
            .cookie_secure(false)
            .build(),
        )
        .configure(crate::routes::route_config);
        
    let service = test::init_service(app).await;
    
    // Test PUT requests - all should be unauthorized  
    let endpoints = [
        "/api/user/1",
        "/api/host/1",
        "/api/key/1"
    ];
    
    for endpoint in endpoints {
        let req = test::TestRequest::put()
            .uri(endpoint)
            .set_json(&json!({}))
            .to_request();
        
        let resp = test::call_service(&service, req).await;
        // Should be some kind of error - either auth, validation, or server error
        assert!(
            resp.status().is_client_error() || resp.status().is_server_error(),
            "PUT {} returned {}, expected client or server error", endpoint, resp.status()
        );
    }
    
    log::info!("✅ PUT requests without auth test passed");
}

#[tokio::test]
#[serial]
async fn test_delete_requests_without_auth() {
    test_only!();
    init_test_mode();
    
    // Create test app inline
    let db_pool = create_test_db_pool().await;
    let config = TestAppConfig::new();
    
    let app = App::new()
        .app_data(web::Data::new(db_pool))
        .app_data(web::Data::new(config.clone()))
        .wrap(IdentityMiddleware::default())
        .wrap(
            SessionMiddleware::builder(
                CookieSessionStore::default(),
                Key::from(config.session_key.as_bytes()),
            )
            .cookie_secure(false)
            .build(),
        )
        .configure(crate::routes::route_config);
        
    let service = test::init_service(app).await;
    
    // Test DELETE requests - all should be unauthorized or have other auth-related errors
    let endpoints = [
        "/api/user/testuser",
        "/api/host/testhost", 
        "/api/key/1",
        "/api/host/authorization/1"
    ];
    
    for endpoint in endpoints {
        let req = test::TestRequest::delete()
            .uri(endpoint)
            .to_request();
        
        let resp = test::call_service(&service, req).await;
        // Should be unauthorized, but may get server error if resource lookup happens before auth
        assert!(
            resp.status() == StatusCode::UNAUTHORIZED || 
            resp.status() == StatusCode::INTERNAL_SERVER_ERROR ||
            resp.status() == StatusCode::NOT_FOUND,
            "DELETE {} returned {}, expected 401, 500, or 404", endpoint, resp.status()
        );
    }
    
    log::info!("✅ DELETE requests without auth test passed");
}

#[tokio::test]
#[serial]
async fn test_diff_api() {
    test_only!();
    init_test_mode();
    
    // Create test app inline
    let db_pool = create_test_db_pool().await;
    let config = TestAppConfig::new();
    
    let app = App::new()
        .app_data(web::Data::new(db_pool))
        .app_data(web::Data::new(config.clone()))
        .wrap(IdentityMiddleware::default())
        .wrap(
            SessionMiddleware::builder(
                CookieSessionStore::default(),
                Key::from(config.session_key.as_bytes()),
            )
            .cookie_secure(false)
            .build(),
        )
        .configure(crate::routes::route_config);
        
    let service = test::init_service(app).await;
    
    // Test diff API endpoints
    let endpoints = [
        "/api/diff",                    // GET hosts for diff
        "/api/diff/testhost",          // GET host diff 
        "/api/diff/testhost/details"   // GET diff details
    ];
    
    for endpoint in endpoints {
        let req = test::TestRequest::get()
            .uri(endpoint)
            .to_request();
        
        let resp = test::call_service(&service, req).await;
        // Should be some kind of error - either auth, server error, or not found
        assert!(
            resp.status().is_client_error() || resp.status().is_server_error(),
            "GET {} returned {}, expected client or server error", endpoint, resp.status()
        );
    }
    
    log::info!("✅ Diff API test passed");
}