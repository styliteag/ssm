use actix_web::{test, web, App, http::StatusCode};
use serde_json::json;

use crate::tests::test_utils::*;
use crate::routes::authorization;
use crate::api_types::*;
use crate::db::{Host, User};

#[tokio::test]
async fn test_get_all_authorizations_empty() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/authorization").configure(authorization::config))
    ).await;

    let req = test::TestRequest::get()
        .uri("/authorization")
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::OK);

    let body: ApiResponse<Vec<authorization::AuthorizationResponse>> = test::read_body_json(resp).await;
    assert!(body.success);
    assert_eq!(body.data.unwrap().len(), 0);
}

#[tokio::test]
async fn test_get_all_authorizations_with_data() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    // Setup test data
    let user_id = insert_test_user(&test_config.db_pool, "test-user").await.unwrap();
    let host_id = insert_test_host(&test_config.db_pool, "test-host").await.unwrap();
    
    // Create authorization
    let mut conn = test_config.db_pool.get().unwrap();
    Host::authorize_user(&mut conn, host_id, user_id, "ubuntu".to_string(), Some("no-port-forwarding".to_string())).unwrap();
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/authorization").configure(authorization::config))
    ).await;

    let req = test::TestRequest::get()
        .uri("/authorization")
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::OK);

    let body: ApiResponse<Vec<authorization::AuthorizationResponse>> = test::read_body_json(resp).await;
    assert!(body.success);
    let authorizations = body.data.unwrap();
    assert_eq!(authorizations.len(), 1);
    assert_eq!(authorizations[0].login, "ubuntu");
    assert_eq!(authorizations[0].options, Some("no-port-forwarding".to_string()));
}

#[tokio::test]
async fn test_create_authorization_success() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let user_id = insert_test_user(&test_config.db_pool, "test-user").await.unwrap();
    let host_id = insert_test_host(&test_config.db_pool, "test-host").await.unwrap();
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/authorization").configure(authorization::config))
    ).await;

    let new_auth = json!({
        "user_id": user_id,
        "host_id": host_id,
        "login": "ubuntu",
        "options": "no-port-forwarding,no-agent-forwarding"
    });

    let req = test::TestRequest::post()
        .uri("/authorization")
        .set_json(&new_auth)
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::CREATED);

    let body: ApiResponse<authorization::AuthorizationResponse> = test::read_body_json(resp).await;
    assert!(body.success);
    let auth = body.data.unwrap();
    assert_eq!(auth.login, "ubuntu");
    assert_eq!(auth.options, Some("no-port-forwarding,no-agent-forwarding".to_string()));
    assert!(auth.id > 0);
}

#[tokio::test]
async fn test_create_authorization_invalid_user() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let host_id = insert_test_host(&test_config.db_pool, "test-host").await.unwrap();
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/authorization").configure(authorization::config))
    ).await;

    let new_auth = json!({
        "user_id": 99999,
        "host_id": host_id,
        "login": "ubuntu",
        "options": null
    });

    let req = test::TestRequest::post()
        .uri("/authorization")
        .set_json(&new_auth)
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::INTERNAL_SERVER_ERROR);

    let body: ApiError = test::read_body_json(resp).await;
    assert!(!body.success);
}

#[tokio::test]
async fn test_create_authorization_invalid_host() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let user_id = insert_test_user(&test_config.db_pool, "test-user").await.unwrap();
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/authorization").configure(authorization::config))
    ).await;

    let new_auth = json!({
        "user_id": user_id,
        "host_id": 99999,
        "login": "ubuntu",
        "options": null
    });

    let req = test::TestRequest::post()
        .uri("/authorization")
        .set_json(&new_auth)
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::INTERNAL_SERVER_ERROR);

    let body: ApiError = test::read_body_json(resp).await;
    assert!(!body.success);
}

#[tokio::test]
async fn test_create_duplicate_authorization() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let user_id = insert_test_user(&test_config.db_pool, "test-user").await.unwrap();
    let host_id = insert_test_host(&test_config.db_pool, "test-host").await.unwrap();
    
    // Create first authorization
    let mut conn = test_config.db_pool.get().unwrap();
    Host::authorize_user(&mut conn, host_id, user_id, "ubuntu".to_string(), None).unwrap();
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/authorization").configure(authorization::config))
    ).await;

    // Try to create duplicate authorization
    let duplicate_auth = json!({
        "user_id": user_id,
        "host_id": host_id,
        "login": "ubuntu",
        "options": null
    });

    let req = test::TestRequest::post()
        .uri("/authorization")
        .set_json(&duplicate_auth)
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::INTERNAL_SERVER_ERROR);

    let body: ApiError = test::read_body_json(resp).await;
    assert!(!body.success);
}

#[tokio::test]
async fn test_get_authorization_by_id_success() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let user_id = insert_test_user(&test_config.db_pool, "test-user").await.unwrap();
    let host_id = insert_test_host(&test_config.db_pool, "test-host").await.unwrap();
    
    // Create authorization
    let mut conn = test_config.db_pool.get().unwrap();
    Host::authorize_user(&mut conn, host_id, user_id, "ubuntu".to_string(), Some("test-options".to_string())).unwrap();
    
    // Get the authorization ID
    use crate::schema::authorization::dsl::*;
    use diesel::prelude::*;
    let auth_id: i32 = authorization
        .filter(host_id.eq(host_id))
        .filter(user_id.eq(user_id))
        .select(id)
        .first(&mut conn)
        .unwrap();
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/authorization").configure(authorization::config))
    ).await;

    let req = test::TestRequest::get()
        .uri(&format!("/authorization/{}", auth_id))
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::OK);

    let body: ApiResponse<authorization::AuthorizationResponse> = test::read_body_json(resp).await;
    assert!(body.success);
    let auth = body.data.unwrap();
    assert_eq!(auth.id, auth_id);
    assert_eq!(auth.login, "ubuntu");
    assert_eq!(auth.options, Some("test-options".to_string()));
}

#[tokio::test]
async fn test_get_authorization_by_id_not_found() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/authorization").configure(authorization::config))
    ).await;

    let req = test::TestRequest::get()
        .uri("/authorization/99999")
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);

    let body: ApiError = test::read_body_json(resp).await;
    assert!(!body.success);
    assert!(body.message.contains("Authorization not found"));
}

#[tokio::test]
async fn test_update_authorization_success() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let user_id = insert_test_user(&test_config.db_pool, "test-user").await.unwrap();
    let host_id = insert_test_host(&test_config.db_pool, "test-host").await.unwrap();
    
    // Create authorization
    let mut conn = test_config.db_pool.get().unwrap();
    Host::authorize_user(&mut conn, host_id, user_id, "ubuntu".to_string(), None).unwrap();
    
    // Get the authorization ID
    use crate::schema::authorization::dsl::*;
    use diesel::prelude::*;
    let auth_id: i32 = authorization
        .filter(host_id.eq(host_id))
        .filter(user_id.eq(user_id))
        .select(id)
        .first(&mut conn)
        .unwrap();
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/authorization").configure(authorization::config))
    ).await;

    let update_data = json!({
        "login": "root",
        "options": "command=\"/bin/false\",no-pty"
    });

    let req = test::TestRequest::put()
        .uri(&format!("/authorization/{}", auth_id))
        .set_json(&update_data)
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::OK);

    let body: ApiResponse<()> = test::read_body_json(resp).await;
    assert!(body.success);
    assert!(body.message.unwrap().contains("Authorization updated successfully"));
}

#[tokio::test]
async fn test_update_authorization_not_found() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/authorization").configure(authorization::config))
    ).await;

    let update_data = json!({
        "login": "root",
        "options": "command=\"/bin/false\",no-pty"
    });

    let req = test::TestRequest::put()
        .uri("/authorization/99999")
        .set_json(&update_data)
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);

    let body: ApiError = test::read_body_json(resp).await;
    assert!(!body.success);
    assert!(body.message.contains("Authorization not found"));
}

#[tokio::test]
async fn test_delete_authorization_success() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let user_id = insert_test_user(&test_config.db_pool, "test-user").await.unwrap();
    let host_id = insert_test_host(&test_config.db_pool, "test-host").await.unwrap();
    
    // Create authorization
    let mut conn = test_config.db_pool.get().unwrap();
    Host::authorize_user(&mut conn, host_id, user_id, "ubuntu".to_string(), None).unwrap();
    
    // Get the authorization ID
    use crate::schema::authorization::dsl::*;
    use diesel::prelude::*;
    let auth_id: i32 = authorization
        .filter(host_id.eq(host_id))
        .filter(user_id.eq(user_id))
        .select(id)
        .first(&mut conn)
        .unwrap();
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/authorization").configure(authorization::config))
    ).await;

    let req = test::TestRequest::delete()
        .uri(&format!("/authorization/{}", auth_id))
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::OK);

    let body: ApiResponse<()> = test::read_body_json(resp).await;
    assert!(body.success);
    assert!(body.message.unwrap().contains("Authorization deleted successfully"));
    
    // Verify authorization was deleted
    let remaining: i64 = authorization
        .filter(id.eq(auth_id))
        .count()
        .get_result(&mut conn)
        .unwrap();
    assert_eq!(remaining, 0);
}

#[tokio::test]
async fn test_delete_authorization_not_found() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/authorization").configure(authorization::config))
    ).await;

    let req = test::TestRequest::delete()
        .uri("/authorization/99999")
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);

    let body: ApiError = test::read_body_json(resp).await;
    assert!(!body.success);
    assert!(body.message.contains("Authorization not found"));
}

#[tokio::test]
async fn test_get_authorizations_by_user() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let user_id = insert_test_user(&test_config.db_pool, "test-user").await.unwrap();
    let host1_id = insert_test_host(&test_config.db_pool, "test-host-1").await.unwrap();
    let host2_id = insert_test_host(&test_config.db_pool, "test-host-2").await.unwrap();
    
    // Create multiple authorizations for the same user
    let mut conn = test_config.db_pool.get().unwrap();
    Host::authorize_user(&mut conn, host1_id, user_id, "ubuntu".to_string(), None).unwrap();
    Host::authorize_user(&mut conn, host2_id, user_id, "root".to_string(), Some("restricted".to_string())).unwrap();
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/authorization").configure(authorization::config))
    ).await;

    let req = test::TestRequest::get()
        .uri(&format!("/authorization/user/{}", user_id))
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::OK);

    let body: ApiResponse<Vec<authorization::AuthorizationResponse>> = test::read_body_json(resp).await;
    assert!(body.success);
    let authorizations = body.data.unwrap();
    assert_eq!(authorizations.len(), 2);
    
    // Verify both authorizations belong to the user
    assert!(authorizations.iter().all(|a| a.user_id == user_id));
    
    // Verify different logins
    let logins: Vec<&String> = authorizations.iter().map(|a| &a.login).collect();
    assert!(logins.contains(&&"ubuntu".to_string()));
    assert!(logins.contains(&&"root".to_string()));
}

#[tokio::test]
async fn test_get_authorizations_by_host() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let user1_id = insert_test_user(&test_config.db_pool, "test-user-1").await.unwrap();
    let user2_id = insert_test_user(&test_config.db_pool, "test-user-2").await.unwrap();
    let host_id = insert_test_host(&test_config.db_pool, "test-host").await.unwrap();
    
    // Create multiple authorizations for the same host
    let mut conn = test_config.db_pool.get().unwrap();
    Host::authorize_user(&mut conn, host_id, user1_id, "ubuntu".to_string(), None).unwrap();
    Host::authorize_user(&mut conn, host_id, user2_id, "admin".to_string(), Some("no-pty".to_string())).unwrap();
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/authorization").configure(authorization::config))
    ).await;

    let req = test::TestRequest::get()
        .uri(&format!("/authorization/host/{}", host_id))
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::OK);

    let body: ApiResponse<Vec<authorization::AuthorizationResponse>> = test::read_body_json(resp).await;
    assert!(body.success);
    let authorizations = body.data.unwrap();
    assert_eq!(authorizations.len(), 2);
    
    // Verify both authorizations belong to the host
    assert!(authorizations.iter().all(|a| a.host_id == host_id));
    
    // Verify different users
    let user_ids: Vec<i32> = authorizations.iter().map(|a| a.user_id).collect();
    assert!(user_ids.contains(&user1_id));
    assert!(user_ids.contains(&user2_id));
}

#[tokio::test]
async fn test_authorization_matrix() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    // Setup a matrix of users and hosts
    let user1_id = insert_test_user(&test_config.db_pool, "user1").await.unwrap();
    let user2_id = insert_test_user(&test_config.db_pool, "user2").await.unwrap();
    let host1_id = insert_test_host(&test_config.db_pool, "host1").await.unwrap();
    let host2_id = insert_test_host(&test_config.db_pool, "host2").await.unwrap();
    
    // Create selective authorizations
    let mut conn = test_config.db_pool.get().unwrap();
    Host::authorize_user(&mut conn, host1_id, user1_id, "ubuntu".to_string(), None).unwrap();
    Host::authorize_user(&mut conn, host2_id, user2_id, "root".to_string(), None).unwrap();
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/authorization").configure(authorization::config))
    ).await;

    // Get authorization matrix
    let req = test::TestRequest::get()
        .uri("/authorization/matrix")
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::OK);

    let body: ApiResponse<authorization::AuthorizationMatrixResponse> = test::read_body_json(resp).await;
    assert!(body.success);
    let matrix = body.data.unwrap();
    
    // Should have 2 users and 2 hosts with 2 authorizations
    assert_eq!(matrix.users.len(), 2);
    assert_eq!(matrix.hosts.len(), 2);
    assert_eq!(matrix.authorizations.len(), 2);
}

#[tokio::test]
async fn test_authorization_validation() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/authorization").configure(authorization::config))
    ).await;

    // Test with missing required fields
    let invalid_auth = json!({
        "user_id": 1
    });

    let req = test::TestRequest::post()
        .uri("/authorization")
        .set_json(&invalid_auth)
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

    // Test with empty login
    let invalid_auth = json!({
        "user_id": 1,
        "host_id": 1,
        "login": "",
        "options": null
    });

    let req = test::TestRequest::post()
        .uri("/authorization")
        .set_json(&invalid_auth)
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert!(resp.status().is_client_error() || resp.status().is_server_error());
}