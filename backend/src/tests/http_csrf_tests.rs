use actix_web::test;
use serde_json::json;
use serial_test::serial;

use crate::create_inline_test_service;

// Helper function to extract session cookie from response
fn get_session_cookie<B>(resp: &actix_web::dev::ServiceResponse<B>) -> String 
where
    B: actix_web::body::MessageBody,
{
    let cookie_header = resp.headers()
        .get(actix_web::http::header::SET_COOKIE)
        .expect("Set-Cookie header should be present");
    
    let cookie_str = cookie_header.to_str().unwrap();
    if let Some(session_part) = cookie_str.split(';').next() {
        return session_part.to_string();
    }
    panic!("Could not extract session cookie");
}

#[tokio::test]
#[serial]
async fn test_csrf_token_returned_on_login() {
    let (app, _test_config) = create_inline_test_service!();
    
    // Login and check for CSRF token
    let req = test::TestRequest::post()
        .uri("/api/auth/login")
        .set_json(&json!({
            "username": "testuser",
            "password": "testpass"
        }))
        .to_request();
    
    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), 200);
    
    let body: serde_json::Value = test::read_body_json(resp).await;
    assert!(body["success"].as_bool().unwrap());
    assert!(body["data"]["csrf_token"].is_string(), "CSRF token should be returned on login");
    
    let csrf_token = body["data"]["csrf_token"].as_str().unwrap();
    assert!(!csrf_token.is_empty(), "CSRF token should not be empty");
}

#[tokio::test]
#[serial]
async fn test_csrf_token_endpoint() {
    let (app, _test_config) = create_inline_test_service!();
    
    // Authenticate first
    let login_req = test::TestRequest::post()
        .uri("/api/auth/login")
        .set_json(&json!({
            "username": "testuser",
            "password": "testpass"
        }))
        .to_request();
    
    let login_resp = test::call_service(&app, login_req).await;
    assert_eq!(login_resp.status(), 200);
    
    let session_cookie = get_session_cookie(&login_resp);
    
    // Get CSRF token from endpoint
    let req = test::TestRequest::get()
        .uri("/api/auth/csrf")
        .insert_header(("Cookie", session_cookie))
        .to_request();
    
    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), 200);
    
    let body: serde_json::Value = test::read_body_json(resp).await;
    assert!(body["data"]["csrf_token"].is_string(), "CSRF token should be returned");
}

#[tokio::test]
#[serial]
async fn test_post_request_without_csrf_token_fails() {
    let (app, _test_config) = create_inline_test_service!();
    
    // Authenticate first
    let login_req = test::TestRequest::post()
        .uri("/api/auth/login")
        .set_json(&json!({
            "username": "testuser",
            "password": "testpass"
        }))
        .to_request();
    
    let login_resp = test::call_service(&app, login_req).await;
    assert_eq!(login_resp.status(), 200);
    
    let session_cookie = get_session_cookie(&login_resp);
    
    // Try to create a host without CSRF token (should fail)
    let req = test::TestRequest::post()
        .uri("/api/host")
        .insert_header(("Cookie", session_cookie))
        .set_json(&json!({
            "name": "test-host",
            "address": "192.168.1.100",
            "username": "ubuntu",
            "port": 22
        }))
        .to_request();
    
    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), 403, "Request without CSRF token should be forbidden");
}

#[tokio::test]
#[serial]
async fn test_post_request_with_invalid_csrf_token_fails() {
    let (app, _test_config) = create_inline_test_service!();
    
    // Authenticate first
    let login_req = test::TestRequest::post()
        .uri("/api/auth/login")
        .set_json(&json!({
            "username": "testuser",
            "password": "testpass"
        }))
        .to_request();
    
    let login_resp = test::call_service(&app, login_req).await;
    assert_eq!(login_resp.status(), 200);
    
    let session_cookie = get_session_cookie(&login_resp);
    
    // Try to create a host with invalid CSRF token (should fail)
    let req = test::TestRequest::post()
        .uri("/api/host")
        .insert_header(("Cookie", session_cookie))
        .insert_header(("X-CSRF-Token", "invalid-token"))
        .set_json(&json!({
            "name": "test-host",
            "address": "192.168.1.100",
            "username": "ubuntu",
            "port": 22
        }))
        .to_request();
    
    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), 403, "Request with invalid CSRF token should be forbidden");
}

#[tokio::test]
#[serial]
async fn test_post_request_with_valid_csrf_token_succeeds() {
    let (app, _test_config) = create_inline_test_service!();
    
    // Login to get CSRF token
    let login_req = test::TestRequest::post()
        .uri("/api/auth/login")
        .set_json(&json!({
            "username": "testuser",
            "password": "testpass"
        }))
        .to_request();
    
    let login_resp = test::call_service(&app, login_req).await;
    assert_eq!(login_resp.status(), 200);
    
    let session_cookie = get_session_cookie(&login_resp);
    
    // Get CSRF token from the current session
    let csrf_req = test::TestRequest::get()
        .uri("/api/auth/csrf")
        .insert_header(("Cookie", session_cookie.clone()))
        .to_request();
    
    let csrf_resp = test::call_service(&app, csrf_req).await;
    assert_eq!(csrf_resp.status(), 200);
    let csrf_body: serde_json::Value = test::read_body_json(csrf_resp).await;
    let csrf_token = csrf_body["data"]["csrf_token"].as_str().unwrap();
    
    // Try to create a host with valid CSRF token
    let req = test::TestRequest::post()
        .uri("/api/host")
        .insert_header(("Cookie", session_cookie))
        .insert_header(("X-CSRF-Token", csrf_token))
        .set_json(&json!({
            "name": "test-host-csrf",
            "address": "192.168.1.100",
            "username": "ubuntu",
            "port": 22,
            "key_fingerprint": "SHA256:test-fingerprint"
        }))
        .to_request();
    
    let resp = test::call_service(&app, req).await;
    // Note: This might fail for other reasons (like SSH connection), 
    // but it should NOT fail with 403 Forbidden
    assert_ne!(resp.status(), 403, "Request with valid CSRF token should not be forbidden");
}

#[tokio::test]
#[serial]
async fn test_get_requests_now_require_csrf_token() {
    let (app, _test_config) = create_inline_test_service!();
    
    // Authenticate first
    let login_req = test::TestRequest::post()
        .uri("/api/auth/login")
        .set_json(&json!({
            "username": "testuser",
            "password": "testpass"
        }))
        .to_request();
    
    let login_resp = test::call_service(&app, login_req).await;
    assert_eq!(login_resp.status(), 200);
    
    let session_cookie = get_session_cookie(&login_resp);
    
    // GET requests should now be blocked without CSRF token
    let req = test::TestRequest::get()
        .uri("/api/host")
        .insert_header(("Cookie", session_cookie))
        .to_request();
    
    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), 403, "GET requests should now require CSRF token");
}

#[tokio::test]
#[serial]
async fn test_get_requests_work_with_csrf_token() {
    let (app, _test_config) = create_inline_test_service!();
    
    // Login to get CSRF token
    let login_req = test::TestRequest::post()
        .uri("/api/auth/login")
        .set_json(&json!({
            "username": "testuser",
            "password": "testpass"
        }))
        .to_request();
    
    let login_resp = test::call_service(&app, login_req).await;
    assert_eq!(login_resp.status(), 200);
    
    let session_cookie = get_session_cookie(&login_resp);
    
    // Get CSRF token from the current session
    let csrf_req = test::TestRequest::get()
        .uri("/api/auth/csrf")
        .insert_header(("Cookie", session_cookie.clone()))
        .to_request();
    
    let csrf_resp = test::call_service(&app, csrf_req).await;
    assert_eq!(csrf_resp.status(), 200);
    let csrf_body: serde_json::Value = test::read_body_json(csrf_resp).await;
    let csrf_token = csrf_body["data"]["csrf_token"].as_str().unwrap();
    
    // GET requests should work WITH CSRF token
    let req = test::TestRequest::get()
        .uri("/api/host")
        .insert_header(("Cookie", session_cookie))
        .insert_header(("X-CSRF-Token", csrf_token))
        .to_request();
    
    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), 200, "GET requests should work with valid CSRF token");
}

#[tokio::test]
#[serial]
async fn test_auth_endpoints_dont_require_csrf_token() {
    let (app, _test_config) = create_inline_test_service!();
    
    // Login should work without CSRF token (it's an auth endpoint)
    let req = test::TestRequest::post()
        .uri("/api/auth/login")
        .set_json(&json!({
            "username": "testuser",
            "password": "testpass"
        }))
        .to_request();
    
    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), 200, "Auth endpoints should work without CSRF token");
}