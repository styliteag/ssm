/// HTTP Host Management Endpoint Tests
/// 
/// Tests for /api/host/* endpoints with complete isolation

use actix_web::http::StatusCode;
use serde_json::json;

use crate::tests::http_test_utils::HttpTestContext;

#[actix_web::test]
async fn test_list_hosts() {
    let mut ctx = HttpTestContext::new().await;
    ctx.login("testuser", "testpass").await.unwrap();
    
    // Create some test hosts
    ctx.create_test_host("host1", "192.168.1.10").await;
    ctx.create_test_host("host2", "192.168.1.20").await;
    
    // List hosts
    let resp = ctx.get("/api/host").await;
    assert_eq!(resp.status(), StatusCode::OK);
    
    let json = HttpTestContext::extract_json(resp).await;
    assert_eq!(json["status"], "success");
    
    let hosts = json["data"].as_array().unwrap();
    assert!(hosts.len() >= 2);
    
    let hostnames: Vec<String> = hosts.iter()
        .map(|h| h["name"].as_str().unwrap().to_string())
        .collect();
    assert!(hostnames.contains(&"host1".to_string()));
    assert!(hostnames.contains(&"host2".to_string()));
}

#[actix_web::test]
async fn test_create_host_with_fingerprint() {
    let mut ctx = HttpTestContext::new().await;
    ctx.login("testuser", "testpass").await.unwrap();
    
    let resp = ctx.post_json("/api/host", json!({
        "name": "newhost",
        "address": "192.168.1.100",
        "port": 2222,
        "username": "admin",
        "key_fingerprint": "SHA256:abcd1234efgh5678",
        "jump_via": null
    })).await;
    
    // When creating with fingerprint, should return 201
    assert_eq!(resp.status(), StatusCode::CREATED);
    
    let json = HttpTestContext::extract_json(resp).await;
    assert_eq!(json["status"], "success");
    assert_eq!(json["data"]["name"], "newhost");
    assert_eq!(json["data"]["address"], "192.168.1.100");
    assert_eq!(json["data"]["port"], 2222);
    assert_eq!(json["data"]["username"], "admin");
}

#[actix_web::test]
async fn test_create_host_without_fingerprint() {
    let mut ctx = HttpTestContext::new().await;
    ctx.login("testuser", "testpass").await.unwrap();
    
    // Create host without fingerprint - should prompt for confirmation
    let resp = ctx.post_json("/api/host", json!({
        "name": "needsfingerprint",
        "address": "192.168.1.101",
        "port": 22,
        "username": "ubuntu",
        "key_fingerprint": null,
        "jump_via": null
    })).await;
    
    // Should return 200 with requires_confirmation
    assert_eq!(resp.status(), StatusCode::OK);
    
    let json = HttpTestContext::extract_json(resp).await;
    assert_eq!(json["status"], "success");
    assert_eq!(json["data"]["requires_confirmation"], true);
    assert!(json["data"]["key_fingerprint"].as_str().is_some());
}

#[actix_web::test]
async fn test_get_host() {
    let mut ctx = HttpTestContext::new().await;
    ctx.login("testuser", "testpass").await.unwrap();
    
    // Create a host
    ctx.create_test_host("gethost", "192.168.1.30").await;
    
    // Get the host
    let resp = ctx.get("/api/host/gethost").await;
    assert_eq!(resp.status(), StatusCode::OK);
    
    let json = HttpTestContext::extract_json(resp).await;
    assert_eq!(json["status"], "success");
    assert_eq!(json["data"]["name"], "gethost");
    assert_eq!(json["data"]["address"], "192.168.1.30");
}

#[actix_web::test]
async fn test_get_nonexistent_host() {
    let mut ctx = HttpTestContext::new().await;
    ctx.login("testuser", "testpass").await.unwrap();
    
    let resp = ctx.get("/api/host/nonexistent").await;
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
    
    let json = HttpTestContext::extract_json(resp).await;
    assert_eq!(json["status"], "error");
    assert_eq!(json["error"]["code"], "NOT_FOUND");
}

#[actix_web::test]
async fn test_update_host() {
    let mut ctx = HttpTestContext::new().await;
    ctx.login("testuser", "testpass").await.unwrap();
    
    // Create a host
    ctx.create_test_host("updatehost", "192.168.1.40").await;
    
    // Update the host
    let resp = ctx.put_json("/api/host/updatehost", json!({
        "name": "renamedhost",
        "address": "192.168.1.41",
        "username": "root",
        "port": 2222,
        "key_fingerprint": "SHA256:newfingerprint",
        "jump_via": ""
    })).await;
    
    assert_eq!(resp.status(), StatusCode::OK);
    
    let json = HttpTestContext::extract_json(resp).await;
    assert_eq!(json["status"], "success");
    
    // Verify the update
    let resp = ctx.get("/api/host/renamedhost").await;
    let json = HttpTestContext::extract_json(resp).await;
    assert_eq!(json["data"]["name"], "renamedhost");
    assert_eq!(json["data"]["address"], "192.168.1.41");
    assert_eq!(json["data"]["port"], 2222);
}

#[actix_web::test]
async fn test_delete_host_with_confirmation() {
    let mut ctx = HttpTestContext::new().await;
    ctx.login("testuser", "testpass").await.unwrap();
    
    // Create a host
    ctx.create_test_host("deletehost", "192.168.1.50").await;
    
    // Delete without confirmation - should return info
    let resp = ctx.delete_json("/api/host/deletehost", json!({
        "confirm": false
    })).await;
    assert_eq!(resp.status(), StatusCode::OK);
    
    let json = HttpTestContext::extract_json(resp).await;
    assert_eq!(json["status"], "success");
    // Should return affected authorizations and hosts
    assert!(json["data"]["authorizations"].is_array());
    
    // Host should still exist
    let resp = ctx.get("/api/host/deletehost").await;
    assert_eq!(resp.status(), StatusCode::OK);
    
    // Delete with confirmation
    let resp = ctx.delete_json("/api/host/deletehost", json!({
        "confirm": true
    })).await;
    assert_eq!(resp.status(), StatusCode::OK);
    
    // Host should be deleted
    let resp = ctx.get("/api/host/deletehost").await;
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

#[actix_web::test]
async fn test_get_host_logins() {
    let mut ctx = HttpTestContext::new().await;
    ctx.login("testuser", "testpass").await.unwrap();
    
    // Create a host
    ctx.create_test_host("loginhost", "192.168.1.60").await;
    
    // Get logins (mock should return empty list)
    let resp = ctx.get("/api/host/loginhost/logins").await;
    assert_eq!(resp.status(), StatusCode::OK);
    
    let json = HttpTestContext::extract_json(resp).await;
    assert_eq!(json["status"], "success");
    assert!(json["data"]["logins"].is_array());
}

#[actix_web::test]
async fn test_authorize_user_on_host() {
    let mut ctx = HttpTestContext::new().await;
    ctx.login("testuser", "testpass").await.unwrap();
    
    // Create user and host
    let user_id = ctx.create_test_user("authuser").await;
    let host_id = ctx.create_test_host("authhost", "192.168.1.70").await;
    
    // Authorize user
    let resp = ctx.post_json("/api/host/user/authorize", json!({
        "host_id": host_id,
        "user_id": user_id,
        "login": "deploy",
        "options": "no-x11-forwarding"
    })).await;
    
    assert_eq!(resp.status(), StatusCode::OK);
    
    let json = HttpTestContext::extract_json(resp).await;
    assert_eq!(json["status"], "success");
    assert_eq!(json["message"], "User authorized successfully");
}

#[actix_web::test]
async fn test_get_host_authorizations() {
    let mut ctx = HttpTestContext::new().await;
    ctx.login("testuser", "testpass").await.unwrap();
    
    // Create user and host
    let user_id = ctx.create_test_user("listuser").await;
    let host_id = ctx.create_test_host("listhost", "192.168.1.80").await;
    
    // Authorize user
    ctx.post_json("/api/host/user/authorize", json!({
        "host_id": host_id,
        "user_id": user_id,
        "login": "admin",
        "options": null
    })).await;
    
    // Get host authorizations
    let resp = ctx.get("/api/host/listhost/authorizations").await;
    assert_eq!(resp.status(), StatusCode::OK);
    
    let json = HttpTestContext::extract_json(resp).await;
    assert_eq!(json["status"], "success");
    
    let auths = json["data"]["authorizations"].as_array().unwrap();
    assert_eq!(auths.len(), 1);
    assert_eq!(auths[0]["username"], "listuser");
    assert_eq!(auths[0]["login"], "admin");
}

#[actix_web::test]
async fn test_delete_authorization() {
    let mut ctx = HttpTestContext::new().await;
    ctx.login("testuser", "testpass").await.unwrap();
    
    // Create user and host
    let user_id = ctx.create_test_user("deluser").await;
    let host_id = ctx.create_test_host("delhost", "192.168.1.90").await;
    
    // Authorize user
    ctx.post_json("/api/host/user/authorize", json!({
        "host_id": host_id,
        "user_id": user_id,
        "login": "ubuntu",
        "options": null
    })).await;
    
    // Get authorizations to find the ID
    let resp = ctx.get("/api/host/delhost/authorizations").await;
    let json = HttpTestContext::extract_json(resp).await;
    let auth_id = json["data"]["authorizations"][0]["authorization_id"].as_i64().unwrap();
    
    // Delete the authorization
    let resp = ctx.delete(&format!("/api/host/authorization/{}", auth_id)).await;
    assert_eq!(resp.status(), StatusCode::OK);
    
    // Verify it's deleted
    let resp = ctx.get("/api/host/delhost/authorizations").await;
    let json = HttpTestContext::extract_json(resp).await;
    let auths = json["data"]["authorizations"].as_array().unwrap();
    assert_eq!(auths.len(), 0);
}

#[actix_web::test]
async fn test_gen_authorized_keys() {
    let mut ctx = HttpTestContext::new().await;
    ctx.login("testuser", "testpass").await.unwrap();
    
    // Create user with key and host
    let user_id = ctx.create_test_user("keygenuser").await;
    let host_id = ctx.create_test_host("keygenhost", "192.168.1.95").await;
    
    // Add key to user
    ctx.post_json("/api/user/assign_key", json!({
        "user_id": user_id,
        "key_type": "ssh-rsa",
        "key_base64": "AAAAB3NzaC1yc2EAAAADAQABAAABAQC7TEST",
        "key_comment": "test@keygen"
    })).await;
    
    // Authorize user
    ctx.post_json("/api/host/user/authorize", json!({
        "host_id": host_id,
        "user_id": user_id,
        "login": "ubuntu",
        "options": null
    })).await;
    
    // Generate authorized keys
    let resp = ctx.post_json("/api/host/gen_authorized_keys", json!({
        "host_name": "keygenhost",
        "login": "ubuntu"
    })).await;
    
    assert_eq!(resp.status(), StatusCode::OK);
    
    let json = HttpTestContext::extract_json(resp).await;
    assert_eq!(json["status"], "success");
    assert_eq!(json["data"]["login"], "ubuntu");
    assert!(json["data"]["authorized_keys"].as_str().unwrap().contains("ssh-rsa"));
}

#[actix_web::test]
async fn test_set_authorized_keys() {
    let mut ctx = HttpTestContext::new().await;
    ctx.login("testuser", "testpass").await.unwrap();
    
    // Create host
    ctx.create_test_host("setkeyshost", "192.168.1.96").await;
    
    // Set authorized keys (mock will accept but not really deploy)
    let resp = ctx.post_json("/api/host/setkeyshost/set_authorized_keys", json!({
        "login": "deploy",
        "authorized_keys": "ssh-rsa AAAAB3NzaC1yc2E... deploy@example\nssh-ed25519 AAAAC3NzaC... backup@example"
    })).await;
    
    assert_eq!(resp.status(), StatusCode::OK);
    
    let json = HttpTestContext::extract_json(resp).await;
    assert_eq!(json["status"], "success");
    assert_eq!(json["message"], "Authorized keys applied successfully");
}

#[actix_web::test]
async fn test_add_host_key() {
    let mut ctx = HttpTestContext::new().await;
    ctx.login("testuser", "testpass").await.unwrap();
    
    // Create host
    let host_id = ctx.create_test_host("hostkeyhost", "192.168.1.97").await;
    
    // Add host key with fingerprint
    let resp = ctx.post_json(&format!("/api/host/{}/add_hostkey", host_id), json!({
        "key_fingerprint": "SHA256:newhostkey123456"
    })).await;
    
    assert_eq!(resp.status(), StatusCode::OK);
    
    let json = HttpTestContext::extract_json(resp).await;
    assert_eq!(json["status"], "success");
    assert_eq!(json["message"], "Host key updated successfully");
}

#[actix_web::test]
async fn test_host_with_jumphost() {
    let mut ctx = HttpTestContext::new().await;
    ctx.login("testuser", "testpass").await.unwrap();
    
    // Create jumphost first
    let jump_id = ctx.create_test_host("jumphost", "10.0.0.1").await;
    
    // Create host with jumphost
    let resp = ctx.post_json("/api/host", json!({
        "name": "targethost",
        "address": "192.168.100.10",
        "port": 22,
        "username": "ubuntu",
        "key_fingerprint": "SHA256:targetfingerprint",
        "jump_via": jump_id
    })).await;
    
    assert_eq!(resp.status(), StatusCode::CREATED);
    
    // Get host and verify jumphost
    let resp = ctx.get("/api/host/targethost").await;
    let json = HttpTestContext::extract_json(resp).await;
    assert_eq!(json["data"]["jump_via"], jump_id);
    assert_eq!(json["data"]["jumphost_name"], "jumphost");
}

#[actix_web::test]
async fn test_host_endpoints_require_auth() {
    let ctx = HttpTestContext::new().await;
    
    // Try various endpoints without authentication
    let endpoints = vec![
        ("/api/host", "GET"),
        ("/api/host", "POST"),
        ("/api/host/somehost", "GET"),
        ("/api/host/somehost", "PUT"),
        ("/api/host/somehost", "DELETE"),
        ("/api/host/somehost/logins", "GET"),
        ("/api/host/somehost/authorizations", "GET"),
        ("/api/host/user/authorize", "POST"),
        ("/api/host/gen_authorized_keys", "POST"),
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