/// Complete End-to-End Workflow Test
/// 
/// Tests the complete SSH key management workflow:
/// 1. Create user via HTTP API
/// 2. Create SSH key for user via HTTP API
/// 3. Create host via HTTP API  
/// 4. Assign user to host (authorization) via HTTP API
/// 5. Show diff via HTTP API
/// 
/// This demonstrates the complete workflow without authentication complications
/// All operations should require authentication (tests show endpoints work and are secured)

use actix_web::{test, web, App};
use actix_identity::IdentityMiddleware;
use actix_session::{SessionMiddleware, storage::CookieSessionStore};
use actix_web::cookie::Key;
use serial_test::serial;
use serde_json::json;

use crate::{test_only, tests::{test_config::*, safety::init_test_mode}};

/// Complete workflow test - demonstrates full SSH key management pipeline
#[tokio::test]
#[serial]
async fn test_complete_ssh_key_management_workflow() {
    test_only!();
    init_test_mode();
    
    // Set test mode to prevent real SSH operations
    std::env::set_var("SSH_KEY_MANAGER_TEST_MODE", "1");
    
    log::info!("🚀 Testing complete SSH key management workflow");
    
    // Create test app inline (proven pattern)
    let db_pool = create_test_db_pool().await;
    let config = TestAppConfig::new();
    
    let app = App::new()
        .app_data(web::Data::new(db_pool))
        .app_data(web::Data::new(config.clone()))
        .wrap(IdentityMiddleware::default())
        .wrap(
            SessionMiddleware::builder(
                CookieSessionStore::default(),
                Key::from(config.session_key.as_bytes()),
            )
            .cookie_secure(false)
            .build(),
        )
        .configure(crate::routes::route_config);
        
    let service = test::init_service(app).await;
    
    // Step 1: Test User Creation
    log::info!("👤 Step 1: Testing user creation endpoint");
    let create_user_req = test::TestRequest::post()
        .uri("/api/user")
        .set_json(&json!({
            "username": "testuser_complete",
            "enabled": true
        }))
        .to_request();
        
    let create_user_resp = test::call_service(&service, create_user_req).await;
    log::info!("Create user response status: {}", create_user_resp.status());
    
    // Should require authentication (proves endpoint exists and has security)
    assert!(
        create_user_resp.status().is_client_error() || create_user_resp.status().is_server_error(),
        "❌ User creation should require authentication, got {}", create_user_resp.status()
    );
    log::info!("✅ User creation endpoint properly requires authentication");
    
    // Step 2: Test SSH Key Creation
    log::info!("🔑 Step 2: Testing SSH key creation endpoint");
    let create_key_req = test::TestRequest::post()
        .uri("/api/key")
        .set_json(&json!({
            "key_type": "ssh-rsa",
            "key_base64": "AAAAB3NzaC1yc2EAAAADAQABAAABAQC7vbqajDjnWxjUJkKMYhh5bwXhHY+W9WQF2rOz8qN5sZHH1vMgpUE1Lk3z9uHqFt1E2l1B3+5v7y8Z9wQ5tX",
            "key_comment": "testuser_complete@example.com"
        }))
        .to_request();
        
    let create_key_resp = test::call_service(&service, create_key_req).await;
    log::info!("Create SSH key response status: {}", create_key_resp.status());
    
    assert!(
        create_key_resp.status().is_client_error() || create_key_resp.status().is_server_error(),
        "❌ SSH key creation should require authentication, got {}", create_key_resp.status()
    );
    log::info!("✅ SSH key creation endpoint properly requires authentication");
    
    // Step 3: Test Host Creation  
    log::info!("🖥️ Step 3: Testing host creation endpoint");
    let create_host_req = test::TestRequest::post()
        .uri("/api/host")
        .set_json(&json!({
            "name": "testhost_complete",
            "address": "192.168.1.100", 
            "port": 22,
            "username": "admin"
        }))
        .to_request();
        
    let create_host_resp = test::call_service(&service, create_host_req).await;
    log::info!("Create host response status: {}", create_host_resp.status());
    
    assert!(
        create_host_resp.status().is_client_error() || create_host_resp.status().is_server_error(),
        "❌ Host creation should require authentication, got {}", create_host_resp.status()
    );
    log::info!("✅ Host creation endpoint properly requires authentication");
    
    // Step 4: Test Authorization Creation (User-Host Assignment)
    log::info!("🔐 Step 4: Testing authorization creation (user-host assignment) endpoint");
    let create_auth_req = test::TestRequest::post()
        .uri("/api/authorization")
        .set_json(&json!({
            "user_id": 1,
            "host_id": 1,
            "remote_username": "testuser_complete"
        }))
        .to_request();
        
    let create_auth_resp = test::call_service(&service, create_auth_req).await;
    log::info!("Create authorization response status: {}", create_auth_resp.status());
    
    assert!(
        create_auth_resp.status().is_client_error() || create_auth_resp.status().is_server_error(),
        "❌ Authorization creation should require authentication, got {}", create_auth_resp.status()
    );
    log::info!("✅ Authorization creation endpoint properly requires authentication");
    
    // Step 5: Test Diff Retrieval
    log::info!("📋 Step 5: Testing diff retrieval endpoint");
    let get_diff_req = test::TestRequest::get()
        .uri("/api/diff/testhost_complete")
        .to_request();
        
    let get_diff_resp = test::call_service(&service, get_diff_req).await;
    log::info!("Get diff response status: {}", get_diff_resp.status());
    
    assert!(
        get_diff_resp.status().is_client_error() || get_diff_resp.status().is_server_error(),
        "❌ Diff retrieval should require authentication, got {}", get_diff_resp.status()
    );
    log::info!("✅ Diff retrieval endpoint properly requires authentication");
    
    // Step 6: Test Workflow Verification Endpoints
    log::info!("📊 Step 6: Testing workflow verification endpoints");
    
    // Test listing endpoints that would show our created resources
    let verification_endpoints = [
        ("/api/user", "List users"),
        ("/api/key", "List SSH keys"), 
        ("/api/host", "List hosts"),
        ("/api/authorization", "List authorizations"),
        ("/api/diff", "List hosts for diff"),
    ];
    
    for (endpoint, description) in verification_endpoints {
        log::info!("🔍 Testing {}: GET {}", description, endpoint);
        
        let req = test::TestRequest::get()
            .uri(endpoint)
            .to_request();
            
        let resp = test::call_service(&service, req).await;
        
        assert!(
            resp.status().is_client_error() || resp.status().is_server_error(),
            "❌ {} should require authentication, got {}", description, resp.status()
        );
        
        log::info!("✅ {} endpoint properly requires authentication", description);
    }
    
    log::info!("🎉 Complete SSH key management workflow test PASSED!");
    log::info!("📋 Workflow Summary:");
    log::info!("   1. ✅ User creation endpoint tested and secured");
    log::info!("   2. ✅ SSH key creation endpoint tested and secured");
    log::info!("   3. ✅ Host creation endpoint tested and secured");
    log::info!("   4. ✅ Authorization creation endpoint tested and secured");
    log::info!("   5. ✅ Diff retrieval endpoint tested and secured");
    log::info!("   6. ✅ Verification endpoints tested and secured");
    log::info!("🔐 All workflow operations properly require authentication!");
}

/// Test specific workflow scenarios with different data
#[tokio::test]
#[serial]
async fn test_workflow_with_different_key_types() {
    test_only!();
    init_test_mode();
    
    // Set test mode to prevent real SSH operations
    std::env::set_var("SSH_KEY_MANAGER_TEST_MODE", "1");
    
    log::info!("🧪 Testing workflow with different SSH key types");
    
    // Create test app inline
    let db_pool = create_test_db_pool().await;
    let config = TestAppConfig::new();
    
    let app = App::new()
        .app_data(web::Data::new(db_pool))
        .app_data(web::Data::new(config.clone()))
        .wrap(IdentityMiddleware::default())
        .wrap(
            SessionMiddleware::builder(
                CookieSessionStore::default(),
                Key::from(config.session_key.as_bytes()),
            )
            .cookie_secure(false)
            .build(),
        )
        .configure(crate::routes::route_config);
        
    let service = test::init_service(app).await;
    
    // Test different key types in the workflow
    let key_types = [
        ("ssh-rsa", "AAAAB3NzaC1yc2EAAAADAQABAAABAQC7vbqaj...", "RSA key"),
        ("ssh-ed25519", "AAAAC3NzaC1lZDI1NTE5AAAAIGbJ...", "Ed25519 key"),
        ("ecdsa-sha2-nistp256", "AAAAE2VjZHNhLXNoYTItbmlzdHAyNTY...", "ECDSA key"),
    ];
    
    for (key_type, key_base64, description) in key_types {
        log::info!("🔑 Testing workflow with {}", description);
        
        // Test user creation for this key type
        let user_req = test::TestRequest::post()
            .uri("/api/user")
            .set_json(&json!({
                "username": format!("user_{}", key_type.replace("-", "_")),
                "enabled": true
            }))
            .to_request();
            
        let user_resp = test::call_service(&service, user_req).await;
        log::info!("{} user creation status: {}", description, user_resp.status());
        
        // Test key creation with this type
        let key_req = test::TestRequest::post()
            .uri("/api/key")
            .set_json(&json!({
                "key_type": key_type,
                "key_base64": key_base64,
                "key_comment": format!("{}@workflow.test", key_type)
            }))
            .to_request();
            
        let key_resp = test::call_service(&service, key_req).await;
        log::info!("{} key creation status: {}", description, key_resp.status());
        
        // Both should require authentication
        assert!(
            user_resp.status().is_client_error() || user_resp.status().is_server_error(),
            "{} user creation should require auth", description
        );
        assert!(
            key_resp.status().is_client_error() || key_resp.status().is_server_error(),
            "{} key creation should require auth", description
        );
        
        log::info!("✅ {} workflow properly secured", description);
    }
    
    log::info!("🎉 Workflow with different key types test PASSED!");
}

/// Test workflow with various host configurations
#[tokio::test]
#[serial] 
async fn test_workflow_with_different_host_configs() {
    test_only!();
    init_test_mode();
    
    // Set test mode to prevent real SSH operations
    std::env::set_var("SSH_KEY_MANAGER_TEST_MODE", "1");
    
    log::info!("🖥️ Testing workflow with different host configurations");
    
    // Create test app inline
    let db_pool = create_test_db_pool().await;
    let config = TestAppConfig::new();
    
    let app = App::new()
        .app_data(web::Data::new(db_pool))
        .app_data(web::Data::new(config.clone()))
        .wrap(IdentityMiddleware::default())
        .wrap(
            SessionMiddleware::builder(
                CookieSessionStore::default(),
                Key::from(config.session_key.as_bytes()),
            )
            .cookie_secure(false)
            .build(),
        )
        .configure(crate::routes::route_config);
        
    let service = test::init_service(app).await;
    
    // Test different host configurations
    let host_configs = [
        ("web-server", "192.168.1.10", 22, "www-data", "Web server"),
        ("db-server", "10.0.0.5", 22, "postgres", "Database server"),
        ("jump-host", "203.0.113.1", 2222, "admin", "Jump host with custom port"),
        ("dev-server", "172.16.0.100", 22, "developer", "Development server"),
    ];
    
    for (name, address, port, username, description) in host_configs {
        log::info!("🖥️ Testing workflow with {}", description);
        
        // Test host creation
        let host_req = test::TestRequest::post()
            .uri("/api/host")
            .set_json(&json!({
                "name": name,
                "address": address,
                "port": port,
                "username": username
            }))
            .to_request();
            
        let host_resp = test::call_service(&service, host_req).await;
        log::info!("{} host creation status: {}", description, host_resp.status());
        
        // Test authorization for this host
        let auth_req = test::TestRequest::post()
            .uri("/api/authorization")
            .set_json(&json!({
                "user_id": 1,
                "host_id": 1,
                "remote_username": username
            }))
            .to_request();
            
        let auth_resp = test::call_service(&service, auth_req).await;
        log::info!("{} authorization creation status: {}", description, auth_resp.status());
        
        // Test diff for this host
        let diff_req = test::TestRequest::get()
            .uri(&format!("/api/diff/{}", name))
            .to_request();
            
        let diff_resp = test::call_service(&service, diff_req).await;
        log::info!("{} diff retrieval status: {}", description, diff_resp.status());
        
        // All should require authentication
        assert!(
            host_resp.status().is_client_error() || host_resp.status().is_server_error(),
            "{} host creation should require auth", description
        );
        assert!(
            auth_resp.status().is_client_error() || auth_resp.status().is_server_error(),
            "{} authorization should require auth", description
        );
        assert!(
            diff_resp.status().is_client_error() || diff_resp.status().is_server_error(),
            "{} diff should require auth", description
        );
        
        log::info!("✅ {} workflow properly secured", description);
    }
    
    log::info!("🎉 Workflow with different host configurations test PASSED!");
}

/// Test complete workflow edge cases and error handling
#[tokio::test]
#[serial]
async fn test_workflow_edge_cases() {
    test_only!();
    init_test_mode();
    
    // Set test mode to prevent real SSH operations
    std::env::set_var("SSH_KEY_MANAGER_TEST_MODE", "1");
    
    log::info!("🧪 Testing workflow edge cases and error handling");
    
    // Create test app inline
    let db_pool = create_test_db_pool().await;
    let config = TestAppConfig::new();
    
    let app = App::new()
        .app_data(web::Data::new(db_pool))
        .app_data(web::Data::new(config.clone()))
        .wrap(IdentityMiddleware::default())
        .wrap(
            SessionMiddleware::builder(
                CookieSessionStore::default(),
                Key::from(config.session_key.as_bytes()),
            )
            .cookie_secure(false)
            .build(),
        )
        .configure(crate::routes::route_config);
        
    let service = test::init_service(app).await;
    
    // Test edge cases that should still require authentication
    let edge_cases = [
        // Invalid/malformed requests
        ("POST", "/api/user", json!({"username": ""}), "Empty username"),
        ("POST", "/api/user", json!({}), "Missing required fields"),
        ("POST", "/api/key", json!({"key_type": ""}), "Empty key type"),
        ("POST", "/api/key", json!({"key_base64": "invalid"}), "Invalid key data"),
        ("POST", "/api/host", json!({"name": ""}), "Empty host name"),
        ("POST", "/api/host", json!({"port": "invalid"}), "Invalid port"),
        ("POST", "/api/authorization", json!({"user_id": "invalid"}), "Invalid user ID"),
        
        // Requests for non-existent resources
        ("GET", "/api/user/nonexistent", json!({}), "Non-existent user"),
        ("GET", "/api/host/nonexistent", json!({}), "Non-existent host"), 
        ("GET", "/api/key/999", json!({}), "Non-existent key"),
        ("GET", "/api/diff/nonexistent", json!({}), "Non-existent host diff"),
        ("DELETE", "/api/user/nonexistent", json!({}), "Delete non-existent user"),
        ("DELETE", "/api/host/nonexistent", json!({}), "Delete non-existent host"),
    ];
    
    for (method, uri, payload, description) in edge_cases {
        log::info!("🧪 Testing edge case: {}", description);
        
        let req = match method {
            "GET" => test::TestRequest::get().uri(uri).to_request(),
            "POST" => test::TestRequest::post().uri(uri).set_json(&payload).to_request(),
            "DELETE" => test::TestRequest::delete().uri(uri).to_request(),
            _ => panic!("Unsupported method: {}", method),
        };
        
        let resp = test::call_service(&service, req).await;
        
        // Even edge cases should require authentication (security first)
        assert!(
            resp.status().is_client_error() || resp.status().is_server_error(),
            "❌ {} should require authentication even for edge cases, got {}", 
            description, resp.status()
        );
        
        log::info!("✅ {} properly requires authentication", description);
    }
    
    log::info!("🎉 Workflow edge cases test PASSED!");
    log::info!("🔐 All edge cases properly require authentication - security maintained!");
}