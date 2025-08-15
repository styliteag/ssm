/// Session-Based Authentication Tests
/// 
/// Tests that verify the session/cookie authentication system works correctly,
/// including login flow, session persistence, logout functionality, and session security.

use actix_web::{test, http::StatusCode, cookie::Cookie};
use serde_json::json;
use serial_test::serial;
use std::fs;
use std::path::PathBuf;
use bcrypt::{hash, DEFAULT_COST};

use crate::{
    tests::{
        http_test_helpers::{extract_json},
    },
    create_inline_test_service,
};

/// Test successful login creates valid session
#[tokio::test]
#[serial]
async fn test_successful_login_creates_session() {
    let (app, test_config) = create_inline_test_service!();
    
    // Create a test htpasswd file
    let htpasswd_path = test_config.config.htpasswd_path.clone();
    let test_password = "testpass";
    let hashed_password = hash(test_password, DEFAULT_COST).expect("Failed to hash password");
    let htpasswd_content = format!("testuser:{}", hashed_password);
    
    // Ensure directory exists
    if let Some(parent) = htpasswd_path.parent() {
        std::fs::create_dir_all(parent).ok();
    }
    
    fs::write(&htpasswd_path, htpasswd_content).expect("Failed to write htpasswd file");
    
    // Test login with correct credentials
    let login_data = json!({
        "username": "testuser",
        "password": test_password
    });
    
    let req = test::TestRequest::post()
        .uri("/api/auth/login")
        .set_json(&login_data)
        .to_request();
    
    let resp = test::call_service(&app, req).await;
    
    // Should successfully login
    assert_eq!(resp.status(), StatusCode::OK, "Login should succeed with valid credentials");
    
    // Verify response structure
    let json = extract_json(resp).await;
    assert_eq!(json["success"], true);
    assert_eq!(json["data"]["username"], "testuser");
    assert_eq!(json["data"]["success"], true);
    
    // Clean up
    let _ = fs::remove_file(&htpasswd_path);
    
    log::info!("✅ Successful login creates valid session");
}

/// Test login with invalid credentials fails
#[tokio::test]
#[serial]
async fn test_login_with_invalid_credentials_fails() {
    let (app, test_config) = create_inline_test_service!();
    
    // Create a test htpasswd file
    let htpasswd_path = test_config.config.htpasswd_path.clone();
    let test_password = "correctpassword";
    let hashed_password = hash(test_password, DEFAULT_COST).expect("Failed to hash password");
    let htpasswd_content = format!("testuser:{}", hashed_password);
    
    // Ensure directory exists
    if let Some(parent) = htpasswd_path.parent() {
        std::fs::create_dir_all(parent).ok();
    }
    
    fs::write(&htpasswd_path, htpasswd_content).expect("Failed to write htpasswd file");
    
    // Test login with wrong password
    let login_data = json!({
        "username": "testuser",
        "password": "wrongpassword"
    });
    
    let req = test::TestRequest::post()
        .uri("/api/auth/login")
        .set_json(&login_data)
        .to_request();
    
    let resp = test::call_service(&app, req).await;
    
    // Should fail with 401 Unauthorized
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED, "Login should fail with invalid credentials");
    
    // Verify error response
    let json = extract_json(resp).await;
    assert!(json["message"].is_string());
    let error_msg = json["message"].as_str().unwrap_or("");
    assert!(error_msg.to_lowercase().contains("invalid") || error_msg.to_lowercase().contains("password"));
    
    // Test login with non-existent user
    let login_data = json!({
        "username": "nonexistentuser",
        "password": "anypassword"
    });
    
    let req = test::TestRequest::post()
        .uri("/api/auth/login")
        .set_json(&login_data)
        .to_request();
    
    let resp = test::call_service(&app, req).await;
    
    // Should also fail
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
    
    // Clean up
    let _ = fs::remove_file(&htpasswd_path);
    
    log::info!("✅ Login with invalid credentials properly fails");
}

/// Test session-based access to protected endpoints
#[tokio::test]
#[serial]
async fn test_session_based_access_to_protected_endpoints() {
    let (app, test_config) = create_inline_test_service!();
    
    // Create a test htpasswd file
    let htpasswd_path = test_config.config.htpasswd_path.clone();
    let test_password = "testpass";
    let hashed_password = hash(test_password, DEFAULT_COST).expect("Failed to hash password");
    let htpasswd_content = format!("testuser:{}", hashed_password);
    
    // Ensure directory exists
    if let Some(parent) = htpasswd_path.parent() {
        std::fs::create_dir_all(parent).ok();
    }
    
    fs::write(&htpasswd_path, htpasswd_content).expect("Failed to write htpasswd file");
    
    // Step 1: Login to get session cookie
    let login_data = json!({
        "username": "testuser",
        "password": test_password
    });
    
    let req = test::TestRequest::post()
        .uri("/api/auth/login")
        .set_json(&login_data)
        .to_request();
    
    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::OK);
    
    // Extract session cookie
    let cookies: Vec<Cookie> = resp.response().cookies().collect();
    let session_cookie = cookies.iter()
        .find(|cookie| cookie.name() == "id" || cookie.name().contains("session") || cookie.name().contains("ssm"))
        .expect("Should have session cookie after login");
    
    // Step 2: Use session cookie to access protected endpoint
    let req = test::TestRequest::get()
        .uri("/api/user")
        .cookie(session_cookie.clone())
        .to_request();
    
    let resp = test::call_service(&app, req).await;
    
    // Should now have access (may return OK, NOT_FOUND, etc., but not UNAUTHORIZED)
    assert_ne!(resp.status(), StatusCode::UNAUTHORIZED, "Should have access with valid session");
    
    // Step 3: Test multiple endpoints with same session
    let protected_endpoints = vec![
        "/api/host",
        "/api/diff",
    ];
    
    for endpoint in protected_endpoints {
        let req = test::TestRequest::get()
            .uri(endpoint)
            .cookie(session_cookie.clone())
            .to_request();
        
        let resp = test::call_service(&app, req).await;
        assert_ne!(resp.status(), StatusCode::UNAUTHORIZED, 
            "Endpoint {} should be accessible with valid session", endpoint);
    }
    
    // Clean up
    let _ = fs::remove_file(&htpasswd_path);
    
    log::info!("✅ Session-based access to protected endpoints works");
}

/// Test logout invalidates session
#[tokio::test]
#[serial]
async fn test_logout_invalidates_session() {
    let (app, test_config) = create_inline_test_service!();
    
    // Create a test htpasswd file
    let htpasswd_path = test_config.config.htpasswd_path.clone();
    let test_password = "testpass";
    let hashed_password = hash(test_password, DEFAULT_COST).expect("Failed to hash password");
    let htpasswd_content = format!("testuser:{}", hashed_password);
    
    // Ensure directory exists
    if let Some(parent) = htpasswd_path.parent() {
        std::fs::create_dir_all(parent).ok();
    }
    
    fs::write(&htpasswd_path, htpasswd_content).expect("Failed to write htpasswd file");
    
    // Step 1: Login to get session
    let login_data = json!({
        "username": "testuser",
        "password": test_password
    });
    
    let req = test::TestRequest::post()
        .uri("/api/auth/login")
        .set_json(&login_data)
        .to_request();
    
    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::OK);
    
    let cookies: Vec<Cookie> = resp.response().cookies().collect();
    let session_cookie = cookies.iter()
        .find(|cookie| cookie.name() == "id" || cookie.name().contains("session") || cookie.name().contains("ssm"))
        .expect("Should have session cookie after login");
    
    // Step 2: Verify session works
    let req = test::TestRequest::get()
        .uri("/api/user")
        .cookie(session_cookie.clone())
        .to_request();
    
    let resp = test::call_service(&app, req).await;
    assert_ne!(resp.status(), StatusCode::UNAUTHORIZED);
    
    // Step 3: Logout
    let req = test::TestRequest::post()
        .uri("/api/auth/logout")
        .cookie(session_cookie.clone())
        .to_request();
    
    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::OK, "Logout should succeed");
    
    // Verify logout response
    let json = extract_json(resp).await;
    assert_eq!(json["success"], true);
    
    // Step 4: Try to use old session after logout
    let req = test::TestRequest::get()
        .uri("/api/user")
        .cookie(session_cookie.clone())
        .to_request();
    
    let resp = test::call_service(&app, req).await;
    
    // Should now be unauthorized
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED, "Session should be invalid after logout");
    
    // Clean up
    let _ = fs::remove_file(&htpasswd_path);
    
    log::info!("✅ Logout properly invalidates session");
}

/// Test auth status endpoint
#[tokio::test]
#[serial]
async fn test_auth_status_endpoint() {
    let (app, test_config) = create_inline_test_service!();
    
    // Test status without authentication
    let req = test::TestRequest::get()
        .uri("/api/auth/status")
        .to_request();
    
    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::OK, "Auth status should work without authentication");
    
    let json = extract_json(resp).await;
    assert_eq!(json["success"], true);
    assert_eq!(json["data"]["logged_in"], false);
    assert!(json["data"]["username"].is_null());
    
    // Create a test htpasswd file and login
    let htpasswd_path = test_config.config.htpasswd_path.clone();
    let test_password = "testpass";
    let hashed_password = hash(test_password, DEFAULT_COST).expect("Failed to hash password");
    let htpasswd_content = format!("testuser:{}", hashed_password);
    
    // Ensure directory exists
    if let Some(parent) = htpasswd_path.parent() {
        std::fs::create_dir_all(parent).ok();
    }
    
    fs::write(&htpasswd_path, htpasswd_content).expect("Failed to write htpasswd file");
    
    // Login
    let login_data = json!({
        "username": "testuser",
        "password": test_password
    });
    
    let req = test::TestRequest::post()
        .uri("/api/auth/login")
        .set_json(&login_data)
        .to_request();
    
    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::OK);
    
    let cookies: Vec<Cookie> = resp.response().cookies().collect();
    let session_cookie = cookies.iter()
        .find(|cookie| cookie.name() == "id" || cookie.name().contains("session") || cookie.name().contains("ssm"))
        .expect("Should have session cookie after login");
    
    // Test status with authentication
    let req = test::TestRequest::get()
        .uri("/api/auth/status")
        .cookie(session_cookie.clone())
        .to_request();
    
    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::OK);
    
    let json = extract_json(resp).await;
    assert_eq!(json["success"], true);
    assert_eq!(json["data"]["logged_in"], true);
    assert_eq!(json["data"]["username"], "testuser");
    
    // Clean up
    let _ = fs::remove_file(&htpasswd_path);
    
    log::info!("✅ Auth status endpoint works correctly");
}

/// Test session cookie security properties
#[tokio::test]
#[serial]
async fn test_session_cookie_security() {
    let (app, test_config) = create_inline_test_service!();
    
    // Create a test htpasswd file
    let htpasswd_path = test_config.config.htpasswd_path.clone();
    let test_password = "testpass";
    let hashed_password = hash(test_password, DEFAULT_COST).expect("Failed to hash password");
    let htpasswd_content = format!("testuser:{}", hashed_password);
    
    // Ensure directory exists
    if let Some(parent) = htpasswd_path.parent() {
        std::fs::create_dir_all(parent).ok();
    }
    
    fs::write(&htpasswd_path, htpasswd_content).expect("Failed to write htpasswd file");
    
    // Login to get session cookie
    let login_data = json!({
        "username": "testuser",
        "password": test_password
    });
    
    let req = test::TestRequest::post()
        .uri("/api/auth/login")
        .set_json(&login_data)
        .to_request();
    
    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::OK);
    
    // Check session cookie properties
    let cookies: Vec<Cookie> = resp.response().cookies().collect();
    let session_cookie = cookies.iter()
        .find(|cookie| cookie.name() == "id" || cookie.name().contains("session") || cookie.name().contains("ssm"))
        .expect("Should have session cookie after login");
    
    // Verify cookie security properties
    assert!(session_cookie.http_only().unwrap_or(false), "Session cookie should be HTTP-only");
    
    // In test environment, secure flag might be false, but we should verify the behavior
    // Secure flag should be true in production
    log::info!("Session cookie secure flag: {:?}", session_cookie.secure());
    log::info!("Session cookie http_only flag: {:?}", session_cookie.http_only());
    log::info!("Session cookie same_site: {:?}", session_cookie.same_site());
    
    // Verify cookie name and value are properly set
    assert!(!session_cookie.value().is_empty(), "Session cookie should have non-empty value");
    assert!(session_cookie.name().len() > 0, "Session cookie should have a name");
    
    // Clean up
    let _ = fs::remove_file(&htpasswd_path);
    
    log::info!("✅ Session cookie has proper security properties");
}

/// Test invalid session handling
#[tokio::test]
#[serial]
async fn test_invalid_session_handling() {
    let (app, _test_config) = create_inline_test_service!();
    
    // Test with completely invalid session cookie
    let invalid_cookie = Cookie::build("ssm_session", "invalid_session_data_12345").finish();
    
    let req = test::TestRequest::get()
        .uri("/api/user")
        .cookie(invalid_cookie)
        .to_request();
    
    let resp = test::call_service(&app, req).await;
    
    // Should return unauthorized for invalid session
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED, "Invalid session should be rejected");
    
    // Test with empty session cookie
    let empty_cookie = Cookie::build("ssm_session", "").finish();
    
    let req = test::TestRequest::get()
        .uri("/api/user")
        .cookie(empty_cookie)
        .to_request();
    
    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
    
    // Test with malformed session cookie
    let malformed_cookie = Cookie::build("ssm_session", "malformed{session}data").finish();
    
    let req = test::TestRequest::get()
        .uri("/api/user")
        .cookie(malformed_cookie)
        .to_request();
    
    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
    
    log::info!("✅ Invalid sessions are properly rejected");
}

/// Test bcrypt password verification including Apache htpasswd formats
#[tokio::test]
#[serial]
async fn test_bcrypt_password_verification() {
    let (app, test_config) = create_inline_test_service!();
    
    // Test with $2y$ format (Apache htpasswd bcrypt format)
    let htpasswd_path = test_config.config.htpasswd_path.clone();
    
    // Create test password with $2y$ format (simulating Apache htpasswd -cB)
    let test_password = "testpassword123";
    // This simulates what Apache htpasswd would generate
    let apache_hash = hash(test_password, DEFAULT_COST).expect("Failed to hash password");
    // Convert $2b$ to $2y$ to simulate Apache format
    let apache_hash = apache_hash.replace("$2b$", "$2y$");
    let htpasswd_content = format!("testuser:{}", apache_hash);
    
    // Ensure directory exists
    if let Some(parent) = htpasswd_path.parent() {
        std::fs::create_dir_all(parent).ok();
    }
    
    fs::write(&htpasswd_path, htpasswd_content).expect("Failed to write htpasswd file");
    
    // Test login with $2y$ format
    let login_data = json!({
        "username": "testuser",
        "password": test_password
    });
    
    let req = test::TestRequest::post()
        .uri("/api/auth/login")
        .set_json(&login_data)
        .to_request();
    
    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::OK, "Should handle $2y$ bcrypt format");
    
    // Test with $2b$ format  
    let bcrypt_hash = hash(test_password, DEFAULT_COST).expect("Failed to hash password");
    let htpasswd_content = format!("testuser:{}", bcrypt_hash);
    fs::write(&htpasswd_path, htpasswd_content).expect("Failed to write htpasswd file");
    
    let req = test::TestRequest::post()
        .uri("/api/auth/login")
        .set_json(&login_data)
        .to_request();
    
    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::OK, "Should handle $2b$ bcrypt format");
    
    // Clean up
    let _ = fs::remove_file(&htpasswd_path);
    
    log::info!("✅ Bcrypt password verification works with both $2y$ and $2b$ formats");
}