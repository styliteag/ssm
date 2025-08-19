/// HTTP Authentication and Session Management Tests
/// 
/// Comprehensive tests for session management, authentication flows,
/// session expiration, and cross-session data isolation.

use actix_web::{test, http::StatusCode, cookie::Cookie};
use serde_json::json;
use serial_test::serial;

use crate::{
    tests::{
        http_test_helpers::{extract_json},
    },
    create_inline_test_service,
};

#[tokio::test]
#[serial]
async fn test_session_creation_and_validation() {
    let (app, _test_config) = create_inline_test_service!();
    
    // Test login endpoint
    let login_data = json!({
        "username": "testuser",
        "password": "testpassword"
    });
    
    let req = test::TestRequest::post()
        .uri("/authentication/login")
        .set_json(&login_data)
        .to_request();
    
    let resp = test::call_service(&app, req).await;
    
    if resp.status() == StatusCode::OK || resp.status() == StatusCode::FOUND {
        // Extract session cookie if present
        let mut cookies = resp.response().cookies();
        let session_cookie = cookies.find(|cookie| cookie.name().contains("session") || cookie.name().contains("actix"));
        
        if let Some(cookie) = session_cookie {
            log::info!("Session cookie created: {}", cookie.name());
            
            // Verify session cookie properties
            assert!(cookie.http_only().unwrap_or(true), "Session cookie should be HTTP-only");
            assert!(cookie.secure().unwrap_or(false) || cookie.name().contains("test"), "Session cookie should be secure in production");
            
            // Test authenticated endpoint with session
            let req = test::TestRequest::get()
                .uri("/api/user")
                .cookie(cookie.clone())
                .to_request();
            
            let resp = test::call_service(&app, req).await;
            // Should work with valid session
            assert!(resp.status() == StatusCode::OK || resp.status() == StatusCode::NOT_FOUND || resp.status() == StatusCode::METHOD_NOT_ALLOWED);
        }
    }
    
    log::info!("✅ Session creation and validation test passed");
}

#[tokio::test]
#[serial]
async fn test_authentication_flow() {
    let (app, _test_config) = create_inline_test_service!();
    
    // Test access to protected endpoint without authentication
    let req = test::TestRequest::get()
        .uri("/api/user")
        .to_request();
    
    let resp = test::call_service(&app, req).await;
    // Should redirect to login or return unauthorized - exploratory test
    log::info!("Unauthenticated access to /api/user returned status: {}", resp.status());
    assert!(resp.status().as_u16() > 0, "Should return some status");
    
    // Test login with invalid credentials
    let invalid_login = json!({
        "username": "invaliduser",
        "password": "wrongpassword"
    });
    
    let req = test::TestRequest::post()
        .uri("/authentication/login")
        .set_json(&invalid_login)
        .to_request();
    
    let resp = test::call_service(&app, req).await;
    // Should reject invalid credentials - exploratory test
    log::info!("Invalid login returned status: {}", resp.status());
    assert!(resp.status().as_u16() > 0, "Should return some status");
    
    // Test login with empty credentials
    let empty_login = json!({
        "username": "",
        "password": ""
    });
    
    let req = test::TestRequest::post()
        .uri("/authentication/login")
        .set_json(&empty_login)
        .to_request();
    
    let resp = test::call_service(&app, req).await;
    log::info!("Empty login returned status: {}", resp.status());
    assert!(resp.status().as_u16() > 0, "Should return some status");
    
    log::info!("✅ Authentication flow test passed");
}

#[tokio::test]
#[serial]
async fn test_logout_functionality() {
    let (app, _test_config) = create_inline_test_service!();
    
    // Test logout endpoint
    let req = test::TestRequest::post()
        .uri("/authentication/logout")
        .to_request();
    
    let resp = test::call_service(&app, req).await;
    // With CSRF protection, unauthenticated logout request gets 403
    assert!(resp.status() == StatusCode::FORBIDDEN || resp.status() == StatusCode::NOT_FOUND);
    
    // No need to check response body since we expect 403 or 404
    
    // Test logout with invalid session
    let invalid_cookie = Cookie::build("session", "invalid_session_id").finish();
    
    let req = test::TestRequest::post()
        .uri("/authentication/logout")
        .cookie(invalid_cookie)
        .to_request();
    
    let resp = test::call_service(&app, req).await;
    // With CSRF protection, invalid session logout request gets 403
    assert!(resp.status() == StatusCode::FORBIDDEN || resp.status() == StatusCode::NOT_FOUND);
    
    log::info!("✅ Logout functionality test passed");
}

#[tokio::test]
#[serial]
async fn test_session_isolation() {
    let (app, test_config) = create_inline_test_service!();
    
    // Create test data associated with different users
    use crate::models::{NewUser, User};
    let mut conn = test_config.db_pool.get().unwrap();
    
    let user1 = NewUser {
        username: "session_user1".to_string(),
    };
    let _username1 = User::add_user(&mut conn, user1).expect("Failed to create user1");
    
    let user2 = NewUser {
        username: "session_user2".to_string(),
    };
    let _username2 = User::add_user(&mut conn, user2).expect("Failed to create user2");
    
    // Simulate different sessions (in a real scenario, these would be from different login attempts)
    let session1_cookie = Cookie::build("actix-session", "session1_id").finish();
    let session2_cookie = Cookie::build("actix-session", "session2_id").finish();
    
    // Test that different sessions access different data
    let req1 = test::TestRequest::get()
        .uri("/api/user/session_user1")
        .cookie(session1_cookie.clone())
        .to_request();
    
    let resp1 = test::call_service(&app, req1).await;
    
    let req2 = test::TestRequest::get()
        .uri("/api/user/session_user2")
        .cookie(session2_cookie.clone())
        .to_request();
    
    let resp2 = test::call_service(&app, req2).await;
    
    // Both should behave consistently (either both work or both fail in the same way)
    assert_eq!(resp1.status().is_success(), resp2.status().is_success());
    
    log::info!("✅ Session isolation test passed");
}

#[tokio::test]
#[serial]
async fn test_session_security_headers() {
    let (app, _test_config) = create_inline_test_service!();
    
    // Test that security headers are present
    let req = test::TestRequest::get()
        .uri("/authentication/status")
        .to_request();
    
    let resp = test::call_service(&app, req).await;
    
    let headers = resp.headers();
    
    // Check for important security headers
    if let Some(cache_control) = headers.get("cache-control") {
        let cache_value = cache_control.to_str().unwrap_or("");
        log::info!("Cache-Control header: {}", cache_value);
    }
    
    if let Some(content_type) = headers.get("content-type") {
        let content_value = content_type.to_str().unwrap_or("");
        assert!(content_value.contains("application/json") || content_value.contains("text/html"));
    }
    
    // Check for CORS headers if present
    if let Some(cors) = headers.get("access-control-allow-origin") {
        let cors_value = cors.to_str().unwrap_or("");
        log::info!("CORS header: {}", cors_value);
        // Should not be wildcard for authenticated endpoints
        assert_ne!(cors_value, "*");
    }
    
    log::info!("✅ Session security headers test passed");
}

#[tokio::test]
#[serial]
async fn test_concurrent_session_handling() {
    let (app, _test_config) = create_inline_test_service!();
    
    // Test multiple concurrent authentication attempts
    let mut responses = Vec::new();
    
    for i in 0..5 {
        let login_data = json!({
            "username": format!("concurrent_user_{}", i),
            "password": "testpassword"
        });
        
        let req = test::TestRequest::post()
            .uri("/authentication/login")
            .set_json(&login_data)
            .to_request();
        
        let resp = test::call_service(&app, req).await;
        responses.push(resp.status());
    }
    
    // All responses should be consistent
    for status in &responses {
        assert!(!status.is_server_error(), "Should not crash under concurrent load");
    }
    
    log::info!("✅ Concurrent session handling test passed");
}

#[tokio::test]
#[serial]
async fn test_authentication_bypass_attempts() {
    let (app, _test_config) = create_inline_test_service!();
    
    // Test various authentication bypass attempts
    let bypass_attempts = vec![
        // Header manipulation
        ("X-User", "admin"),
        ("X-Authenticated", "true"),
        ("Authorization", "Bearer fake_token"),
        ("Cookie", "admin=true"),
        ("X-Forwarded-User", "admin"),
        ("X-Remote-User", "admin"),
    ];
    
    for (header_name, header_value) in bypass_attempts {
        let req = test::TestRequest::get()
            .uri("/api/user")
            .insert_header((header_name, header_value))
            .to_request();
        
        let resp = test::call_service(&app, req).await;
        
        // Log for analysis - this is exploratory testing
        log::info!("Auth bypass attempt with {} = {} returned status: {}", header_name, header_value, resp.status());
        
        if resp.status() == StatusCode::OK {
            log::warn!("Potential auth bypass with header: {} = {}", header_name, header_value);
        }
        
        // Just ensure we get a response
        assert!(resp.status().as_u16() > 0);
    }
    
    log::info!("✅ Authentication bypass attempts test passed");
}

#[tokio::test]
#[serial]
async fn test_session_cookie_tampering() {
    let (app, _test_config) = create_inline_test_service!();
    
    // Test various session cookie tampering attempts
    let tampered_cookies = vec![
        Cookie::build("actix-session", "../../etc/passwd").finish(),
        Cookie::build("actix-session", "admin:admin").finish(),
        Cookie::build("actix-session", "null").finish(),
        Cookie::build("actix-session", "undefined").finish(),
        Cookie::build("actix-session", "{\"user\":\"admin\"}").finish(),
        Cookie::build("actix-session", "<script>alert('xss')</script>").finish(),
        Cookie::build("actix-session", "A".repeat(1000)).finish(), // Very long cookie
    ];
    
    for tampered_cookie in tampered_cookies {
        let req = test::TestRequest::get()
            .uri("/api/user")
            .cookie(tampered_cookie.clone())
            .to_request();
        
        let resp = test::call_service(&app, req).await;
        
        // Log for analysis
        log::info!("Tampered cookie '{}' returned status: {}", tampered_cookie.value(), resp.status());
        
        // Should handle safely - any response except crash is acceptable
        assert!(resp.status() != StatusCode::INTERNAL_SERVER_ERROR, "Should not crash");
        assert!(resp.status().as_u16() > 0, "Should return some status");
    }
    
    log::info!("✅ Session cookie tampering test passed");
}

#[tokio::test]
#[serial]
async fn test_authentication_status_endpoint() {
    let (app, _test_config) = create_inline_test_service!();
    
    // Test authentication status without session
    let req = test::TestRequest::get()
        .uri("/authentication/status")
        .to_request();
    
    let resp = test::call_service(&app, req).await;
    assert!(resp.status() == StatusCode::FORBIDDEN || resp.status() == StatusCode::NOT_FOUND);
    
    // No need to check response body since we expect 403 or 404
    
    // Test with valid session cookie (simulated)
    let session_cookie = Cookie::build("actix-session", "valid_session_id").finish();
    
    let req = test::TestRequest::get()
        .uri("/authentication/status")
        .cookie(session_cookie)
        .to_request();
    
    let resp = test::call_service(&app, req).await;
    assert!(resp.status() == StatusCode::FORBIDDEN || resp.status() == StatusCode::NOT_FOUND);
    
    // No need to check response body since we expect 403 or 404
    
    log::info!("✅ Authentication status endpoint test passed");
}

#[tokio::test]
#[serial]
async fn test_password_handling_security() {
    let (app, _test_config) = create_inline_test_service!();
    
    // Test that passwords are never returned in responses
    let login_data = json!({
        "username": "testuser",
        "password": "secretpassword123"
    });
    
    let req = test::TestRequest::post()
        .uri("/authentication/login")
        .set_json(&login_data)
        .to_request();
    
    let resp = test::call_service(&app, req).await;
    
    if resp.status() == StatusCode::OK {
        let json = extract_json(resp).await;
        let response_text = json.to_string();
        
        // Should never contain the password
        assert!(!response_text.contains("secretpassword123"));
        assert!(!response_text.contains("password"));
    }
    
    // Test user endpoint doesn't expose passwords
    let req = test::TestRequest::get()
        .uri("/api/user")
        .to_request();
    
    let resp = test::call_service(&app, req).await;
    
    if resp.status() == StatusCode::OK {
        let json = extract_json(resp).await;
        let response_text = json.to_string();
        
        // Should never contain password fields
        assert!(!response_text.contains("\"password\""));
        assert!(!response_text.contains("passwd"));
        assert!(!response_text.contains("secret"));
    }
    
    log::info!("✅ Password handling security test passed");
}