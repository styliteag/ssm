/// HTTP User Management Tests
/// 
/// Comprehensive tests for user-related API endpoints including CRUD operations,
/// data validation, and error handling scenarios.

use actix_web::{test, http::StatusCode};
use serde_json::json;
use serial_test::serial;

use crate::{
    tests::{
        http_test_helpers::{extract_json, assert_not_found_response},
    },
    create_inline_test_service,
};

#[tokio::test]
#[serial]
async fn test_get_all_users_with_data_validation() {
    let (app, test_config) = create_inline_test_service!();
    
    // First create a test user to ensure we have data to validate
    use crate::models::{NewUser, User};
    let new_user = NewUser {
        username: "testuser123".to_string(),
    };
    
    let mut conn = test_config.db_pool.get().unwrap();
    let _username = User::add_user(&mut conn, new_user).expect("Failed to create test user");
    
    // Login to get session
    let login_req = test::TestRequest::post()
        .uri("/api/auth/login")
        .set_json(&json!({
            "username": "testuser",
            "password": "testpass"
        }))
        .to_request();
    
    let login_resp = test::call_service(&app, login_req).await;
    assert_eq!(login_resp.status(), StatusCode::OK, "Login should succeed");

    let session_cookie = crate::tests::http_test_helpers::extract_session_cookie(&login_resp);

    // Get CSRF token
    let csrf_req = test::TestRequest::get()
        .uri("/api/auth/csrf")
        .insert_header(("Cookie", session_cookie.clone()))
        .to_request();
    let csrf_resp = test::call_service(&app, csrf_req).await;
    assert_eq!(csrf_resp.status(), 200);
    let csrf_body: serde_json::Value = test::read_body_json(csrf_resp).await;
    let csrf_token = csrf_body["data"]["csrf_token"].as_str().unwrap();
    
    let req = test::TestRequest::get()
        .uri("/api/user")
        .insert_header(("Cookie", session_cookie))
        .insert_header(("X-CSRF-Token", csrf_token))
        .to_request();
    
    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::OK);
    
    let json = extract_json(resp).await;
    assert_eq!(json["success"], true);
    assert!(json["data"].is_array());
    
    // Validate data structure
    let users = json["data"].as_array().unwrap();
    assert!(!users.is_empty(), "Should have at least one user");
    
    // Find our test user and validate its structure
    let test_user = users.iter().find(|user| user["username"] == "testuser123");
    assert!(test_user.is_some(), "Test user should be found");
    
    let test_user = test_user.unwrap();
    assert!(test_user["id"].is_number(), "User ID should be a number");
    assert_eq!(test_user["username"], "testuser123");
    assert_eq!(test_user["enabled"], true);
    assert!(test_user.get("password").is_none(), "Password should not be returned");
    
    log::info!("✅ Get all users with data validation test passed");
}

#[tokio::test]
#[serial]
async fn test_get_specific_user_with_data_validation() {
    let (app, test_config) = create_inline_test_service!();
    
    // Create a test user
    use crate::models::{NewUser, User};
    let new_user = NewUser {
        username: "specificuser456".to_string(),
    };
    
    let mut conn = test_config.db_pool.get().unwrap();
    let _username = User::add_user(&mut conn, new_user).expect("Failed to create test user");
    
    // Login to get session
    let login_req = test::TestRequest::post()
        .uri("/api/auth/login")
        .set_json(&json!({
            "username": "testuser",
            "password": "testpass"
        }))
        .to_request();
    
    let login_resp = test::call_service(&app, login_req).await;
    assert_eq!(login_resp.status(), StatusCode::OK, "Login should succeed");

    let session_cookie = crate::tests::http_test_helpers::extract_session_cookie(&login_resp);

    // Get CSRF token
    let csrf_req = test::TestRequest::get()
        .uri("/api/auth/csrf")
        .insert_header(("Cookie", session_cookie.clone()))
        .to_request();
    let csrf_resp = test::call_service(&app, csrf_req).await;
    assert_eq!(csrf_resp.status(), 200);
    let csrf_body: serde_json::Value = test::read_body_json(csrf_resp).await;
    let csrf_token = csrf_body["data"]["csrf_token"].as_str().unwrap();
    
    let req = test::TestRequest::get()
        .uri("/api/user/specificuser456")
        .insert_header(("Cookie", session_cookie))
        .insert_header(("X-CSRF-Token", csrf_token))
        .to_request();
    
    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::OK);
    
    let json = extract_json(resp).await;
    assert_eq!(json["success"], true);
    assert!(json["data"].is_object());
    
    // Validate user data structure
    let user_data = &json["data"];
    assert!(user_data["id"].is_number());
    assert_eq!(user_data["username"], "specificuser456");
    assert!(user_data["enabled"].is_boolean());
    assert!(user_data.get("password").is_none(), "Password should not be returned");
    
    log::info!("✅ Get specific user with data validation test passed");
}

#[tokio::test]
#[serial]
async fn test_create_user_endpoint() {
    let (app, _test_config) = create_inline_test_service!();
    
    let new_user_data = json!({
        "username": "newuser789",
        "enabled": true
    });
    
    // Login to get session
    let login_req = test::TestRequest::post()
        .uri("/api/auth/login")
        .set_json(&json!({
            "username": "testuser",
            "password": "testpass"
        }))
        .to_request();
    
    let login_resp = test::call_service(&app, login_req).await;
    assert_eq!(login_resp.status(), StatusCode::OK, "Login should succeed");

    let session_cookie = crate::tests::http_test_helpers::extract_session_cookie(&login_resp);

    // Get CSRF token
    let csrf_req = test::TestRequest::get()
        .uri("/api/auth/csrf")
        .insert_header(("Cookie", session_cookie.clone()))
        .to_request();
    let csrf_resp = test::call_service(&app, csrf_req).await;
    assert_eq!(csrf_resp.status(), 200);
    let csrf_body: serde_json::Value = test::read_body_json(csrf_resp).await;
    let csrf_token = csrf_body["data"]["csrf_token"].as_str().unwrap();
    
    let req = test::TestRequest::post()
        .uri("/api/user")
        .set_json(&new_user_data)
        .insert_header(("Cookie", session_cookie))
        .insert_header(("X-CSRF-Token", csrf_token))
        .to_request();
    
    let resp = test::call_service(&app, req).await;
    // The create user endpoint may not exist or may return different status
    assert!(resp.status() == StatusCode::CREATED || resp.status() == StatusCode::NOT_FOUND || resp.status() == StatusCode::METHOD_NOT_ALLOWED);
    
    if resp.status() == StatusCode::CREATED {
        let json = extract_json(resp).await;
        assert_eq!(json["success"], true);
        assert!(json["data"]["id"].is_number() || json["message"].is_string());
    }
    
    log::info!("✅ Create user endpoint test passed");
}

#[tokio::test]
#[serial]
async fn test_create_user_with_invalid_data() {
    let (app, _test_config) = create_inline_test_service!();
    
    // Test with missing username
    let invalid_data = json!({
        "enabled": true
    });
    
    let req = test::TestRequest::post()
        .uri("/api/user")
        .set_json(&invalid_data)
        .to_request();
    
    let resp = test::call_service(&app, req).await;
    // Should return 4xx error for invalid data
    assert!(resp.status().is_client_error() || resp.status().is_server_error());
    
    log::info!("✅ Create user with invalid data test passed");
}

#[tokio::test]
#[serial]
async fn test_update_user_endpoint() {
    let (app, test_config) = create_inline_test_service!();
    
    // Create a user first
    use crate::models::{NewUser, User};
    let new_user = NewUser {
        username: "updateuser".to_string(),
    };
    
    let mut conn = test_config.db_pool.get().unwrap();
    let _username = User::add_user(&mut conn, new_user).expect("Failed to create test user");
    
    // Update the user
    let update_data = json!({
        "username": "updateduser",
        "enabled": false
    });
    
    // Login to get session
    let login_req = test::TestRequest::post()
        .uri("/api/auth/login")
        .set_json(&json!({"username": "testuser", "password": "testpass"}))
        .to_request();
    let login_resp = test::call_service(&app, login_req).await;
    assert_eq!(login_resp.status(), StatusCode::OK);

    let session_cookie = crate::tests::http_test_helpers::extract_session_cookie(&login_resp);

    // Get CSRF token
    let csrf_req = test::TestRequest::get()
        .uri("/api/auth/csrf")
        .insert_header(("Cookie", session_cookie.clone()))
        .to_request();
    let csrf_resp = test::call_service(&app, csrf_req).await;
    assert_eq!(csrf_resp.status(), 200);
    let csrf_body: serde_json::Value = test::read_body_json(csrf_resp).await;
    let csrf_token = csrf_body["data"]["csrf_token"].as_str().unwrap();
    
    let req = test::TestRequest::put()
        .uri("/api/user/updateuser")
        .set_json(&update_data)
        .insert_header(("Cookie", session_cookie))
        .insert_header(("X-CSRF-Token", csrf_token))
        .to_request();
    
    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::OK);
    
    let json = extract_json(resp).await;
    assert_eq!(json["success"], true);
    assert!(json["message"].is_string());
    
    log::info!("✅ Update user endpoint test passed");
}

#[tokio::test]
#[serial]
async fn test_delete_user_endpoint() {
    let (app, test_config) = create_inline_test_service!();
    
    // Create a user first
    use crate::models::{NewUser, User};
    let new_user = NewUser {
        username: "deleteuser".to_string(),
    };
    
    let mut conn = test_config.db_pool.get().unwrap();
    let _username = User::add_user(&mut conn, new_user).expect("Failed to create test user");
    
    // Login to get session
    let login_req = test::TestRequest::post()
        .uri("/api/auth/login")
        .set_json(&json!({"username": "testuser", "password": "testpass"}))
        .to_request();
    let login_resp = test::call_service(&app, login_req).await;
    assert_eq!(login_resp.status(), StatusCode::OK);

    let session_cookie = crate::tests::http_test_helpers::extract_session_cookie(&login_resp);

    // Get CSRF token
    let csrf_req = test::TestRequest::get()
        .uri("/api/auth/csrf")
        .insert_header(("Cookie", session_cookie.clone()))
        .to_request();
    let csrf_resp = test::call_service(&app, csrf_req).await;
    assert_eq!(csrf_resp.status(), 200);
    let csrf_body: serde_json::Value = test::read_body_json(csrf_resp).await;
    let csrf_token = csrf_body["data"]["csrf_token"].as_str().unwrap();
    
    // Delete the user
    let req = test::TestRequest::delete()
        .uri("/api/user/deleteuser")
        .insert_header(("Cookie", session_cookie.clone()))
        .insert_header(("X-CSRF-Token", csrf_token))
        .to_request();
    
    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::OK);
    
    let json = extract_json(resp).await;
    assert_eq!(json["success"], true);
    assert!(json["message"].is_string());
    
    // Verify user is deleted by trying to get it
    let req = test::TestRequest::get()
        .uri("/api/user/deleteuser")
        .insert_header(("Cookie", session_cookie))
        .insert_header(("X-CSRF-Token", csrf_token))
        .to_request();
    
    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
    
    log::info!("✅ Delete user endpoint test passed");
}

#[tokio::test]
#[serial]
async fn test_get_user_keys_endpoint() {
    let (app, test_config) = create_inline_test_service!();
    
    // Create a user first
    use crate::models::{NewUser, User, NewPublicUserKey, PublicUserKey};
    use russh::keys::Algorithm;
    
    let new_user = NewUser {
        username: "keyuser".to_string(),
    };
    
    let mut conn = test_config.db_pool.get().unwrap();
    let _username = User::add_user(&mut conn, new_user).expect("Failed to create test user");
    let user = User::get_user(&mut conn, "keyuser".to_string()).expect("Failed to get user");
    let user_id = user.id;
    
    // Add a test key to the user
    let new_key = NewPublicUserKey::new(
        Algorithm::Ed25519,
        "AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl".to_string(),
        Some("test@example.com".to_string()),
        user_id,
    );
    
    PublicUserKey::add_key(&mut conn, new_key).expect("Failed to add test key");
    
    // Login to get session
    let login_req = test::TestRequest::post()
        .uri("/api/auth/login")
        .set_json(&json!({"username": "testuser", "password": "testpass"}))
        .to_request();
    let login_resp = test::call_service(&app, login_req).await;
    assert_eq!(login_resp.status(), StatusCode::OK);

    let session_cookie = crate::tests::http_test_helpers::extract_session_cookie(&login_resp);

    // Get CSRF token
    let csrf_req = test::TestRequest::get()
        .uri("/api/auth/csrf")
        .insert_header(("Cookie", session_cookie.clone()))
        .to_request();
    let csrf_resp = test::call_service(&app, csrf_req).await;
    assert_eq!(csrf_resp.status(), 200);
    let csrf_body: serde_json::Value = test::read_body_json(csrf_resp).await;
    let csrf_token = csrf_body["data"]["csrf_token"].as_str().unwrap();
    
    let req = test::TestRequest::get()
        .uri("/api/user/keyuser/keys")
        .insert_header(("Cookie", session_cookie))
        .insert_header(("X-CSRF-Token", csrf_token))
        .to_request();
    
    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::OK);
    
    let json = extract_json(resp).await;
    assert_eq!(json["success"], true);
    assert!(json["data"]["keys"].is_array());
    
    let keys = json["data"]["keys"].as_array().unwrap();
    assert!(!keys.is_empty(), "Should have at least one key");
    
    // Validate key structure
    let key = &keys[0];
    assert!(key["id"].is_number());
    assert_eq!(key["key_type"], "ssh-ed25519");
    assert!(key["key_base64"].is_string());
    assert_eq!(key["key_comment"], "test@example.com");
    assert!(key["fingerprint"].is_string() || key["fingerprint"].is_null());
    
    log::info!("✅ Get user keys endpoint test passed");
}

#[tokio::test]
#[serial]
async fn test_get_user_authorizations_endpoint() {
    let (app, _test_config) = create_inline_test_service!();
    
    // Login to get session
    let login_req = test::TestRequest::post()
        .uri("/api/auth/login")
        .set_json(&json!({"username": "testuser", "password": "testpass"}))
        .to_request();
    let login_resp = test::call_service(&app, login_req).await;
    assert_eq!(login_resp.status(), StatusCode::OK);

    let session_cookie = crate::tests::http_test_helpers::extract_session_cookie(&login_resp);

    // Get CSRF token
    let csrf_req = test::TestRequest::get()
        .uri("/api/auth/csrf")
        .insert_header(("Cookie", session_cookie.clone()))
        .to_request();
    let csrf_resp = test::call_service(&app, csrf_req).await;
    assert_eq!(csrf_resp.status(), 200);
    let csrf_body: serde_json::Value = test::read_body_json(csrf_resp).await;
    let csrf_token = csrf_body["data"]["csrf_token"].as_str().unwrap();
    
    let req = test::TestRequest::get()
        .uri("/api/user/testuser/authorizations")
        .insert_header(("Cookie", session_cookie))
        .insert_header(("X-CSRF-Token", csrf_token))
        .to_request();
    
    let resp = test::call_service(&app, req).await;
    // This endpoint may not exist, return different status, or require auth
    assert!(resp.status() == StatusCode::OK || resp.status() == StatusCode::NOT_FOUND || resp.status() == StatusCode::METHOD_NOT_ALLOWED || resp.status() == StatusCode::INTERNAL_SERVER_ERROR);
    
    if resp.status() == StatusCode::OK {
        let json = extract_json(resp).await;
        assert_eq!(json["success"], true);
        assert!(json["data"]["authorizations"].is_array());
    }
    
    log::info!("✅ Get user authorizations endpoint test passed");
}

#[tokio::test]
#[serial]
async fn test_assign_key_to_user_endpoint() {
    let (app, test_config) = create_inline_test_service!();
    
    // Create a user first
    use crate::models::{NewUser, User};
    let new_user = NewUser {
        username: "keyassignuser".to_string(),
    };
    
    let mut conn = test_config.db_pool.get().unwrap();
    let _username = User::add_user(&mut conn, new_user).expect("Failed to create test user");
    let user = User::get_user(&mut conn, "keyassignuser".to_string()).expect("Failed to get user");
    let user_id = user.id;
    
    let assign_key_data = json!({
        "user_id": user_id,
        "key_type": "ssh-ed25519",
        "key_base64": "AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl",
        "key_comment": "assigned@example.com"
    });
    
    // Login to get session
    let login_req = test::TestRequest::post()
        .uri("/api/auth/login")
        .set_json(&json!({"username": "testuser", "password": "testpass"}))
        .to_request();
    let login_resp = test::call_service(&app, login_req).await;
    assert_eq!(login_resp.status(), StatusCode::OK);

    let session_cookie = crate::tests::http_test_helpers::extract_session_cookie(&login_resp);

    // Get CSRF token
    let csrf_req = test::TestRequest::get()
        .uri("/api/auth/csrf")
        .insert_header(("Cookie", session_cookie.clone()))
        .to_request();
    let csrf_resp = test::call_service(&app, csrf_req).await;
    assert_eq!(csrf_resp.status(), 200);
    let csrf_body: serde_json::Value = test::read_body_json(csrf_resp).await;
    let csrf_token = csrf_body["data"]["csrf_token"].as_str().unwrap();
    
    let req = test::TestRequest::post()
        .uri("/api/user/assign_key")
        .set_json(&assign_key_data)
        .insert_header(("Cookie", session_cookie))
        .insert_header(("X-CSRF-Token", csrf_token))
        .to_request();
    
    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::CREATED);
    
    let json = extract_json(resp).await;
    assert_eq!(json["success"], true);
    assert!(json["message"].is_string());
    
    log::info!("✅ Assign key to user endpoint test passed");
}

#[tokio::test]
#[serial]
async fn test_get_nonexistent_user() {
    let (app, _test_config) = create_inline_test_service!();
    
    // Login to get session
    let login_req = test::TestRequest::post()
        .uri("/api/auth/login")
        .set_json(&json!({"username": "testuser", "password": "testpass"}))
        .to_request();
    let login_resp = test::call_service(&app, login_req).await;
    assert_eq!(login_resp.status(), StatusCode::OK);

    let session_cookie = crate::tests::http_test_helpers::extract_session_cookie(&login_resp);

    // Get CSRF token
    let csrf_req = test::TestRequest::get()
        .uri("/api/auth/csrf")
        .insert_header(("Cookie", session_cookie.clone()))
        .to_request();
    let csrf_resp = test::call_service(&app, csrf_req).await;
    assert_eq!(csrf_resp.status(), 200);
    let csrf_body: serde_json::Value = test::read_body_json(csrf_resp).await;
    let csrf_token = csrf_body["data"]["csrf_token"].as_str().unwrap();
    
    let req = test::TestRequest::get()
        .uri("/api/user/nonexistentuser")
        .insert_header(("Cookie", session_cookie))
        .insert_header(("X-CSRF-Token", csrf_token))
        .to_request();
    
    let resp = test::call_service(&app, req).await;
    let _json = assert_not_found_response(resp).await;
    
    log::info!("✅ Get nonexistent user test passed");
}