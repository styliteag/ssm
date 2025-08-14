/// HTTP Authentication Endpoint Tests
/// 
/// Tests for /api/auth/* endpoints with complete isolation

use actix_web::http::StatusCode;
use serde_json::json;

use crate::tests::http_test_utils::HttpTestContext;

#[actix_web::test]
async fn test_login_success() {
    let mut ctx = HttpTestContext::new().await;
    
    let resp = ctx.post_json("/api/auth/login", json!({
        "username": "testuser",
        "password": "testpass"
    })).await;
    
    assert_eq!(resp.status(), StatusCode::OK);
    
    let json = HttpTestContext::extract_json(resp).await;
    assert_eq!(json["status"], "success");
    assert_eq!(json["data"]["username"], "testuser");
    assert_eq!(json["data"]["message"], "Login successful");
    
    // Should have session cookie
    assert!(ctx.session_cookie.is_some());
}

#[actix_web::test]
async fn test_login_invalid_credentials() {
    let ctx = HttpTestContext::new().await;
    
    let resp = ctx.post_json("/api/auth/login", json!({
        "username": "testuser",
        "password": "wrongpassword"
    })).await;
    
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
    
    let json = HttpTestContext::extract_json(resp).await;
    assert_eq!(json["status"], "error");
    assert_eq!(json["error"]["code"], "UNAUTHORIZED");
}

#[actix_web::test]
async fn test_login_missing_username() {
    let ctx = HttpTestContext::new().await;
    
    let resp = ctx.post_json("/api/auth/login", json!({
        "password": "testpass"
    })).await;
    
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[actix_web::test]
async fn test_login_missing_password() {
    let ctx = HttpTestContext::new().await;
    
    let resp = ctx.post_json("/api/auth/login", json!({
        "username": "testuser"
    })).await;
    
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[actix_web::test]
async fn test_logout() {
    let mut ctx = HttpTestContext::new().await;
    
    // First login
    ctx.login("testuser", "testpass").await.unwrap();
    
    // Then logout
    let resp = ctx.post_json("/api/auth/logout", json!({})).await;
    
    assert_eq!(resp.status(), StatusCode::OK);
    
    let json = HttpTestContext::extract_json(resp).await;
    assert_eq!(json["status"], "success");
    assert_eq!(json["message"], "Logged out successfully");
}

#[actix_web::test]
async fn test_auth_status_logged_in() {
    let mut ctx = HttpTestContext::new().await;
    
    // Login first
    ctx.login("testuser", "testpass").await.unwrap();
    
    // Check status
    let resp = ctx.get("/api/auth/status").await;
    
    assert_eq!(resp.status(), StatusCode::OK);
    
    let json = HttpTestContext::extract_json(resp).await;
    assert_eq!(json["status"], "success");
    assert_eq!(json["data"]["logged_in"], true);
    assert_eq!(json["data"]["username"], "testuser");
}

#[actix_web::test]
async fn test_auth_status_not_logged_in() {
    let ctx = HttpTestContext::new().await;
    
    // Check status without login
    let resp = ctx.get("/api/auth/status").await;
    
    assert_eq!(resp.status(), StatusCode::OK);
    
    let json = HttpTestContext::extract_json(resp).await;
    assert_eq!(json["status"], "success");
    assert_eq!(json["data"]["logged_in"], false);
    assert_eq!(json["data"]["username"], serde_json::Value::Null);
}

#[actix_web::test]
async fn test_protected_endpoint_without_auth() {
    let ctx = HttpTestContext::new().await;
    
    // Try to access protected endpoint without login
    let resp = ctx.get("/api/user").await;
    
    // Should redirect to login or return 401
    assert!(
        resp.status() == StatusCode::UNAUTHORIZED || 
        resp.status() == StatusCode::SEE_OTHER,
        "Protected endpoint should require authentication"
    );
}

#[actix_web::test]
async fn test_protected_endpoint_with_auth() {
    let mut ctx = HttpTestContext::new().await;
    
    // Login first
    ctx.login("testuser", "testpass").await.unwrap();
    
    // Access protected endpoint
    let resp = ctx.get("/api/user").await;
    
    assert_eq!(resp.status(), StatusCode::OK);
    
    let json = HttpTestContext::extract_json(resp).await;
    assert_eq!(json["status"], "success");
}

#[actix_web::test]
async fn test_session_persistence() {
    let mut ctx = HttpTestContext::new().await;
    
    // Login
    ctx.login("testuser", "testpass").await.unwrap();
    
    // Make multiple authenticated requests
    for _ in 0..3 {
        let resp = ctx.get("/api/auth/status").await;
        assert_eq!(resp.status(), StatusCode::OK);
        
        let json = HttpTestContext::extract_json(resp).await;
        assert_eq!(json["data"]["logged_in"], true);
        assert_eq!(json["data"]["username"], "testuser");
    }
}

#[actix_web::test]
async fn test_concurrent_sessions_isolated() {
    // Create two separate contexts (simulating two different users)
    let mut ctx1 = HttpTestContext::new().await;
    let mut ctx2 = HttpTestContext::new().await;
    
    // Login as different users
    ctx1.login("testuser", "testpass").await.unwrap();
    ctx2.login("admin", "testpass").await.unwrap();
    
    // Check both sessions are independent
    let resp1 = ctx1.get("/api/auth/status").await;
    let json1 = HttpTestContext::extract_json(resp1).await;
    assert_eq!(json1["data"]["username"], "testuser");
    
    let resp2 = ctx2.get("/api/auth/status").await;
    let json2 = HttpTestContext::extract_json(resp2).await;
    assert_eq!(json2["data"]["username"], "admin");
    
    // Logout ctx1
    ctx1.post_json("/api/auth/logout", json!({})).await;
    
    // ctx2 should still be logged in
    let resp2_after = ctx2.get("/api/auth/status").await;
    let json2_after = HttpTestContext::extract_json(resp2_after).await;
    assert_eq!(json2_after["data"]["logged_in"], true);
    assert_eq!(json2_after["data"]["username"], "admin");
}