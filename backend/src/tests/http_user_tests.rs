/// HTTP User Management Endpoint Tests
/// 
/// Tests for /api/user/* endpoints with complete isolation

use actix_web::http::StatusCode;
use serde_json::json;

use crate::tests::http_test_utils::HttpTestContext;

#[actix_web::test]
async fn test_list_users() {
    let mut ctx = HttpTestContext::new().await;
    ctx.login("testuser", "testpass").await.unwrap();
    
    // Create some test users
    ctx.create_test_user("alice").await;
    ctx.create_test_user("bob").await;
    
    // List users
    let resp = ctx.get("/api/user").await;
    assert_eq!(resp.status(), StatusCode::OK);
    
    let json = HttpTestContext::extract_json(resp).await;
    assert_eq!(json["status"], "success");
    
    let users = json["data"].as_array().unwrap();
    assert!(users.len() >= 2);
    
    // Check that our test users are in the list
    let usernames: Vec<String> = users.iter()
        .map(|u| u["username"].as_str().unwrap().to_string())
        .collect();
    assert!(usernames.contains(&"alice".to_string()));
    assert!(usernames.contains(&"bob".to_string()));
}

#[actix_web::test]
async fn test_create_user() {
    let mut ctx = HttpTestContext::new().await;
    ctx.login("testuser", "testpass").await.unwrap();
    
    let resp = ctx.post_json("/api/user", json!({
        "username": "newuser"
    })).await;
    
    assert_eq!(resp.status(), StatusCode::CREATED);
    
    let json = HttpTestContext::extract_json(resp).await;
    assert_eq!(json["status"], "success");
    assert_eq!(json["data"]["username"], "newuser");
    assert_eq!(json["data"]["enabled"], true);
}

#[actix_web::test]
async fn test_create_duplicate_user() {
    let mut ctx = HttpTestContext::new().await;
    ctx.login("testuser", "testpass").await.unwrap();
    
    // Create user first time
    ctx.post_json("/api/user", json!({
        "username": "duplicate"
    })).await;
    
    // Try to create same user again
    let resp = ctx.post_json("/api/user", json!({
        "username": "duplicate"
    })).await;
    
    assert_eq!(resp.status(), StatusCode::INTERNAL_SERVER_ERROR);
    
    let json = HttpTestContext::extract_json(resp).await;
    assert_eq!(json["status"], "error");
}

#[actix_web::test]
async fn test_get_user() {
    let mut ctx = HttpTestContext::new().await;
    ctx.login("testuser", "testpass").await.unwrap();
    
    // Create a user
    ctx.create_test_user("gettest").await;
    
    // Get the user
    let resp = ctx.get("/api/user/gettest").await;
    assert_eq!(resp.status(), StatusCode::OK);
    
    let json = HttpTestContext::extract_json(resp).await;
    assert_eq!(json["status"], "success");
    assert_eq!(json["data"]["username"], "gettest");
    assert_eq!(json["data"]["enabled"], true);
}

#[actix_web::test]
async fn test_get_nonexistent_user() {
    let mut ctx = HttpTestContext::new().await;
    ctx.login("testuser", "testpass").await.unwrap();
    
    let resp = ctx.get("/api/user/nonexistent").await;
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
    
    let json = HttpTestContext::extract_json(resp).await;
    assert_eq!(json["status"], "error");
    assert_eq!(json["error"]["code"], "NOT_FOUND");
}

#[actix_web::test]
async fn test_update_user() {
    let mut ctx = HttpTestContext::new().await;
    ctx.login("testuser", "testpass").await.unwrap();
    
    // Create a user
    ctx.create_test_user("updatetest").await;
    
    // Update the user (rename and disable)
    let resp = ctx.put_json("/api/user/updatetest", json!({
        "username": "renamed",
        "enabled": false
    })).await;
    
    assert_eq!(resp.status(), StatusCode::OK);
    
    let json = HttpTestContext::extract_json(resp).await;
    assert_eq!(json["status"], "success");
    
    // Verify the update
    let resp = ctx.get("/api/user/renamed").await;
    let json = HttpTestContext::extract_json(resp).await;
    assert_eq!(json["data"]["username"], "renamed");
    assert_eq!(json["data"]["enabled"], false);
}

#[actix_web::test]
async fn test_delete_user() {
    let mut ctx = HttpTestContext::new().await;
    ctx.login("testuser", "testpass").await.unwrap();
    
    // Create a user
    ctx.create_test_user("deletetest").await;
    
    // Delete the user
    let resp = ctx.delete("/api/user/deletetest").await;
    assert_eq!(resp.status(), StatusCode::OK);
    
    let json = HttpTestContext::extract_json(resp).await;
    assert_eq!(json["status"], "success");
    
    // Verify user is deleted
    let resp = ctx.get("/api/user/deletetest").await;
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

#[actix_web::test]
async fn test_get_user_keys() {
    let mut ctx = HttpTestContext::new().await;
    ctx.login("testuser", "testpass").await.unwrap();
    
    // Create a user
    let user_id = ctx.create_test_user("keyuser").await;
    
    // Add a key for the user
    ctx.post_json("/api/user/assign_key", json!({
        "user_id": user_id,
        "key_type": "ssh-rsa",
        "key_base64": "AAAAB3NzaC1yc2EAAAADAQABAAABgQC7TEST",
        "key_comment": "test@example.com"
    })).await;
    
    // Get user's keys
    let resp = ctx.get("/api/user/keyuser/keys").await;
    assert_eq!(resp.status(), StatusCode::OK);
    
    let json = HttpTestContext::extract_json(resp).await;
    assert_eq!(json["status"], "success");
    
    let keys = json["data"].as_array().unwrap();
    assert_eq!(keys.len(), 1);
    assert_eq!(keys[0]["key_type"], "ssh-rsa");
    assert_eq!(keys[0]["comment"], "test@example.com");
}

#[actix_web::test]
async fn test_assign_key_to_user() {
    let mut ctx = HttpTestContext::new().await;
    ctx.login("testuser", "testpass").await.unwrap();
    
    // Create a user
    let user_id = ctx.create_test_user("assignkeyuser").await;
    
    // Assign a key
    let resp = ctx.post_json("/api/user/assign_key", json!({
        "user_id": user_id,
        "key_type": "ssh-ed25519",
        "key_base64": "AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SuVKT",
        "key_comment": "ed25519@test"
    })).await;
    
    assert_eq!(resp.status(), StatusCode::CREATED);
    
    let json = HttpTestContext::extract_json(resp).await;
    assert_eq!(json["status"], "success");
    assert_eq!(json["message"], "Key assigned successfully");
}

#[actix_web::test]
async fn test_assign_invalid_key_type() {
    let mut ctx = HttpTestContext::new().await;
    ctx.login("testuser", "testpass").await.unwrap();
    
    let user_id = ctx.create_test_user("invalidkeyuser").await;
    
    // Try to assign key with invalid type
    let resp = ctx.post_json("/api/user/assign_key", json!({
        "user_id": user_id,
        "key_type": "invalid-type",
        "key_base64": "AAAAB3NzaC1yc2EAAAADAQABAAABgQC7TEST",
        "key_comment": "test"
    })).await;
    
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    
    let json = HttpTestContext::extract_json(resp).await;
    assert_eq!(json["status"], "error");
    assert!(json["error"]["message"].as_str().unwrap().contains("Invalid key algorithm"));
}

#[actix_web::test]
async fn test_get_user_authorizations() {
    let mut ctx = HttpTestContext::new().await;
    ctx.login("testuser", "testpass").await.unwrap();
    
    // Create user and host
    let user_id = ctx.create_test_user("authuser").await;
    let host_id = ctx.create_test_host("authhost", "192.168.1.50").await;
    
    // Authorize user on host
    ctx.post_json("/api/host/user/authorize", json!({
        "host_id": host_id,
        "user_id": user_id,
        "login": "ubuntu",
        "options": "no-port-forwarding"
    })).await;
    
    // Get user's authorizations
    let resp = ctx.get("/api/user/authuser/authorizations").await;
    assert_eq!(resp.status(), StatusCode::OK);
    
    let json = HttpTestContext::extract_json(resp).await;
    assert_eq!(json["status"], "success");
    
    let auths = json["data"].as_array().unwrap();
    assert_eq!(auths.len(), 1);
    assert_eq!(auths[0]["host_name"], "authhost");
    assert_eq!(auths[0]["login"], "ubuntu");
    assert_eq!(auths[0]["options"], "no-port-forwarding");
}

#[actix_web::test]
async fn test_user_endpoints_require_auth() {
    let ctx = HttpTestContext::new().await;
    
    // Try various endpoints without authentication
    let endpoints = vec![
        ("/api/user", "GET"),
        ("/api/user", "POST"),
        ("/api/user/someuser", "GET"),
        ("/api/user/someuser", "PUT"),
        ("/api/user/someuser", "DELETE"),
        ("/api/user/someuser/keys", "GET"),
        ("/api/user/someuser/authorizations", "GET"),
    ];
    
    for (endpoint, method) in endpoints {
        let resp = match method {
            "GET" => ctx.get(endpoint).await,
            "POST" => ctx.post_json(endpoint, json!({})).await,
            "PUT" => ctx.put_json(endpoint, json!({})).await,
            "DELETE" => ctx.delete(endpoint).await,
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