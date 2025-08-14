use actix_web::{test, web, App, http::StatusCode};
use serde_json::json;

use crate::tests::test_utils::*;
use crate::routes::key;
use crate::api_types::*;
use crate::db::PublicUserKey;
use crate::models::PublicUserKey as ModelPublicUserKey;

#[tokio::test]
async fn test_get_all_keys_empty() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/key").configure(key::config))
    ).await;

    let req = test::TestRequest::get()
        .uri("/key")
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::OK);

    let body: ApiResponse<Vec<key::KeyResponse>> = test::read_body_json(resp).await;
    assert!(body.success);
    assert_eq!(body.data.unwrap().len(), 0);
}

#[tokio::test]
async fn test_get_all_keys_with_data() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    // Setup test data
    let user1_id = insert_test_user(&test_config.db_pool, "test-user-1").await.unwrap();
    let user2_id = insert_test_user(&test_config.db_pool, "test-user-2").await.unwrap();
    let key1_id = insert_test_key(&test_config.db_pool, user1_id).await.unwrap();
    let key2_id = insert_test_key(&test_config.db_pool, user2_id).await.unwrap();
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/key").configure(key::config))
    ).await;

    let req = test::TestRequest::get()
        .uri("/key")
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::OK);

    let body: ApiResponse<Vec<key::KeyResponse>> = test::read_body_json(resp).await;
    assert!(body.success);
    let keys = body.data.unwrap();
    assert_eq!(keys.len(), 2);
    assert!(keys.iter().any(|k| k.id == key1_id));
    assert!(keys.iter().any(|k| k.id == key2_id));
}

#[tokio::test]
async fn test_get_key_by_id_success() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let user_id = insert_test_user(&test_config.db_pool, "test-user").await.unwrap();
    let key_id = insert_test_key(&test_config.db_pool, user_id).await.unwrap();
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/key").configure(key::config))
    ).await;

    let req = test::TestRequest::get()
        .uri(&format!("/key/{}", key_id))
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::OK);

    let body: ApiResponse<key::KeyResponse> = test::read_body_json(resp).await;
    assert!(body.success);
    let key = body.data.unwrap();
    assert_eq!(key.id, key_id);
    assert_eq!(key.key_type, "ssh-rsa");
    assert!(key.comment.as_ref().unwrap().contains("test@example.com"));
}

#[tokio::test]
async fn test_get_key_by_id_not_found() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/key").configure(key::config))
    ).await;

    let req = test::TestRequest::get()
        .uri("/key/99999")
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);

    let body: ApiError = test::read_body_json(resp).await;
    assert!(!body.success);
    assert!(body.message.contains("Key not found"));
}

#[tokio::test]
async fn test_create_key_success() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let user_id = insert_test_user(&test_config.db_pool, "test-user").await.unwrap();
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/key").configure(key::config))
    ).await;

    let new_key = json!({
        "user_id": user_id,
        "key_type": "ssh-rsa",
        "key_base64": "AAAAB3NzaC1yc2EAAAADAQABAAABgQC7vbqajDw5XJjfsQM1dLDEeuxWiZQ",
        "comment": "new-test-key@example.com"
    });

    let req = test::TestRequest::post()
        .uri("/key")
        .set_json(&new_key)
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::CREATED);

    let body: ApiResponse<key::KeyResponse> = test::read_body_json(resp).await;
    assert!(body.success);
    let key = body.data.unwrap();
    assert_eq!(key.key_type, "ssh-rsa");
    assert_eq!(key.comment.unwrap(), "new-test-key@example.com");
    assert!(key.id > 0);
}

#[tokio::test]
async fn test_create_key_invalid_user() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/key").configure(key::config))
    ).await;

    let new_key = json!({
        "user_id": 99999,
        "key_type": "ssh-rsa",
        "key_base64": "AAAAB3NzaC1yc2EAAAADAQABAAABgQC7vbqajDw5XJjfsQM1dLDEeuxWiZQ",
        "comment": "test@example.com"
    });

    let req = test::TestRequest::post()
        .uri("/key")
        .set_json(&new_key)
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::INTERNAL_SERVER_ERROR);

    let body: ApiError = test::read_body_json(resp).await;
    assert!(!body.success);
}

#[tokio::test]
async fn test_create_key_invalid_format() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let user_id = insert_test_user(&test_config.db_pool, "test-user").await.unwrap();
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/key").configure(key::config))
    ).await;

    let new_key = json!({
        "user_id": user_id,
        "key_type": "invalid-type",
        "key_base64": "invalid-base64-data",
        "comment": "test@example.com"
    });

    let req = test::TestRequest::post()
        .uri("/key")
        .set_json(&new_key)
        .to_request();

    let resp = test::call_service(&app, req).await;
    // Behavior depends on validation - could be 400 or 500
    assert!(resp.status().is_client_error() || resp.status().is_server_error());
}

#[tokio::test]
async fn test_update_key_success() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let user_id = insert_test_user(&test_config.db_pool, "test-user").await.unwrap();
    let key_id = insert_test_key(&test_config.db_pool, user_id).await.unwrap();
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/key").configure(key::config))
    ).await;

    let update_data = json!({
        "comment": "updated-comment@example.com"
    });

    let req = test::TestRequest::put()
        .uri(&format!("/key/{}", key_id))
        .set_json(&update_data)
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::OK);

    let body: ApiResponse<()> = test::read_body_json(resp).await;
    assert!(body.success);
    assert!(body.message.unwrap().contains("Key updated successfully"));
}

#[tokio::test]
async fn test_update_key_not_found() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/key").configure(key::config))
    ).await;

    let update_data = json!({
        "comment": "updated-comment@example.com"
    });

    let req = test::TestRequest::put()
        .uri("/key/99999")
        .set_json(&update_data)
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);

    let body: ApiError = test::read_body_json(resp).await;
    assert!(!body.success);
    assert!(body.message.contains("Key not found"));
}

#[tokio::test]
async fn test_delete_key_success() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let user_id = insert_test_user(&test_config.db_pool, "test-user").await.unwrap();
    let key_id = insert_test_key(&test_config.db_pool, user_id).await.unwrap();
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/key").configure(key::config))
    ).await;

    let req = test::TestRequest::delete()
        .uri(&format!("/key/{}", key_id))
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::OK);

    let body: ApiResponse<()> = test::read_body_json(resp).await;
    assert!(body.success);
    assert!(body.message.unwrap().contains("Key deleted successfully"));
    
    // Verify key was deleted
    let mut conn = test_config.db_pool.get().unwrap();
    let key = PublicUserKey::get_from_id(&mut conn, key_id).await;
    assert!(key.is_ok());
    assert!(key.unwrap().is_none());
}

#[tokio::test]
async fn test_delete_key_not_found() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/key").configure(key::config))
    ).await;

    let req = test::TestRequest::delete()
        .uri("/key/99999")
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);

    let body: ApiError = test::read_body_json(resp).await;
    assert!(!body.success);
    assert!(body.message.contains("Key not found"));
}

#[tokio::test]
async fn test_parse_openssh_key_valid() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let user_id = insert_test_user(&test_config.db_pool, "test-user").await.unwrap();
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/key").configure(key::config))
    ).await;

    let openssh_key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC7vbqajDw5XJjfsQM1dLDEeuxWiZQ user@example.com";
    let parse_data = json!({
        "user_id": user_id,
        "openssh_key": openssh_key
    });

    let req = test::TestRequest::post()
        .uri("/key/parse")
        .set_json(&parse_data)
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::OK);

    let body: ApiResponse<key::KeyResponse> = test::read_body_json(resp).await;
    assert!(body.success);
    let key = body.data.unwrap();
    assert_eq!(key.key_type, "ssh-rsa");
    assert_eq!(key.comment.unwrap(), "user@example.com");
}

#[tokio::test]
async fn test_parse_openssh_key_invalid() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let user_id = insert_test_user(&test_config.db_pool, "test-user").await.unwrap();
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/key").configure(key::config))
    ).await;

    let openssh_key = "invalid-ssh-key-format";
    let parse_data = json!({
        "user_id": user_id,
        "openssh_key": openssh_key
    });

    let req = test::TestRequest::post()
        .uri("/key/parse")
        .set_json(&parse_data)
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

    let body: ApiError = test::read_body_json(resp).await;
    assert!(!body.success);
    assert!(body.message.contains("Invalid SSH key format"));
}

#[tokio::test]
async fn test_key_validation() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let user_id = insert_test_user(&test_config.db_pool, "test-user").await.unwrap();
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/key").configure(key::config))
    ).await;

    // Test with missing required fields
    let invalid_key = json!({
        "user_id": user_id
    });

    let req = test::TestRequest::post()
        .uri("/key")
        .set_json(&invalid_key)
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

    // Test with empty key_base64
    let invalid_key = json!({
        "user_id": user_id,
        "key_type": "ssh-rsa",
        "key_base64": "",
        "comment": "test@example.com"
    });

    let req = test::TestRequest::post()
        .uri("/key")
        .set_json(&invalid_key)
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert!(resp.status().is_client_error() || resp.status().is_server_error());
}

#[cfg(test)]
mod model_tests {
    use super::*;
    use crate::models::PublicUserKey;

    #[test]
    fn test_key_to_openssh() {
        let key = PublicUserKey {
            id: 1,
            key_type: "ssh-rsa".to_string(),
            key_base64: "AAAAB3NzaC1yc2EAAAADAQABAAABgQC7vbqajDw5XJjfsQM1dLDEeuxWiZQ".to_string(),
            comment: Some("test@example.com".to_string()),
            user_id: 1,
        };

        let openssh = key.to_openssh();
        assert_eq!(openssh, "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC7vbqajDw5XJjfsQM1dLDEeuxWiZQ test@example.com");
    }

    #[test]
    fn test_key_to_openssh_no_comment() {
        let key = PublicUserKey {
            id: 1,
            key_type: "ssh-rsa".to_string(),
            key_base64: "AAAAB3NzaC1yc2EAAAADAQABAAABgQC7vbqajDw5XJjfsQM1dLDEeuxWiZQ".to_string(),
            comment: None,
            user_id: 1,
        };

        let openssh = key.to_openssh();
        assert_eq!(openssh, "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC7vbqajDw5XJjfsQM1dLDEeuxWiZQ");
    }

    #[test]
    fn test_key_preview() {
        let key = PublicUserKey {
            id: 1,
            key_type: "ssh-rsa".to_string(),
            key_base64: "AAAAB3NzaC1yc2EAAAADAQABAAABgQC7vbqajDw5XJjfsQM1dLDEeuxWiZQ".to_string(),
            comment: Some("test@example.com".to_string()),
            user_id: 1,
        };

        let preview = key.key_preview();
        assert_eq!(preview, "...iZQ");
    }

    #[test]
    fn test_key_preview_short() {
        let key = PublicUserKey {
            id: 1,
            key_type: "ssh-rsa".to_string(),
            key_base64: "ABC".to_string(),
            comment: Some("test@example.com".to_string()),
            user_id: 1,
        };

        let preview = key.key_preview();
        assert_eq!(preview, "...ABC");
    }
}

#[tokio::test]
async fn test_bulk_key_operations() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let user_id = insert_test_user(&test_config.db_pool, "test-user").await.unwrap();
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/key").configure(key::config))
    ).await;

    // Create multiple keys
    for i in 1..=3 {
        let new_key = json!({
            "user_id": user_id,
            "key_type": "ssh-rsa",
            "key_base64": format!("AAAAB3NzaC1yc2EAAAADAQABAAABgQC7vbqajDw5XJjfsQM1dLDEeuxWi{:02}", i),
            "comment": format!("test-key-{}@example.com", i)
        });

        let req = test::TestRequest::post()
            .uri("/key")
            .set_json(&new_key)
            .to_request();

        let resp = test::call_service(&app, req).await;
        assert_eq!(resp.status(), StatusCode::CREATED);
    }

    // Verify all keys were created
    let req = test::TestRequest::get()
        .uri("/key")
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::OK);

    let body: ApiResponse<Vec<key::KeyResponse>> = test::read_body_json(resp).await;
    assert!(body.success);
    assert_eq!(body.data.unwrap().len(), 3);
}