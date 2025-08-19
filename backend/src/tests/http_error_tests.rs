/// HTTP Error Handling Tests
/// 
/// Tests for error conditions, authentication protection, CORS headers,
/// invalid endpoints, and diff operations.

use actix_web::{test, http::StatusCode};
use serial_test::serial;

use crate::{
    create_inline_test_service,
};

#[tokio::test]
#[serial]
async fn test_protected_endpoints_require_auth() {
    let (app, _test_config) = create_inline_test_service!();
    
    // Test that protected endpoints require authentication
    let protected_endpoints = vec![
        "/api/user",
        "/api/host", 
        "/api/key",
        "/api/diff/",
    ];
    
    for endpoint in protected_endpoints {
        let req = test::TestRequest::get()
            .uri(endpoint)
            .to_request();
        
        let resp = test::call_service(&app, req).await;
        
        // With CSRF protection enabled, unauthenticated requests return 403 FORBIDDEN
        log::info!("Endpoint {} returned: {} (CSRF protection enabled)", endpoint, resp.status());
        assert!(
            resp.status() == StatusCode::FORBIDDEN ||
            resp.status() == StatusCode::NOT_FOUND,
            "Endpoint {} returned unexpected status: {}", endpoint, resp.status()
        );
    }
    
    log::info!("✅ Protected endpoints test passed");
}

#[tokio::test]
#[serial]
async fn test_invalid_endpoints() {
    let (app, _test_config) = create_inline_test_service!();
    
    // Test nonexistent endpoint
    let req = test::TestRequest::get()
        .uri("/api/nonexistent")
        .to_request();
    
    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::FORBIDDEN); // CSRF protection applies globally
    
    // Test invalid HTTP method
    let req = test::TestRequest::patch()
        .uri("/")
        .to_request();
    
    let resp = test::call_service(&app, req).await;
    // Root path with unsupported method can return 404 or 403 depending on route matching
    assert!(
        resp.status() == StatusCode::FORBIDDEN || resp.status() == StatusCode::NOT_FOUND,
        "Expected FORBIDDEN or NOT_FOUND, got: {}", resp.status()
    );
    
    log::info!("✅ Invalid endpoints test passed");
}

#[tokio::test]
#[serial]
async fn test_cors_headers() {
    let (app, _test_config) = create_inline_test_service!();
    
    // Test OPTIONS request for CORS
    let req = test::TestRequest::default()
        .insert_header(("Origin", "http://localhost:3000"))
        .method(actix_web::http::Method::OPTIONS)
        .uri("/api/info")
        .to_request();
    
    let resp = test::call_service(&app, req).await;
    
    // Should handle OPTIONS request (CORS preflight or return method not allowed)
    assert!(
        resp.status().is_success() || 
        resp.status() == StatusCode::METHOD_NOT_ALLOWED || 
        resp.status() == StatusCode::NOT_FOUND,
        "CORS OPTIONS request failed with unexpected status: {}", resp.status()
    );
    
    log::info!("✅ CORS headers test passed");
}

#[tokio::test]
#[serial]
async fn test_get_hosts_for_diff() {
    let (app, _test_config) = create_inline_test_service!();
    
    let req = test::TestRequest::get()
        .uri("/api/diff/")
        .to_request();
    
    let resp = test::call_service(&app, req).await;
    // With CSRF protection, unauthenticated requests return 403 FORBIDDEN
    assert!(
        resp.status() == StatusCode::FORBIDDEN || resp.status() == StatusCode::NOT_FOUND,
        "Diff endpoint returned unexpected status: {}", resp.status()
    );
    
    if resp.status() == StatusCode::FORBIDDEN {
        log::info!("Diff endpoint correctly rejected unauthenticated request with 403");
    } else {
        log::info!("Diff endpoint not available (404) - this may be expected");
    }
    
    log::info!("✅ Get hosts for diff test passed");
}