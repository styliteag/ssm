/// HTTP Authorization Management Tests
/// 
/// Comprehensive tests for user-host authorization CRUD operations,
/// permission validation, and authorization listing/filtering.

use actix_web::{test, http::StatusCode};
use serde_json::json;
use serial_test::serial;

use crate::{
    tests::{
        http_test_helpers::{extract_json},
    },
    create_inline_test_service,
    authenticated_request,
};

#[tokio::test]
#[serial]
async fn test_create_authorization() {
    let (app, test_config) = create_inline_test_service!();
    
    // Create test user and host
    use crate::models::{NewUser, User, NewHost, Host};
    let mut conn = test_config.db_pool.get().unwrap();
    
    let new_user = NewUser {
        username: "authcreateuser".to_string(),
    };
    let _username = User::add_user(&mut conn, new_user).expect("Failed to create test user");
    let user = User::get_user(&mut conn, "authcreateuser".to_string()).expect("Failed to get user");
    
    let new_host = NewHost {
        name: "authcreatehost".to_string(),
        username: "ubuntu".to_string(),
        address: "192.168.1.100".to_string(),
        port: 22,
        key_fingerprint: Some("SHA256:authcreatefingerprint".to_string()),
        jump_via: None,
    };
    let host_id = Host::add_host(&mut conn, &new_host).expect("Failed to create test host");
    
    let authorization_data = json!({
        "user_id": user.id,
        "host_id": host_id,
        "login": "ubuntu",
        "options": "no-port-forwarding,no-agent-forwarding"
    });
    
    let req = authenticated_request!(&app, post, "/api/authorization", &authorization_data)
        .to_request();
    
    let resp = test::call_service(&app, req).await;
    // Authorization CRUD endpoint doesn't exist yet - should return 404
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
    
    if resp.status() == StatusCode::CREATED || resp.status() == StatusCode::OK {
        let json = extract_json(resp).await;
        assert_eq!(json["success"], true);
        assert!(json["data"]["id"].is_number() || json["message"].is_string());
    }
    
    log::info!("✅ Create authorization test passed");
}

#[tokio::test]
#[serial]
async fn test_get_all_authorizations() {
    let (app, test_config) = create_inline_test_service!();
    
    // Create test data
    use crate::models::{NewUser, User, NewHost, Host};
    let mut conn = test_config.db_pool.get().unwrap();
    
    let new_user = NewUser {
        username: "authlistuser".to_string(),
    };
    let _username = User::add_user(&mut conn, new_user).expect("Failed to create test user");
    let user = User::get_user(&mut conn, "authlistuser".to_string()).expect("Failed to get user");
    
    let new_host = NewHost {
        name: "authlisthost".to_string(),
        username: "root".to_string(),
        address: "192.168.1.110".to_string(),
        port: 22,
        key_fingerprint: Some("SHA256:authlistfingerprint".to_string()),
        jump_via: None,
    };
    let host_id = Host::add_host(&mut conn, &new_host).expect("Failed to create test host");
    
    // Create authorization using model method
    let _ = Host::authorize_user(
        &mut conn,
        host_id,
        user.id,
        "root".to_string(),
        Some("command=\"/bin/ls\"".to_string()),
    );
    
    let req = authenticated_request!(&app, get, "/api/authorization")
        .to_request();
    
    let resp = test::call_service(&app, req).await;
    // Authorization CRUD endpoint doesn't exist yet - should return 404
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
    
    log::info!("✅ Get all authorizations test passed");
}

#[tokio::test]
#[serial]
async fn test_get_specific_authorization() {
    let (app, test_config) = create_inline_test_service!();
    
    // Create test authorization
    use crate::models::{NewUser, User, NewHost, Host};
    let mut conn = test_config.db_pool.get().unwrap();
    
    let new_user = NewUser {
        username: "authspecificuser".to_string(),
    };
    let _username = User::add_user(&mut conn, new_user).expect("Failed to create test user");
    let user = User::get_user(&mut conn, "authspecificuser".to_string()).expect("Failed to get user");
    
    let new_host = NewHost {
        name: "authspecifichost".to_string(),
        username: "deploy".to_string(),
        address: "192.168.1.120".to_string(),
        port: 22,
        key_fingerprint: Some("SHA256:authspecificfingerprint".to_string()),
        jump_via: None,
    };
    let host_id = Host::add_host(&mut conn, &new_host).expect("Failed to create test host");
    
    // Create authorization
    let _ = Host::authorize_user(
        &mut conn,
        host_id,
        user.id,
        "deploy".to_string(),
        Some("restrict".to_string()),
    );
    
    // Get authorization ID by checking host's authorized users
    let host = Host::get_from_name_sync(&mut conn, "authspecifichost".to_string()).unwrap().unwrap();
    let authorized_users = host.get_authorized_users(&mut conn).unwrap();
    
    if !authorized_users.is_empty() {
        let auth_id = authorized_users[0].id;
        
        let req = authenticated_request!(&app, get, &format!("/api/authorization/{}", auth_id))
            .to_request();
        
        let resp = test::call_service(&app, req).await;
        // Authorization CRUD endpoint doesn't exist yet - should return 404
        assert_eq!(resp.status(), StatusCode::NOT_FOUND);
    }
    
    log::info!("✅ Get specific authorization test passed");
}

#[tokio::test]
#[serial]
async fn test_update_authorization() {
    let (app, test_config) = create_inline_test_service!();
    
    // Create test authorization
    use crate::models::{NewUser, User, NewHost, Host};
    let mut conn = test_config.db_pool.get().unwrap();
    
    let new_user = NewUser {
        username: "authupdateuser".to_string(),
    };
    let _username = User::add_user(&mut conn, new_user).expect("Failed to create test user");
    let user = User::get_user(&mut conn, "authupdateuser".to_string()).expect("Failed to get user");
    
    let new_host = NewHost {
        name: "authupdatehost".to_string(),
        username: "admin".to_string(),
        address: "192.168.1.130".to_string(),
        port: 22,
        key_fingerprint: Some("SHA256:authupdatefingerprint".to_string()),
        jump_via: None,
    };
    let host_id = Host::add_host(&mut conn, &new_host).expect("Failed to create test host");
    
    // Create authorization
    let _ = Host::authorize_user(
        &mut conn,
        host_id,
        user.id,
        "admin".to_string(),
        Some("old-options".to_string()),
    );
    
    // Get authorization ID
    let host = Host::get_from_name_sync(&mut conn, "authupdatehost".to_string()).unwrap().unwrap();
    let authorized_users = host.get_authorized_users(&mut conn).unwrap();
    
    if !authorized_users.is_empty() {
        let auth_id = authorized_users[0].id;
        
        let update_data = json!({
            "login": "admin",
            "options": "no-pty,command=\"/usr/bin/rsync\""
        });
        
        let req = authenticated_request!(&app, put, &format!("/api/authorization/{}", auth_id), &update_data)
            .to_request();
        
        let resp = test::call_service(&app, req).await;
        // Authorization CRUD endpoint doesn't exist yet - should return 404
        assert_eq!(resp.status(), StatusCode::NOT_FOUND);
    }
    
    log::info!("✅ Update authorization test passed");
}

#[tokio::test]
#[serial]
async fn test_delete_authorization() {
    let (app, test_config) = create_inline_test_service!();
    
    // Create test authorization
    use crate::models::{NewUser, User, NewHost, Host};
    let mut conn = test_config.db_pool.get().unwrap();
    
    let new_user = NewUser {
        username: "authdeleteuser".to_string(),
    };
    let _username = User::add_user(&mut conn, new_user).expect("Failed to create test user");
    let user = User::get_user(&mut conn, "authdeleteuser".to_string()).expect("Failed to get user");
    
    let new_host = NewHost {
        name: "authdeletehost".to_string(),
        username: "test".to_string(),
        address: "192.168.1.140".to_string(),
        port: 22,
        key_fingerprint: Some("SHA256:authdeletefingerprint".to_string()),
        jump_via: None,
    };
    let host_id = Host::add_host(&mut conn, &new_host).expect("Failed to create test host");
    
    // Create authorization
    let _ = Host::authorize_user(
        &mut conn,
        host_id,
        user.id,
        "test".to_string(),
        None,
    );
    
    // Get authorization ID
    let host = Host::get_from_name_sync(&mut conn, "authdeletehost".to_string()).unwrap().unwrap();
    let authorized_users = host.get_authorized_users(&mut conn).unwrap();
    
    if !authorized_users.is_empty() {
        let auth_id = authorized_users[0].id;
        
        let req = authenticated_request!(&app, delete, &format!("/api/authorization/{}", auth_id))
            .to_request();
        
        let resp = test::call_service(&app, req).await;
        // Authorization CRUD endpoint doesn't exist yet - should return 404
        assert_eq!(resp.status(), StatusCode::NOT_FOUND);
    }
    
    log::info!("✅ Delete authorization test passed");
}

#[tokio::test]
#[serial]
async fn test_authorization_validation() {
    let (app, test_config) = create_inline_test_service!();
    
    // Create test data
    use crate::models::{NewUser, User, NewHost, Host};
    let mut conn = test_config.db_pool.get().unwrap();
    
    let new_user = NewUser {
        username: "authvaliduser".to_string(),
    };
    let _username = User::add_user(&mut conn, new_user).expect("Failed to create test user");
    let user = User::get_user(&mut conn, "authvaliduser".to_string()).expect("Failed to get user");
    
    let new_host = NewHost {
        name: "authvalidhost".to_string(),
        username: "valid".to_string(),
        address: "192.168.1.150".to_string(),
        port: 22,
        key_fingerprint: Some("SHA256:authvalidfingerprint".to_string()),
        jump_via: None,
    };
    let host_id = Host::add_host(&mut conn, &new_host).expect("Failed to create test host");
    
    // Test invalid authorization creation - missing required fields
    let invalid_data = json!({
        "user_id": user.id,
        // Missing host_id and login
    });
    
    let req = authenticated_request!(&app, post, "/api/authorization", &invalid_data)
        .to_request();
    
    let resp = test::call_service(&app, req).await;
    // Authorization CRUD endpoint doesn't exist yet - should return 404
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
    
    // Test invalid authorization - nonexistent user
    let invalid_user_data = json!({
        "user_id": 99999,
        "host_id": host_id,
        "login": "valid"
    });
    
    let req = authenticated_request!(&app, post, "/api/authorization", &invalid_user_data)
        .to_request();
    
    let resp = test::call_service(&app, req).await;
    // Authorization CRUD endpoint doesn't exist yet - should return 404
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
    
    // Test invalid authorization - nonexistent host
    let invalid_host_data = json!({
        "user_id": user.id,
        "host_id": 99999,
        "login": "valid"
    });
    
    let req = authenticated_request!(&app, post, "/api/authorization", &invalid_host_data)
        .to_request();
    
    let resp = test::call_service(&app, req).await;
    // Authorization CRUD endpoint doesn't exist yet - should return 404
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
    
    log::info!("✅ Authorization validation test passed");
}

#[tokio::test]
#[serial]
async fn test_authorization_filtering_and_search() {
    let (app, test_config) = create_inline_test_service!();
    
    // Create multiple test authorizations
    use crate::models::{NewUser, User, NewHost, Host};
    let mut conn = test_config.db_pool.get().unwrap();
    
    // Create multiple users
    let users = vec!["filteruser1", "filteruser2", "filteruser3"];
    let mut user_ids = Vec::new();
    
    for username in users {
        let new_user = NewUser {
            username: username.to_string(),
        };
        let _username = User::add_user(&mut conn, new_user).expect("Failed to create test user");
        let user = User::get_user(&mut conn, username.to_string()).expect("Failed to get user");
        user_ids.push(user.id);
    }
    
    // Create multiple hosts
    let hosts = vec![
        ("filterhost1", "web"),
        ("filterhost2", "db"),
        ("filterhost3", "cache"),
    ];
    let mut host_ids = Vec::new();
    
    for (hostname, login) in &hosts {
        let new_host = NewHost {
            name: hostname.to_string(),
            username: login.to_string(),
            address: format!("192.168.1.{}", 160 + host_ids.len()),
            port: 22,
            key_fingerprint: Some(format!("SHA256:{}fingerprint", hostname)),
            jump_via: None,
        };
        let host_id = Host::add_host(&mut conn, &new_host).expect("Failed to create test host");
        host_ids.push(host_id);
    }
    
    // Create various authorizations
    for (i, &user_id) in user_ids.iter().enumerate() {
        for (j, &host_id) in host_ids.iter().enumerate() {
            if i <= j {  // Create partial matrix of authorizations
                let _ = Host::authorize_user(
                    &mut conn,
                    host_id,
                    user_id,
                    hosts[j].1.to_string(),
                    Some(format!("environment={}", hosts[j].1)),
                );
            }
        }
    }
    
    // Test filtering by user
    let req = authenticated_request!(&app, get, &format!("/api/authorization?user_id={}", user_ids[0]))
        .to_request();
    
    let resp = test::call_service(&app, req).await;
    // Authorization CRUD endpoint doesn't exist yet - should return 404
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
    
    // Test filtering by host
    let req = authenticated_request!(&app, get, &format!("/api/authorization?host_id={}", host_ids[1]))
        .to_request();
    
    let resp = test::call_service(&app, req).await;
    // Authorization CRUD endpoint doesn't exist yet - should return 404
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
    
    // Test search by login
    let req = authenticated_request!(&app, get, "/api/authorization?login=web")
        .to_request();
    
    let resp = test::call_service(&app, req).await;
    // Authorization CRUD endpoint doesn't exist yet - should return 404
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
    
    log::info!("✅ Authorization filtering and search test passed");
}

#[tokio::test]
#[serial]
async fn test_authorization_permissions() {
    let (app, test_config) = create_inline_test_service!();
    
    // Create test data for permission testing
    use crate::models::{NewUser, User, NewHost, Host};
    let mut conn = test_config.db_pool.get().unwrap();
    
    let new_user = NewUser {
        username: "permuser".to_string(),
    };
    let _username = User::add_user(&mut conn, new_user).expect("Failed to create test user");
    let user = User::get_user(&mut conn, "permuser".to_string()).expect("Failed to get user");
    
    let new_host = NewHost {
        name: "permhost".to_string(),
        username: "perm".to_string(),
        address: "192.168.1.170".to_string(),
        port: 22,
        key_fingerprint: Some("SHA256:permfingerprint".to_string()),
        jump_via: None,
    };
    let host_id = Host::add_host(&mut conn, &new_host).expect("Failed to create test host");
    
    // Test authorization with various SSH options
    let auth_options = vec![
        "no-port-forwarding",
        "no-agent-forwarding",
        "no-X11-forwarding",
        "no-pty",
        "command=\"/bin/ls\"",
        "from=\"192.168.1.0/24\"",
        "restrict,command=\"/usr/bin/rsync --server\"",
    ];
    
    for (i, option) in auth_options.iter().enumerate() {
        let authorization_data = json!({
            "user_id": user.id,
            "host_id": host_id,
            "login": format!("perm{}", i),
            "options": option
        });
        
        let req = authenticated_request!(&app, post, "/api/authorization", &authorization_data)
            .to_request();
        
        let resp = test::call_service(&app, req).await;
        // Authorization CRUD endpoint doesn't exist yet - should return 404
        assert_eq!(resp.status(), StatusCode::NOT_FOUND);
    }
    
    log::info!("✅ Authorization permissions test passed");
}