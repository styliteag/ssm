/// HTTP Host Management Tests
/// 
/// Tests for host-related API endpoints including getting all hosts
/// and error handling for nonexistent hosts.

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
async fn test_get_all_hosts() {
    let (app, _test_config) = create_inline_test_service!();
    
    let req = test::TestRequest::get()
        .uri("/api/host")
        .to_request();
    
    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::OK);
    
    let json = extract_json(resp).await;
    assert_eq!(json["success"], true);
    assert!(json["data"].is_array());
    
    log::info!("✅ Get all hosts test passed");
}

#[tokio::test]
#[serial]
async fn test_get_nonexistent_host() {
    let (app, _test_config) = create_inline_test_service!();
    
    let req = test::TestRequest::get()
        .uri("/api/host/nonexistenthost")
        .to_request();
    
    let resp = test::call_service(&app, req).await;
    let _json = assert_not_found_response(resp).await;
    
    log::info!("✅ Get nonexistent host test passed");
}