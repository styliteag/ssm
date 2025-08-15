/// HTTP User Management Tests
/// 
/// Tests for user-related API endpoints including getting all users
/// and error handling for nonexistent users.

use actix_web::{test, http::StatusCode};
use serial_test::serial;

use crate::{
    tests::{
        http_test_helpers::{extract_json, assert_not_found_response},
    },
    create_inline_test_service,
};

#[tokio::test]
#[serial]
async fn test_get_all_users() {
    let (app, _test_config) = create_inline_test_service!();
    
    let req = test::TestRequest::get()
        .uri("/api/user")
        .to_request();
    
    let resp = test::call_service(&app, req).await;
    // Note: Authentication middleware is disabled, so this returns 200 OK
    assert_eq!(resp.status(), StatusCode::OK);
    
    let json = extract_json(resp).await;
    assert_eq!(json["success"], true);
    assert!(json["data"].is_array());
    
    log::info!("✅ Get all users test passed");
}

#[tokio::test]
#[serial]
async fn test_get_nonexistent_user() {
    let (app, _test_config) = create_inline_test_service!();
    
    let req = test::TestRequest::get()
        .uri("/api/user/nonexistentuser")
        .to_request();
    
    let resp = test::call_service(&app, req).await;
    let _json = assert_not_found_response(resp).await;
    
    log::info!("✅ Get nonexistent user test passed");
}