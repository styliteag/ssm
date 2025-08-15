/// HTTP Key Management Tests
/// 
/// Tests for SSH key-related API endpoints including retrieving all keys.

use actix_web::{test, http::StatusCode};
use serial_test::serial;

use crate::{
    tests::{
        http_test_helpers::{extract_json},
    },
    create_inline_test_service,
};

#[tokio::test]
#[serial]
async fn test_get_all_keys() {
    let (app, _test_config) = create_inline_test_service!();
    
    let req = test::TestRequest::get()
        .uri("/api/key")
        .to_request();
    
    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::OK);
    
    let json = extract_json(resp).await;
    assert_eq!(json["success"], true);
    assert!(json["data"]["keys"].is_array());
    
    log::info!("✅ Get all keys test passed");
}