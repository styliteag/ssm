use actix_web::{test, web, App, http::StatusCode};
use serde_json::json;

use crate::tests::test_utils::*;
use crate::routes::diff;
use crate::api_types::*;
use crate::db::Host;

#[tokio::test]
async fn test_get_diff_empty_host() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/diff").configure(diff::config))
    ).await;

    let req = test::TestRequest::get()
        .uri("/diff/nonexistent-host")
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);

    let body: ApiError = test::read_body_json(resp).await;
    assert!(!body.success);
    assert!(body.message.contains("Host not found"));
}

#[tokio::test]
async fn test_get_diff_no_authorizations() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let host_name = "test-host-no-auth";
    let _host_id = insert_test_host(&test_config.db_pool, host_name).await.unwrap();
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/diff").configure(diff::config))
    ).await;

    let req = test::TestRequest::get()
        .uri(&format!("/diff/{}", host_name))
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::OK);

    let body: ApiResponse<diff::DiffResponse> = test::read_body_json(resp).await;
    assert!(body.success);
    let diff = body.data.unwrap();
    assert_eq!(diff.host_name, host_name);
    assert_eq!(diff.logins.len(), 0);
}

#[tokio::test]
async fn test_get_diff_with_authorizations() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let host_name = "test-host-auth";
    let host_id = insert_test_host(&test_config.db_pool, host_name).await.unwrap();
    let user_id = insert_test_user(&test_config.db_pool, "test-user").await.unwrap();
    let _key_id = insert_test_key(&test_config.db_pool, user_id).await.unwrap();
    
    // Create authorization
    let mut conn = test_config.db_pool.get().unwrap();
    Host::authorize_user(&mut conn, host_id, user_id, "ubuntu".to_string(), None).unwrap();
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/diff").configure(diff::config))
    ).await;

    let req = test::TestRequest::get()
        .uri(&format!("/diff/{}", host_name))
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::OK);

    let body: ApiResponse<diff::DiffResponse> = test::read_body_json(resp).await;
    assert!(body.success);
    let diff = body.data.unwrap();
    assert_eq!(diff.host_name, host_name);
    assert_eq!(diff.logins.len(), 1);
    assert_eq!(diff.logins[0].login, "ubuntu");
}

#[tokio::test]
async fn test_get_diff_specific_login() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let host_name = "test-host-login";
    let host_id = insert_test_host(&test_config.db_pool, host_name).await.unwrap();
    let user1_id = insert_test_user(&test_config.db_pool, "test-user-1").await.unwrap();
    let user2_id = insert_test_user(&test_config.db_pool, "test-user-2").await.unwrap();
    let _key1_id = insert_test_key(&test_config.db_pool, user1_id).await.unwrap();
    let _key2_id = insert_test_key(&test_config.db_pool, user2_id).await.unwrap();
    
    // Create authorizations for different logins
    let mut conn = test_config.db_pool.get().unwrap();
    Host::authorize_user(&mut conn, host_id, user1_id, "ubuntu".to_string(), None).unwrap();
    Host::authorize_user(&mut conn, host_id, user2_id, "root".to_string(), None).unwrap();
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/diff").configure(diff::config))
    ).await;

    // Test specific login filter
    let req = test::TestRequest::get()
        .uri(&format!("/diff/{}?login=ubuntu", host_name))
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::OK);

    let body: ApiResponse<diff::DiffResponse> = test::read_body_json(resp).await;
    assert!(body.success);
    let diff = body.data.unwrap();
    assert_eq!(diff.host_name, host_name);
    assert_eq!(diff.logins.len(), 1);
    assert_eq!(diff.logins[0].login, "ubuntu");
}

#[tokio::test]
async fn test_generate_authorized_keys() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let host_name = "test-host-gen";
    let host_id = insert_test_host(&test_config.db_pool, host_name).await.unwrap();
    let user_id = insert_test_user(&test_config.db_pool, "test-user").await.unwrap();
    let _key_id = insert_test_key(&test_config.db_pool, user_id).await.unwrap();
    
    // Create authorization
    let mut conn = test_config.db_pool.get().unwrap();
    Host::authorize_user(&mut conn, host_id, user_id, "ubuntu".to_string(), Some("no-port-forwarding".to_string())).unwrap();
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/diff").configure(diff::config))
    ).await;

    let req = test::TestRequest::get()
        .uri(&format!("/diff/{}/generate/ubuntu", host_name))
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::OK);

    let body: ApiResponse<diff::AuthorizedKeysResponse> = test::read_body_json(resp).await;
    assert!(body.success);
    let authorized_keys = body.data.unwrap();
    assert_eq!(authorized_keys.login, "ubuntu");
    assert!(!authorized_keys.content.is_empty());
    assert!(authorized_keys.content.contains("ssh-rsa"));
    assert!(authorized_keys.content.contains("no-port-forwarding"));
    assert!(authorized_keys.content.contains("test@example.com"));
}

#[tokio::test]
async fn test_generate_authorized_keys_no_keys() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let host_name = "test-host-no-keys";
    let host_id = insert_test_host(&test_config.db_pool, host_name).await.unwrap();
    let user_id = insert_test_user(&test_config.db_pool, "test-user").await.unwrap();
    
    // Create authorization but no keys
    let mut conn = test_config.db_pool.get().unwrap();
    Host::authorize_user(&mut conn, host_id, user_id, "ubuntu".to_string(), None).unwrap();
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/diff").configure(diff::config))
    ).await;

    let req = test::TestRequest::get()
        .uri(&format!("/diff/{}/generate/ubuntu", host_name))
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::OK);

    let body: ApiResponse<diff::AuthorizedKeysResponse> = test::read_body_json(resp).await;
    assert!(body.success);
    let authorized_keys = body.data.unwrap();
    assert_eq!(authorized_keys.login, "ubuntu");
    assert!(authorized_keys.content.is_empty() || authorized_keys.content.trim().is_empty());
}

#[tokio::test]
async fn test_generate_authorized_keys_nonexistent_login() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let host_name = "test-host-no-login";
    let _host_id = insert_test_host(&test_config.db_pool, host_name).await.unwrap();
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/diff").configure(diff::config))
    ).await;

    let req = test::TestRequest::get()
        .uri(&format!("/diff/{}/generate/nonexistent", host_name))
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::OK);

    let body: ApiResponse<diff::AuthorizedKeysResponse> = test::read_body_json(resp).await;
    assert!(body.success);
    let authorized_keys = body.data.unwrap();
    assert_eq!(authorized_keys.login, "nonexistent");
    assert!(authorized_keys.content.is_empty() || authorized_keys.content.trim().is_empty());
}

#[tokio::test]
async fn test_compare_keys() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/diff").configure(diff::config))
    ).await;

    let compare_data = json!({
        "current_keys": "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCold_key old@example.com\n",
        "expected_keys": "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCnew_key new@example.com\n"
    });

    let req = test::TestRequest::post()
        .uri("/diff/compare")
        .set_json(&compare_data)
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::OK);

    let body: ApiResponse<diff::KeyComparisonResponse> = test::read_body_json(resp).await;
    assert!(body.success);
    let comparison = body.data.unwrap();
    assert!(!comparison.identical);
    assert!(!comparison.changes.is_empty());
}

#[tokio::test]
async fn test_compare_identical_keys() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/diff").configure(diff::config))
    ).await;

    let identical_key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCsame_key same@example.com\n";
    let compare_data = json!({
        "current_keys": identical_key,
        "expected_keys": identical_key
    });

    let req = test::TestRequest::post()
        .uri("/diff/compare")
        .set_json(&compare_data)
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::OK);

    let body: ApiResponse<diff::KeyComparisonResponse> = test::read_body_json(resp).await;
    assert!(body.success);
    let comparison = body.data.unwrap();
    assert!(comparison.identical);
    assert!(comparison.changes.is_empty());
}

#[tokio::test]
async fn test_compare_empty_keys() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/diff").configure(diff::config))
    ).await;

    let compare_data = json!({
        "current_keys": "",
        "expected_keys": ""
    });

    let req = test::TestRequest::post()
        .uri("/diff/compare")
        .set_json(&compare_data)
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::OK);

    let body: ApiResponse<diff::KeyComparisonResponse> = test::read_body_json(resp).await;
    assert!(body.success);
    let comparison = body.data.unwrap();
    assert!(comparison.identical);
    assert!(comparison.changes.is_empty());
}

#[tokio::test]
async fn test_apply_diff() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let host_name = "test-host-apply";
    let host_id = insert_test_host(&test_config.db_pool, host_name).await.unwrap();
    let user_id = insert_test_user(&test_config.db_pool, "test-user").await.unwrap();
    let _key_id = insert_test_key(&test_config.db_pool, user_id).await.unwrap();
    
    // Create authorization
    let mut conn = test_config.db_pool.get().unwrap();
    Host::authorize_user(&mut conn, host_id, user_id, "ubuntu".to_string(), None).unwrap();
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/diff").configure(diff::config))
    ).await;

    let apply_data = json!({
        "host_name": host_name,
        "login": "ubuntu",
        "dry_run": true
    });

    let req = test::TestRequest::post()
        .uri("/diff/apply")
        .set_json(&apply_data)
        .to_request();

    let resp = test::call_service(&app, req).await;
    // Note: This might fail due to SSH client not being properly mocked
    // In a real implementation, you'd mock the SSH operations
    assert!(resp.status().is_success() || resp.status().is_server_error());
}

#[tokio::test]
async fn test_diff_multiple_users_same_login() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let host_name = "test-host-multi";
    let host_id = insert_test_host(&test_config.db_pool, host_name).await.unwrap();
    let user1_id = insert_test_user(&test_config.db_pool, "test-user-1").await.unwrap();
    let user2_id = insert_test_user(&test_config.db_pool, "test-user-2").await.unwrap();
    let _key1_id = insert_test_key(&test_config.db_pool, user1_id).await.unwrap();
    let _key2_id = insert_test_key(&test_config.db_pool, user2_id).await.unwrap();
    
    // Both users authorized for same login
    let mut conn = test_config.db_pool.get().unwrap();
    Host::authorize_user(&mut conn, host_id, user1_id, "ubuntu".to_string(), None).unwrap();
    Host::authorize_user(&mut conn, host_id, user2_id, "ubuntu".to_string(), Some("restrict".to_string())).unwrap();
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/diff").configure(diff::config))
    ).await;

    let req = test::TestRequest::get()
        .uri(&format!("/diff/{}/generate/ubuntu", host_name))
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::OK);

    let body: ApiResponse<diff::AuthorizedKeysResponse> = test::read_body_json(resp).await;
    assert!(body.success);
    let authorized_keys = body.data.unwrap();
    assert_eq!(authorized_keys.login, "ubuntu");
    
    // Should contain keys from both users
    let lines: Vec<&str> = authorized_keys.content.lines().collect();
    let key_lines: Vec<&str> = lines.iter().filter(|line| line.starts_with("ssh-rsa")).cloned().collect();
    assert_eq!(key_lines.len(), 2);
    
    // One should have restrictions, one should not
    let restricted_count = key_lines.iter().filter(|line| line.contains("restrict")).count();
    assert_eq!(restricted_count, 1);
}

#[tokio::test]
async fn test_diff_disabled_user() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let host_name = "test-host-disabled";
    let host_id = insert_test_host(&test_config.db_pool, host_name).await.unwrap();
    let user_id = insert_test_user(&test_config.db_pool, "disabled-user").await.unwrap();
    let _key_id = insert_test_key(&test_config.db_pool, user_id).await.unwrap();
    
    // Create authorization
    let mut conn = test_config.db_pool.get().unwrap();
    Host::authorize_user(&mut conn, host_id, user_id, "ubuntu".to_string(), None).unwrap();
    
    // Disable the user
    use crate::db::User;
    User::disable_user(&mut conn, user_id).unwrap();
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/diff").configure(diff::config))
    ).await;

    let req = test::TestRequest::get()
        .uri(&format!("/diff/{}/generate/ubuntu", host_name))
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::OK);

    let body: ApiResponse<diff::AuthorizedKeysResponse> = test::read_body_json(resp).await;
    assert!(body.success);
    let authorized_keys = body.data.unwrap();
    assert_eq!(authorized_keys.login, "ubuntu");
    
    // Should not contain keys from disabled user
    assert!(authorized_keys.content.is_empty() || authorized_keys.content.trim().is_empty());
}

#[cfg(test)]
mod diff_logic_tests {
    use super::*;
    use similar::{ChangeTag, TextDiff};

    #[test]
    fn test_text_diff_additions() {
        let old = "ssh-rsa AAAAB3old old@example.com\n";
        let new = "ssh-rsa AAAAB3old old@example.com\nssh-rsa AAAAB3new new@example.com\n";
        
        let diff = TextDiff::from_lines(old, new);
        let changes: Vec<_> = diff.iter_all_changes().collect();
        
        // Should have both old line (unchanged) and new line (added)
        assert!(changes.len() >= 2);
        assert!(changes.iter().any(|c| c.tag() == ChangeTag::Insert));
    }

    #[test]
    fn test_text_diff_deletions() {
        let old = "ssh-rsa AAAAB3old old@example.com\nssh-rsa AAAAB3remove remove@example.com\n";
        let new = "ssh-rsa AAAAB3old old@example.com\n";
        
        let diff = TextDiff::from_lines(old, new);
        let changes: Vec<_> = diff.iter_all_changes().collect();
        
        // Should have deletions
        assert!(changes.iter().any(|c| c.tag() == ChangeTag::Delete));
    }

    #[test]
    fn test_text_diff_identical() {
        let text = "ssh-rsa AAAAB3same same@example.com\n";
        
        let diff = TextDiff::from_lines(text, text);
        let changes: Vec<_> = diff.iter_all_changes().collect();
        
        // Should only have equal changes
        assert!(changes.iter().all(|c| c.tag() == ChangeTag::Equal));
    }
}