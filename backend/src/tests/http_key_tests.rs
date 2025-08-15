/// HTTP Key Management Endpoint Tests
/// 
/// Tests for /api/key/* endpoints with complete isolation

use actix_web::http::StatusCode;
use serde_json::json;

use crate::tests::http_test_utils::HttpTestContext;

#[actix_web::test]
async fn test_list_keys() {
    let mut ctx = HttpTestContext::new().await;
    ctx.login("testuser", "testpass").await.unwrap();
    
    // Create user and add some keys
    let user_id = ctx.create_test_user("keyuser").await;
    
    // Add multiple keys
    ctx.post_json("/api/user/assign_key", json!({
        "user_id": user_id,
        "key_type": "ssh-rsa",
        "key_base64": "AAAAB3NzaC1yc2EAAAADAQABAAABAQC7TEST1",
        "key_comment": "rsa@example.com"
    })).await;
    
    ctx.post_json("/api/user/assign_key", json!({
        "user_id": user_id,
        "key_type": "ssh-ed25519",
        "key_base64": "AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SuTEST2",
        "key_comment": "ed25519@example.com"
    })).await;
    
    // List all keys
    let resp = ctx.get("/api/key").await;
    assert_eq!(resp.status(), StatusCode::OK);
    
    let json = HttpTestContext::extract_json(resp).await;
    assert_eq!(json["status"], "success");
    
    let keys = json["data"].as_array().unwrap();
    assert!(keys.len() >= 2);
    
    // Check key types are present
    let key_types: Vec<String> = keys.iter()
        .map(|k| k["key_type"].as_str().unwrap().to_string())
        .collect();
    assert!(key_types.contains(&"ssh-rsa".to_string()));
    assert!(key_types.contains(&"ssh-ed25519".to_string()));
}

#[actix_web::test]
async fn test_delete_key() {
    let mut ctx = HttpTestContext::new().await;
    ctx.login("testuser", "testpass").await.unwrap();
    
    // Create user and add key
    let user_id = ctx.create_test_user("delkeyuser").await;
    
    ctx.post_json("/api/user/assign_key", json!({
        "user_id": user_id,
        "key_type": "ssh-rsa",
        "key_base64": "AAAAB3NzaC1yc2EAAAADAQABAAABAQC7DELTEST",
        "key_comment": "delete@example.com"
    })).await;
    
    // Get keys to find the key ID
    let resp = ctx.get("/api/key").await;
    let json = HttpTestContext::extract_json(resp).await;
    let keys = json["data"].as_array().unwrap();
    
    let delete_key = keys.iter()
        .find(|k| k["comment"].as_str().unwrap() == "delete@example.com")
        .unwrap();
    let key_id = delete_key["id"].as_i64().unwrap();
    
    // Delete the key
    let resp = ctx.delete(&format!("/api/key/{}", key_id)).await;
    assert_eq!(resp.status(), StatusCode::OK);
    
    let json = HttpTestContext::extract_json(resp).await;
    assert_eq!(json["status"], "success");
    assert_eq!(json["message"], "Key deleted successfully");
    
    // Verify key is deleted - should not appear in key list
    let resp = ctx.get("/api/key").await;
    let json = HttpTestContext::extract_json(resp).await;
    let remaining_keys = json["data"].as_array().unwrap();
    
    let found = remaining_keys.iter()
        .any(|k| k["comment"].as_str().unwrap() == "delete@example.com");
    assert!(!found, "Deleted key should not appear in key list");
}

#[actix_web::test]
async fn test_delete_nonexistent_key() {
    let mut ctx = HttpTestContext::new().await;
    ctx.login("testuser", "testpass").await.unwrap();
    
    // Try to delete non-existent key
    let resp = ctx.delete("/api/key/99999").await;
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
    
    let json = HttpTestContext::extract_json(resp).await;
    assert_eq!(json["status"], "error");
    assert_eq!(json["error"]["code"], "NOT_FOUND");
}

#[actix_web::test]
async fn test_update_key_comment() {
    let mut ctx = HttpTestContext::new().await;
    ctx.login("testuser", "testpass").await.unwrap();
    
    // Create user and add key
    let user_id = ctx.create_test_user("updatekeyuser").await;
    
    ctx.post_json("/api/user/assign_key", json!({
        "user_id": user_id,
        "key_type": "ssh-rsa",
        "key_base64": "AAAAB3NzaC1yc2EAAAADAQABAAABAQC7UPDATETEST",
        "key_comment": "old@example.com"
    })).await;
    
    // Get keys to find the key ID
    let resp = ctx.get("/api/key").await;
    let json = HttpTestContext::extract_json(resp).await;
    let keys = json["data"].as_array().unwrap();
    
    let update_key = keys.iter()
        .find(|k| k["comment"].as_str().unwrap() == "old@example.com")
        .unwrap();
    let key_id = update_key["id"].as_i64().unwrap();
    
    // Update the key comment
    let resp = ctx.put_json(&format!("/api/key/{}/comment", key_id), json!({
        "comment": "new@example.com"
    })).await;
    
    assert_eq!(resp.status(), StatusCode::OK);
    
    let json = HttpTestContext::extract_json(resp).await;
    assert_eq!(json["status"], "success");
    assert_eq!(json["message"], "Key comment updated successfully");
    
    // Verify the comment was updated
    let resp = ctx.get("/api/key").await;
    let json = HttpTestContext::extract_json(resp).await;
    let updated_keys = json["data"].as_array().unwrap();
    
    let found_key = updated_keys.iter()
        .find(|k| k["id"].as_i64().unwrap() == key_id)
        .unwrap();
    assert_eq!(found_key["comment"], "new@example.com");
}

#[actix_web::test]
async fn test_update_comment_nonexistent_key() {
    let mut ctx = HttpTestContext::new().await;
    ctx.login("testuser", "testpass").await.unwrap();
    
    // Try to update comment of non-existent key
    let resp = ctx.put_json("/api/key/99999/comment", json!({
        "comment": "new@example.com"
    })).await;
    
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
    
    let json = HttpTestContext::extract_json(resp).await;
    assert_eq!(json["status"], "error");
    assert_eq!(json["error"]["code"], "NOT_FOUND");
}

#[actix_web::test]
async fn test_update_key_comment_empty() {
    let mut ctx = HttpTestContext::new().await;
    ctx.login("testuser", "testpass").await.unwrap();
    
    // Create user and add key
    let user_id = ctx.create_test_user("emptycommentuser").await;
    
    ctx.post_json("/api/user/assign_key", json!({
        "user_id": user_id,
        "key_type": "ssh-rsa",
        "key_base64": "AAAAB3NzaC1yc2EAAAADAQABAAABAQC7EMPTYTEST",
        "key_comment": "hascomment@example.com"
    })).await;
    
    // Get key ID
    let resp = ctx.get("/api/key").await;
    let json = HttpTestContext::extract_json(resp).await;
    let keys = json["data"].as_array().unwrap();
    
    let key = keys.iter()
        .find(|k| k["comment"].as_str().unwrap() == "hascomment@example.com")
        .unwrap();
    let key_id = key["id"].as_i64().unwrap();
    
    // Update to empty comment
    let resp = ctx.put_json(&format!("/api/key/{}/comment", key_id), json!({
        "comment": ""
    })).await;
    
    assert_eq!(resp.status(), StatusCode::OK);
    
    // Verify empty comment
    let resp = ctx.get("/api/key").await;
    let json = HttpTestContext::extract_json(resp).await;
    let updated_keys = json["data"].as_array().unwrap();
    
    let found_key = updated_keys.iter()
        .find(|k| k["id"].as_i64().unwrap() == key_id)
        .unwrap();
    assert_eq!(found_key["comment"], "");
}

#[actix_web::test]
async fn test_key_validation_algorithms() {
    let mut ctx = HttpTestContext::new().await;
    ctx.login("testuser", "testpass").await.unwrap();
    
    let user_id = ctx.create_test_user("algouser").await;
    
    // Test valid algorithms
    let valid_algorithms = vec![
        ("ssh-rsa", "AAAAB3NzaC1yc2EAAAADAQABAAABgQC7VALID1"),
        ("ssh-ed25519", "AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SuVALID2"),
        ("ecdsa-sha2-nistp256", "AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEJM"),
        ("ecdsa-sha2-nistp384", "AAAAE2VjZHNhLXNoYTItbmlzdHAzODQAAAAIbmlzdHAzODQAAABhBEJM"),
        ("ecdsa-sha2-nistp521", "AAAAE2VjZHNhLXNoYTItbmlzdHA1MjEAAAAIbmlzdHA1MjEAAACFBEJM"),
        ("ssh-dss", "AAAAB3NzaC1kc3MAAACBAKaXnKzUjZWc1"),
    ];
    
    for (i, (algorithm, key_data)) in valid_algorithms.iter().enumerate() {
        let resp = ctx.post_json("/api/user/assign_key", json!({
            "user_id": user_id,
            "key_type": algorithm,
            "key_base64": key_data,
            "key_comment": format!("{}@test{}", algorithm, i)
        })).await;
        
        assert_eq!(
            resp.status(), 
            StatusCode::CREATED,
            "Algorithm {} should be valid", algorithm
        );
    }
    
    // Test invalid algorithm
    let resp = ctx.post_json("/api/user/assign_key", json!({
        "user_id": user_id,
        "key_type": "invalid-algorithm",
        "key_base64": "AAAAB3NzaC1yc2EAAAADAQABAAABgQC7INVALID",
        "key_comment": "invalid@test"
    })).await;
    
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    
    let json = HttpTestContext::extract_json(resp).await;
    assert_eq!(json["status"], "error");
    assert!(json["error"]["message"].as_str().unwrap().contains("Invalid key algorithm"));
}

#[actix_web::test]
async fn test_key_base64_validation() {
    let mut ctx = HttpTestContext::new().await;
    ctx.login("testuser", "testpass").await.unwrap();
    
    let user_id = ctx.create_test_user("base64user").await;
    
    // Test invalid base64 data
    let invalid_base64_cases = vec![
        "not-base64-data",
        "AAAAB3NzaC1yc2E!", // Invalid character
        "AAAAB3", // Too short
        "", // Empty
    ];
    
    for (i, invalid_data) in invalid_base64_cases.iter().enumerate() {
        let resp = ctx.post_json("/api/user/assign_key", json!({
            "user_id": user_id,
            "key_type": "ssh-rsa",
            "key_base64": invalid_data,
            "key_comment": format!("invalid{}@test", i)
        })).await;
        
        assert!(
            resp.status() == StatusCode::BAD_REQUEST || 
            resp.status() == StatusCode::UNPROCESSABLE_ENTITY,
            "Invalid base64 '{}' should be rejected", invalid_data
        );
    }
}

#[actix_web::test]
async fn test_key_filtering_by_user() {
    let mut ctx = HttpTestContext::new().await;
    ctx.login("testuser", "testpass").await.unwrap();
    
    // Create multiple users
    let user1_id = ctx.create_test_user("keyuser1").await;
    let user2_id = ctx.create_test_user("keyuser2").await;
    
    // Add keys to different users
    ctx.post_json("/api/user/assign_key", json!({
        "user_id": user1_id,
        "key_type": "ssh-rsa",
        "key_base64": "AAAAB3NzaC1yc2EAAAADAQABAAABAQC7USER1",
        "key_comment": "user1@example.com"
    })).await;
    
    ctx.post_json("/api/user/assign_key", json!({
        "user_id": user2_id,
        "key_type": "ssh-ed25519",
        "key_base64": "AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SuUSER2",
        "key_comment": "user2@example.com"
    })).await;
    
    // Get all keys
    let resp = ctx.get("/api/key").await;
    let json = HttpTestContext::extract_json(resp).await;
    let all_keys = json["data"].as_array().unwrap();
    
    // Should see both keys
    let comments: Vec<String> = all_keys.iter()
        .map(|k| k["comment"].as_str().unwrap().to_string())
        .collect();
    assert!(comments.contains(&"user1@example.com".to_string()));
    assert!(comments.contains(&"user2@example.com".to_string()));
    
    // Get keys for specific user
    let resp = ctx.get("/api/user/keyuser1/keys").await;
    let json = HttpTestContext::extract_json(resp).await;
    let user1_keys = json["data"].as_array().unwrap();
    
    // Should only see user1's key
    assert_eq!(user1_keys.len(), 1);
    assert_eq!(user1_keys[0]["comment"], "user1@example.com");
}

#[actix_web::test]
async fn test_delete_key_with_authorizations() {
    let mut ctx = HttpTestContext::new().await;
    ctx.login("testuser", "testpass").await.unwrap();
    
    // Create user, host, and key
    let user_id = ctx.create_test_user("authkeyuser").await;
    let host_id = ctx.create_test_host("authkeyhost", "192.168.1.200").await;
    
    // Add key to user
    ctx.post_json("/api/user/assign_key", json!({
        "user_id": user_id,
        "key_type": "ssh-rsa",
        "key_base64": "AAAAB3NzaC1yc2EAAAADAQABAAABAQC7AUTHKEY",
        "key_comment": "authkey@example.com"
    })).await;
    
    // Authorize user on host
    ctx.post_json("/api/host/user/authorize", json!({
        "host_id": host_id,
        "user_id": user_id,
        "login": "ubuntu",
        "options": null
    })).await;
    
    // Get key ID
    let resp = ctx.get("/api/key").await;
    let json = HttpTestContext::extract_json(resp).await;
    let keys = json["data"].as_array().unwrap();
    
    let key = keys.iter()
        .find(|k| k["comment"].as_str().unwrap() == "authkey@example.com")
        .unwrap();
    let key_id = key["id"].as_i64().unwrap();
    
    // Delete key (should work even with authorizations)
    let resp = ctx.delete(&format!("/api/key/{}", key_id)).await;
    assert_eq!(resp.status(), StatusCode::OK);
    
    // Verify key is deleted
    let resp = ctx.get("/api/key").await;
    let json = HttpTestContext::extract_json(resp).await;
    let remaining_keys = json["data"].as_array().unwrap();
    
    let found = remaining_keys.iter()
        .any(|k| k["comment"].as_str().unwrap() == "authkey@example.com");
    assert!(!found, "Deleted key should not appear in key list");
}

#[actix_web::test]
async fn test_key_endpoints_require_auth() {
    let ctx = HttpTestContext::new().await;
    
    // Try various endpoints without authentication
    let endpoints = vec![
        ("/api/key", "GET"),
        ("/api/key/1", "DELETE"),
        ("/api/key/1/comment", "PUT"),
    ];
    
    for (endpoint, method) in endpoints {
        let resp = match method {
            "GET" => ctx.get(endpoint).await,
            "DELETE" => ctx.delete(endpoint).await,
            "PUT" => ctx.put_json(endpoint, json!({"comment": "test"})).await,
            _ => panic!("Unknown method"),
        };
        
        assert!(
            resp.status() == StatusCode::UNAUTHORIZED || 
            resp.status() == StatusCode::SEE_OTHER,
            "Endpoint {} {} should require authentication, got {}",
            method, endpoint, resp.status()
        );
    }
}

#[actix_web::test]
async fn test_key_comment_special_characters() {
    let mut ctx = HttpTestContext::new().await;
    ctx.login("testuser", "testpass").await.unwrap();
    
    let user_id = ctx.create_test_user("specialuser").await;
    
    // Test comment with special characters
    let special_comment = "user@test.com (production-key) [2024-01-15]";
    
    ctx.post_json("/api/user/assign_key", json!({
        "user_id": user_id,
        "key_type": "ssh-rsa",
        "key_base64": "AAAAB3NzaC1yc2EAAAADAQABAAABAQC7SPECIAL",
        "key_comment": special_comment
    })).await;
    
    // Get keys and verify special characters are preserved
    let resp = ctx.get("/api/key").await;
    let json = HttpTestContext::extract_json(resp).await;
    let keys = json["data"].as_array().unwrap();
    
    let found_key = keys.iter()
        .find(|k| k["comment"].as_str().unwrap() == special_comment)
        .unwrap();
    assert_eq!(found_key["comment"], special_comment);
}

#[actix_web::test]
async fn test_concurrent_key_operations() {
    let mut ctx = HttpTestContext::new().await;
    ctx.login("testuser", "testpass").await.unwrap();
    
    let user_id = ctx.create_test_user("concurrentuser").await;
    
    // Add multiple keys concurrently (simulated by rapid sequential calls)
    let mut tasks = Vec::new();
    
    for i in 0..5 {
        let key_data = format!("AAAAB3NzaC1yc2EAAAADAQABAAABAQC7CONCURRENT{}", i);
        let comment = format!("concurrent{}@test.com", i);
        
        let resp = ctx.post_json("/api/user/assign_key", json!({
            "user_id": user_id,
            "key_type": "ssh-rsa",
            "key_base64": key_data,
            "key_comment": comment
        })).await;
        
        assert_eq!(resp.status(), StatusCode::CREATED);
        tasks.push(comment);
    }
    
    // Verify all keys were added
    let resp = ctx.get("/api/key").await;
    let json = HttpTestContext::extract_json(resp).await;
    let keys = json["data"].as_array().unwrap();
    
    let comments: Vec<String> = keys.iter()
        .map(|k| k["comment"].as_str().unwrap().to_string())
        .collect();
    
    for expected_comment in tasks {
        assert!(
            comments.contains(&expected_comment),
            "Key with comment '{}' should exist", expected_comment
        );
    }
}