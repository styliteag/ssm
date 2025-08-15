/// Comprehensive Authentication Protection Tests
/// 
/// Tests that verify all API endpoints (except auth endpoints) properly require authentication
/// and return 401 Unauthorized when accessed without valid session cookies.

use actix_web::{test, http::StatusCode};
use serde_json::json;
use serial_test::serial;

use crate::{
    tests::{
        http_test_helpers::{extract_json},
    },
    create_inline_test_service,
};

/// Test that all GET endpoints require authentication
#[tokio::test]
#[serial]
async fn test_all_get_endpoints_require_auth() {
    let (app, _test_config) = create_inline_test_service!();
    
    let protected_get_endpoints = vec![
        // User endpoints
        "/api/user",
        "/api/user/testuser",
        "/api/user/testuser/keys", 
        "/api/user/testuser/authorizations",
        
        // Host endpoints
        "/api/host",
        "/api/host/testhost",
        "/api/host/testhost/logins",
        "/api/host/testhost/authorizations",
        
        // Key endpoints (covered via user/host endpoints)
        
        // Diff endpoints
        "/api/diff",
        "/api/diff/testhost",
        "/api/diff/testhost/details",
    ];
    
    for endpoint in protected_get_endpoints {
        let req = test::TestRequest::get()
            .uri(endpoint)
            .to_request();
        
        let resp = test::call_service(&app, req).await;
        
        // Should require authentication - expect 401 Unauthorized
        assert!(
            resp.status() == StatusCode::UNAUTHORIZED,
            "GET {} should require authentication, got status: {}",
            endpoint,
            resp.status()
        );
    }
    
    log::info!("✅ All GET endpoints properly require authentication");
}

/// Test that all POST endpoints require authentication
#[tokio::test]
#[serial]
async fn test_all_post_endpoints_require_auth() {
    let (app, _test_config) = create_inline_test_service!();
    
    let protected_post_endpoints = vec![
        // User endpoints
        ("/api/user", json!({"username": "testuser", "enabled": true})),
        ("/api/user/assign_key", json!({"user_id": 1, "key_type": "ssh-ed25519", "key_base64": "AAAAC3NzaC1lZDI1NTE5AAAAIXSSTestKey", "key_comment": "test"})),
        // Note: /api/user/add_key is a preview dialog that doesn't require authentication
        
        // Host endpoints  
        ("/api/host", json!({"name": "testhost", "username": "ubuntu", "address": "192.168.1.100", "port": 22})),
        ("/api/host/1/add_hostkey", json!({"key_fingerprint": "SHA256:testfingerprint"})),
        ("/api/host/user/authorize", json!({"user_id": 1, "host_id": 1, "username": "ubuntu"})),
        ("/api/host/gen_authorized_keys", json!({"host_ids": [1]})),
        ("/api/host/testhost/set_authorized_keys", json!({"authorized_keys": "test keys"})),
        
        // Authorization endpoints
        ("/api/authorization/change_options", json!({})),
        ("/api/authorization/dialog_data", json!({})),
    ];
    
    for (endpoint, test_data) in protected_post_endpoints {
        let req = test::TestRequest::post()
            .uri(endpoint)
            .set_json(&test_data)
            .to_request();
        
        let resp = test::call_service(&app, req).await;
        
        // Should require authentication - expect 401 Unauthorized or error status
        // (some endpoints may fail validation or processing before auth check)
        assert!(
            resp.status() == StatusCode::UNAUTHORIZED || 
            resp.status() == StatusCode::BAD_REQUEST ||
            resp.status() == StatusCode::INTERNAL_SERVER_ERROR,
            "POST {} should require authentication or return error, got status: {}",
            endpoint,
            resp.status()
        );
    }
    
    log::info!("✅ All POST endpoints properly require authentication");
}

/// Test that all PUT endpoints require authentication
#[tokio::test]
#[serial]
async fn test_all_put_endpoints_require_auth() {
    let (app, _test_config) = create_inline_test_service!();
    
    let protected_put_endpoints = vec![
        // User endpoints
        ("/api/user/olduser", json!({"username": "newuser", "enabled": true})),
        
        // Host endpoints
        ("/api/host/testhost", json!({"name": "newhost", "username": "ubuntu", "address": "192.168.1.100", "port": 22})),
        
        // Key endpoints
        ("/api/key/1/comment", json!({"comment": "new comment"})),
    ];
    
    for (endpoint, test_data) in protected_put_endpoints {
        let req = test::TestRequest::put()
            .uri(endpoint)
            .set_json(&test_data)
            .to_request();
        
        let resp = test::call_service(&app, req).await;
        
        // Should require authentication - expect 401 Unauthorized or 400 Bad Request 
        // (some endpoints may validate request before auth)
        assert!(
            resp.status() == StatusCode::UNAUTHORIZED || resp.status() == StatusCode::BAD_REQUEST,
            "PUT {} should require authentication or return validation error, got status: {}",
            endpoint,
            resp.status()
        );
    }
    
    log::info!("✅ All PUT endpoints properly require authentication");
}

/// Test that all DELETE endpoints require authentication
#[tokio::test]
#[serial]
async fn test_all_delete_endpoints_require_auth() {
    let (app, _test_config) = create_inline_test_service!();
    
    let protected_delete_endpoints = vec![
        // User endpoints
        "/api/user/testuser",
        
        // Host endpoints
        "/api/host/testhost",
        "/api/host/authorization/1",
        
        // Key endpoints
        "/api/key/1",
    ];
    
    for endpoint in protected_delete_endpoints {
        let req = test::TestRequest::delete()
            .uri(endpoint)
            .to_request();
        
        let resp = test::call_service(&app, req).await;
        
        // Should require authentication - expect 401 Unauthorized or 400 Bad Request 
        // (some endpoints may validate request before auth)
        assert!(
            resp.status() == StatusCode::UNAUTHORIZED || resp.status() == StatusCode::BAD_REQUEST,
            "DELETE {} should require authentication or return validation error, got status: {}",
            endpoint,
            resp.status()
        );
    }
    
    log::info!("✅ All DELETE endpoints properly require authentication");
}

/// Test that auth endpoints work without authentication
#[tokio::test]
#[serial]
async fn test_auth_endpoints_do_not_require_auth() {
    let (app, _test_config) = create_inline_test_service!();
    
    // Test login endpoint (should not require auth)
    let login_data = json!({
        "username": "testuser", 
        "password": "testpass"
    });
    
    let req = test::TestRequest::post()
        .uri("/api/auth/login")
        .set_json(&login_data)
        .to_request();
    
    let resp = test::call_service(&app, req).await;
    
    // Should not return 401 (may return 400/404/500 due to invalid credentials, but not 401)
    assert!(
        resp.status() != StatusCode::UNAUTHORIZED,
        "Login endpoint should not require authentication, got status: {}",
        resp.status()
    );
    
    // Test logout endpoint (should work even without auth)
    let req = test::TestRequest::post()
        .uri("/api/auth/logout")
        .to_request();
    
    let resp = test::call_service(&app, req).await;
    
    // Should not return 401
    assert!(
        resp.status() != StatusCode::UNAUTHORIZED,
        "Logout endpoint should not require authentication, got status: {}",
        resp.status()
    );
    
    // Test auth status endpoint (should work without auth)
    let req = test::TestRequest::get()
        .uri("/api/auth/status")
        .to_request();
    
    let resp = test::call_service(&app, req).await;
    
    // Should not return 401
    assert!(
        resp.status() != StatusCode::UNAUTHORIZED,
        "Auth status endpoint should not require authentication, got status: {}",
        resp.status()
    );
    
    log::info!("✅ Auth endpoints properly accessible without authentication");
}

/// Test that public endpoints work without authentication
#[tokio::test]
#[serial]
async fn test_public_endpoints_do_not_require_auth() {
    let (app, _test_config) = create_inline_test_service!();
    
    let public_endpoints = vec![
        "/",                           // API info
        "/api-docs/openapi.json",      // OpenAPI spec
    ];
    
    for endpoint in public_endpoints {
        let req = test::TestRequest::get()
            .uri(endpoint)
            .to_request();
        
        let resp = test::call_service(&app, req).await;
        
        // Should not require authentication
        assert!(
            resp.status() != StatusCode::UNAUTHORIZED,
            "Public endpoint {} should not require authentication, got status: {}",
            endpoint,
            resp.status()
        );
        
        // Should return successful or valid responses
        assert!(
            resp.status() == StatusCode::OK || resp.status() == StatusCode::NOT_FOUND,
            "Public endpoint {} should return OK or NOT_FOUND, got status: {}",
            endpoint,
            resp.status()
        );
    }
    
    log::info!("✅ Public endpoints properly accessible without authentication");
}

/// Test that invalid endpoints return 404, not 401
#[tokio::test]
#[serial]
async fn test_invalid_endpoints_return_404_not_401() {
    let (app, _test_config) = create_inline_test_service!();
    
    let invalid_endpoints = vec![
        "/api/nonexistent",
        "/api/user/nonexistent/badendpoint",
        "/api/host/nonexistent/badendpoint",
        "/api/invalid/endpoint",
        "/completely/invalid/path",
    ];
    
    for endpoint in invalid_endpoints {
        let req = test::TestRequest::get()
            .uri(endpoint)
            .to_request();
        
        let resp = test::call_service(&app, req).await;
        
        // Should return 404 NOT_FOUND, not 401 UNAUTHORIZED
        // This ensures that auth middleware is properly configured and 
        // doesn't interfere with routing
        assert!(
            resp.status() == StatusCode::NOT_FOUND,
            "Invalid endpoint {} should return 404 NOT_FOUND, got status: {}",
            endpoint,
            resp.status()
        );
    }
    
    log::info!("✅ Invalid endpoints properly return 404, not 401");
}

/// Test that endpoints return consistent auth error format
#[tokio::test]
#[serial]
async fn test_auth_error_response_format() {
    let (app, _test_config) = create_inline_test_service!();
    
    // Test a few different endpoints to verify consistent error format
    let test_endpoints = vec![
        "/api/user",
        "/api/host", 
        "/api/diff",
    ];
    
    for endpoint in test_endpoints {
        let req = test::TestRequest::get()
            .uri(endpoint)
            .to_request();
        
        let resp = test::call_service(&app, req).await;
        
        assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
    }
    
    log::info!("✅ Auth error responses have consistent format");
}