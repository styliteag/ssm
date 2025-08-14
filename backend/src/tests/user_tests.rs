use actix_web::{test, web, App, http::StatusCode};
use serde_json::json;

use crate::tests::test_utils::*;
use crate::routes::user;
use crate::api_types::*;
use crate::db::User;

#[tokio::test]
async fn test_get_all_users_empty() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/user").configure(user::config))
    ).await;

    let req = test::TestRequest::get()
        .uri("/user")
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::OK);

    let body: ApiResponse<Vec<user::UserResponse>> = test::read_body_json(resp).await;
    assert!(body.success);
    assert_eq!(body.data.unwrap().len(), 0);
}

#[tokio::test]
async fn test_get_all_users_with_data() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    // Insert test users
    let user1_id = insert_test_user(&test_config.db_pool, "test-user-1").await.unwrap();
    let user2_id = insert_test_user(&test_config.db_pool, "test-user-2").await.unwrap();
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/user").configure(user::config))
    ).await;

    let req = test::TestRequest::get()
        .uri("/user")
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::OK);

    let body: ApiResponse<Vec<user::UserResponse>> = test::read_body_json(resp).await;
    assert!(body.success);
    let users = body.data.unwrap();
    assert_eq!(users.len(), 2);
    assert!(users.iter().any(|u| u.id == user1_id));
    assert!(users.iter().any(|u| u.id == user2_id));
}

#[tokio::test]
async fn test_get_user_by_username_success() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let username = "test-user-get";
    let user_id = insert_test_user(&test_config.db_pool, username).await.unwrap();
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/user").configure(user::config))
    ).await;

    let req = test::TestRequest::get()
        .uri(&format!("/user/{}", username))
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::OK);

    let body: ApiResponse<user::UserResponse> = test::read_body_json(resp).await;
    assert!(body.success);
    let user = body.data.unwrap();
    assert_eq!(user.id, user_id);
    assert_eq!(user.username, username);
    assert!(user.enabled);
}

#[tokio::test]
async fn test_get_user_by_username_not_found() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/user").configure(user::config))
    ).await;

    let req = test::TestRequest::get()
        .uri("/user/nonexistent-user")
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);

    let body: ApiError = test::read_body_json(resp).await;
    assert!(!body.success);
    assert!(body.message.contains("User not found"));
}

#[tokio::test]
async fn test_create_user_success() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/user").configure(user::config))
    ).await;

    let new_user = json!({
        "username": "new-test-user"
    });

    let req = test::TestRequest::post()
        .uri("/user")
        .set_json(&new_user)
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::CREATED);

    let body: ApiResponse<user::UserResponse> = test::read_body_json(resp).await;
    assert!(body.success);
    let user = body.data.unwrap();
    assert_eq!(user.username, "new-test-user");
    assert!(user.enabled);
    assert!(user.id > 0);
}

#[tokio::test]
async fn test_create_user_duplicate_username() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    // Insert existing user
    let username = "duplicate-user";
    let _user_id = insert_test_user(&test_config.db_pool, username).await.unwrap();
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/user").configure(user::config))
    ).await;

    let new_user = json!({
        "username": username
    });

    let req = test::TestRequest::post()
        .uri("/user")
        .set_json(&new_user)
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::INTERNAL_SERVER_ERROR);

    let body: ApiError = test::read_body_json(resp).await;
    assert!(!body.success);
}

#[tokio::test]
async fn test_create_user_empty_username() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/user").configure(user::config))
    ).await;

    let new_user = json!({
        "username": ""
    });

    let req = test::TestRequest::post()
        .uri("/user")
        .set_json(&new_user)
        .to_request();

    let resp = test::call_service(&app, req).await;
    // The validation behavior depends on implementation - 
    // could be 400 (validation error) or 500 (database constraint)
    assert!(resp.status().is_client_error() || resp.status().is_server_error());
}

#[tokio::test]
async fn test_update_user_success() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let username = "test-user-update";
    let _user_id = insert_test_user(&test_config.db_pool, username).await.unwrap();
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/user").configure(user::config))
    ).await;

    let update_data = json!({
        "username": "updated-username",
        "enabled": false
    });

    let req = test::TestRequest::put()
        .uri(&format!("/user/{}", username))
        .set_json(&update_data)
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::OK);

    let body: ApiResponse<()> = test::read_body_json(resp).await;
    assert!(body.success);
    assert!(body.message.unwrap().contains("User updated successfully"));
}

#[tokio::test]
async fn test_update_user_not_found() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/user").configure(user::config))
    ).await;

    let update_data = json!({
        "username": "updated-username",
        "enabled": false
    });

    let req = test::TestRequest::put()
        .uri("/user/nonexistent-user")
        .set_json(&update_data)
        .to_request();

    let resp = test::call_service(&app, req).await;
    // The behavior depends on implementation
    assert!(resp.status().is_client_error() || resp.status().is_server_error());
}

#[tokio::test]
async fn test_delete_user_without_confirmation() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let username = "test-user-delete";
    let _user_id = insert_test_user(&test_config.db_pool, username).await.unwrap();
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/user").configure(user::config))
    ).await;

    let delete_data = json!({
        "confirm": false
    });

    let req = test::TestRequest::delete()
        .uri(&format!("/user/{}", username))
        .set_json(&delete_data)
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::OK);

    // Should return information about what would be deleted
    let body: ApiResponse<user::DeleteUserResponse> = test::read_body_json(resp).await;
    assert!(body.success);
    
    // Verify user still exists
    let mut conn = test_config.db_pool.get().unwrap();
    let user = User::get_from_username(&mut conn, username.to_string()).await;
    assert!(user.is_ok());
    assert!(user.unwrap().is_some());
}

#[tokio::test]
async fn test_delete_user_with_confirmation() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let username = "test-user-delete-confirm";
    let _user_id = insert_test_user(&test_config.db_pool, username).await.unwrap();
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/user").configure(user::config))
    ).await;

    let delete_data = json!({
        "confirm": true
    });

    let req = test::TestRequest::delete()
        .uri(&format!("/user/{}", username))
        .set_json(&delete_data)
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::OK);

    let body: ApiResponse<()> = test::read_body_json(resp).await;
    assert!(body.success);
    
    // Verify user was deleted
    let mut conn = test_config.db_pool.get().unwrap();
    let user = User::get_from_username(&mut conn, username.to_string()).await;
    assert!(user.is_ok());
    assert!(user.unwrap().is_none());
}

#[tokio::test]
async fn test_delete_user_not_found() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/user").configure(user::config))
    ).await;

    let delete_data = json!({
        "confirm": true
    });

    let req = test::TestRequest::delete()
        .uri("/user/nonexistent-user")
        .set_json(&delete_data)
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);

    let body: ApiError = test::read_body_json(resp).await;
    assert!(!body.success);
    assert!(body.message.contains("User not found"));
}

#[tokio::test]
async fn test_get_user_keys() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let username = "test-user-keys";
    let user_id = insert_test_user(&test_config.db_pool, username).await.unwrap();
    let _key_id = insert_test_key(&test_config.db_pool, user_id).await.unwrap();
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/user").configure(user::config))
    ).await;

    let req = test::TestRequest::get()
        .uri(&format!("/user/{}/keys", username))
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::OK);

    let body: ApiResponse<user::UserKeysResponse> = test::read_body_json(resp).await;
    assert!(body.success);
    let keys = body.data.unwrap().keys;
    assert_eq!(keys.len(), 1);
    assert_eq!(keys[0].key_type, "ssh-rsa");
    assert!(keys[0].comment.as_ref().unwrap().contains("test@example.com"));
}

#[tokio::test]
async fn test_get_user_keys_empty() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let username = "test-user-no-keys";
    let _user_id = insert_test_user(&test_config.db_pool, username).await.unwrap();
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/user").configure(user::config))
    ).await;

    let req = test::TestRequest::get()
        .uri(&format!("/user/{}/keys", username))
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::OK);

    let body: ApiResponse<user::UserKeysResponse> = test::read_body_json(resp).await;
    assert!(body.success);
    let keys = body.data.unwrap().keys;
    assert_eq!(keys.len(), 0);
}

#[tokio::test]
async fn test_get_user_authorizations() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let username = "test-user-auth";
    let host_name = "test-host-auth";
    let user_id = insert_test_user(&test_config.db_pool, username).await.unwrap();
    let host_id = insert_test_host(&test_config.db_pool, host_name).await.unwrap();
    
    // Create authorization
    use crate::db::Host;
    let mut conn = test_config.db_pool.get().unwrap();
    Host::authorize_user(&mut conn, host_id, user_id, "ubuntu".to_string(), None).unwrap();
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/user").configure(user::config))
    ).await;

    let req = test::TestRequest::get()
        .uri(&format!("/user/{}/authorizations", username))
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::OK);

    let body: ApiResponse<user::UserAuthorizationsResponse> = test::read_body_json(resp).await;
    assert!(body.success);
    let authorizations = body.data.unwrap().authorizations;
    assert_eq!(authorizations.len(), 1);
    assert_eq!(authorizations[0].login, "ubuntu");
}

#[tokio::test]
async fn test_toggle_user_enabled_status() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let username = "test-user-toggle";
    let user_id = insert_test_user(&test_config.db_pool, username).await.unwrap();
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/user").configure(user::config))
    ).await;

    // Disable user
    let req = test::TestRequest::post()
        .uri(&format!("/user/{}/disable", username))
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::OK);

    // Verify user is disabled
    let mut conn = test_config.db_pool.get().unwrap();
    let user = User::get_from_username(&mut conn, username.to_string()).await.unwrap().unwrap();
    assert!(!user.enabled);

    // Enable user
    let req = test::TestRequest::post()
        .uri(&format!("/user/{}/enable", username))
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::OK);

    // Verify user is enabled
    let user = User::get_from_username(&mut conn, username.to_string()).await.unwrap().unwrap();
    assert!(user.enabled);
}

#[tokio::test]
async fn test_user_validation() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/user").configure(user::config))
    ).await;

    // Test with missing username field
    let invalid_user = json!({});

    let req = test::TestRequest::post()
        .uri("/user")
        .set_json(&invalid_user)
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

    // Test with very long username
    let long_username = "a".repeat(300);
    let invalid_user = json!({
        "username": long_username
    });

    let req = test::TestRequest::post()
        .uri("/user")
        .set_json(&invalid_user)
        .to_request();

    let resp = test::call_service(&app, req).await;
    // Should fail either with validation error or database constraint
    assert!(resp.status().is_client_error() || resp.status().is_server_error());
}