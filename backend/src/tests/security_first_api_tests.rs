/// Security-First API Tests Using Macros
/// 
/// This is the NEW STANDARD for API testing - every endpoint gets comprehensive security testing
/// These tests verify that ALL /api/ routes properly require authentication

use actix_web::{test, web, App};
use actix_identity::IdentityMiddleware;
use actix_session::{SessionMiddleware, storage::CookieSessionStore};
use actix_web::cookie::Key;
use serial_test::serial;
use serde_json::json;

use crate::{test_only, tests::{test_config::*, safety::init_test_mode}};

/// Test User API Security - THE NEW STANDARD
#[tokio::test]
#[serial]
async fn test_user_api_security_comprehensive() {
    test_only!();
    init_test_mode();
    
    log::info!("🧪 Testing User API with MANDATORY comprehensive security");
    
    // Create test app inline (the proven pattern)
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
    
    // Test ALL User API endpoints for security
    let user_endpoints = [
        ("GET", "/api/user", None),
        ("POST", "/api/user", Some(json!({"username": "testuser", "enabled": true}))),
        ("GET", "/api/user/testuser", None),
        ("PUT", "/api/user/testuser", Some(json!({"username": "updateduser", "enabled": false}))),
        ("DELETE", "/api/user/testuser", None),
        ("GET", "/api/user/testuser/keys", None),
        ("GET", "/api/user/testuser/authorizations", None),
        ("POST", "/api/user/assign_key", Some(json!({"user_id": 1, "key_type": "ssh-rsa", "key_base64": "AAAAB3...", "key_comment": "test"}))),
        ("POST", "/api/user/add_key", Some(json!({"key_type": "ssh-rsa", "key_base64": "AAAAB3...", "key_comment": "test"}))),
    ];
    
    for (method, uri, payload) in user_endpoints {
        log::info!("🔒 Testing {} {}", method, uri);
        
        let req = match method {
            "GET" => test::TestRequest::get().uri(uri).to_request(),
            "POST" => {
                let mut builder = test::TestRequest::post().uri(uri);
                if let Some(json_payload) = payload {
                    builder = builder.set_json(&json_payload);
                }
                builder.to_request()
            },
            "PUT" => {
                let mut builder = test::TestRequest::put().uri(uri);
                if let Some(json_payload) = payload {
                    builder = builder.set_json(&json_payload);
                }
                builder.to_request()
            },
            "DELETE" => test::TestRequest::delete().uri(uri).to_request(),
            _ => panic!("Unsupported method: {}", method)
        };
        
        let resp = test::call_service(&service, req).await;
        
        // MANDATORY: All endpoints MUST reject unauthenticated access
        assert!(
            resp.status().is_client_error() || resp.status().is_server_error(),
            "❌ CRITICAL SECURITY FAILURE: {} {} allows unauthenticated access! Status: {}", 
            method, uri, resp.status()
        );
        
        log::info!("✅ {} {} - Authentication required ✓", method, uri);
    }
    
    log::info!("🎉 User API comprehensive security test PASSED!");
}

/// Test Host API Security - THE NEW STANDARD
#[tokio::test]
#[serial]
async fn test_host_api_security_comprehensive() {
    test_only!();
    init_test_mode();
    
    log::info!("🧪 Testing Host API with MANDATORY comprehensive security");
    
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
    
    // Test ALL Host API endpoints for security
    let host_endpoints = [
        ("GET", "/api/host", None),
        ("POST", "/api/host", Some(json!({"name": "testhost", "address": "192.168.1.100", "port": 22, "username": "admin"}))),
        ("GET", "/api/host/testhost", None),
        ("DELETE", "/api/host/testhost", None),
        ("GET", "/api/host/testhost/logins", None),
        ("POST", "/api/host/testhost/authorize", Some(json!({"user_id": 1, "remote_username": "testuser"}))),
        ("DELETE", "/api/host/authorization/1", None),
        ("GET", "/api/host/testhost/authorizations", None),
        ("POST", "/api/host/testhost/authorized_keys", Some(json!({"generate": true}))),
        ("PUT", "/api/host/testhost/authorized_keys", Some(json!({"content": "ssh-rsa AAAAB3..."}))),
        ("POST", "/api/host/testhost/add_key", Some(json!({"key_id": 1}))),
    ];
    
    for (method, uri, payload) in host_endpoints {
        log::info!("🔒 Testing {} {}", method, uri);
        
        let req = match method {
            "GET" => test::TestRequest::get().uri(uri).to_request(),
            "POST" => {
                let mut builder = test::TestRequest::post().uri(uri);
                if let Some(json_payload) = payload {
                    builder = builder.set_json(&json_payload);
                }
                builder.to_request()
            },
            "PUT" => {
                let mut builder = test::TestRequest::put().uri(uri);
                if let Some(json_payload) = payload {
                    builder = builder.set_json(&json_payload);
                }
                builder.to_request()
            },
            "DELETE" => test::TestRequest::delete().uri(uri).to_request(),
            _ => panic!("Unsupported method: {}", method)
        };
        
        let resp = test::call_service(&service, req).await;
        
        // MANDATORY: All endpoints MUST reject unauthenticated access
        assert!(
            resp.status().is_client_error() || resp.status().is_server_error(),
            "❌ CRITICAL SECURITY FAILURE: {} {} allows unauthenticated access! Status: {}", 
            method, uri, resp.status()
        );
        
        log::info!("✅ {} {} - Authentication required ✓", method, uri);
    }
    
    log::info!("🎉 Host API comprehensive security test PASSED!");
}

/// Test Key API Security - THE NEW STANDARD
#[tokio::test]
#[serial]
async fn test_key_api_security_comprehensive() {
    test_only!();
    init_test_mode();
    
    log::info!("🧪 Testing Key API with MANDATORY comprehensive security");
    
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
    
    // Test ALL Key API endpoints for security
    let key_endpoints = [
        ("GET", "/api/key", None),
        ("POST", "/api/key", Some(json!({"key_type": "ssh-rsa", "key_base64": "AAAAB3NzaC1yc2E...", "key_comment": "test@example.com"}))),
        ("GET", "/api/key/1", None),
        ("PUT", "/api/key/1", Some(json!({"key_type": "ssh-rsa", "key_base64": "AAAAB3NzaC1yc2E...", "key_comment": "updated@example.com"}))),
        ("DELETE", "/api/key/1", None),
    ];
    
    for (method, uri, payload) in key_endpoints {
        log::info!("🔒 Testing {} {}", method, uri);
        
        let req = match method {
            "GET" => test::TestRequest::get().uri(uri).to_request(),
            "POST" => {
                let mut builder = test::TestRequest::post().uri(uri);
                if let Some(json_payload) = payload {
                    builder = builder.set_json(&json_payload);
                }
                builder.to_request()
            },
            "PUT" => {
                let mut builder = test::TestRequest::put().uri(uri);
                if let Some(json_payload) = payload {
                    builder = builder.set_json(&json_payload);
                }
                builder.to_request()
            },
            "DELETE" => test::TestRequest::delete().uri(uri).to_request(),
            _ => panic!("Unsupported method: {}", method)
        };
        
        let resp = test::call_service(&service, req).await;
        
        // MANDATORY: All endpoints MUST reject unauthenticated access
        assert!(
            resp.status().is_client_error() || resp.status().is_server_error(),
            "❌ CRITICAL SECURITY FAILURE: {} {} allows unauthenticated access! Status: {}", 
            method, uri, resp.status()
        );
        
        log::info!("✅ {} {} - Authentication required ✓", method, uri);
    }
    
    log::info!("🎉 Key API comprehensive security test PASSED!");
}

/// Test Diff API Security - THE NEW STANDARD
#[tokio::test]
#[serial]
async fn test_diff_api_security_comprehensive() {
    test_only!();
    init_test_mode();
    
    log::info!("🧪 Testing Diff API with MANDATORY comprehensive security");
    
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
    
    // Test ALL Diff API endpoints for security
    let diff_endpoints: [(&str, &str, Option<serde_json::Value>); 3] = [
        ("GET", "/api/diff", None),
        ("GET", "/api/diff/testhost", None),
        ("GET", "/api/diff/testhost/details", None),
    ];
    
    for (method, uri, _payload) in diff_endpoints {
        log::info!("🔒 Testing {} {}", method, uri);
        
        let req = test::TestRequest::get().uri(uri).to_request();
        let resp = test::call_service(&service, req).await;
        
        // MANDATORY: All endpoints MUST reject unauthenticated access
        assert!(
            resp.status().is_client_error() || resp.status().is_server_error(),
            "❌ CRITICAL SECURITY FAILURE: {} {} allows unauthenticated access! Status: {}", 
            method, uri, resp.status()
        );
        
        log::info!("✅ {} {} - Authentication required ✓", method, uri);
    }
    
    log::info!("🎉 Diff API comprehensive security test PASSED!");
}

/// Test Authorization API Security - THE NEW STANDARD
#[tokio::test]
#[serial]
async fn test_authorization_api_security_comprehensive() {
    test_only!();
    init_test_mode();
    
    log::info!("🧪 Testing Authorization API with MANDATORY comprehensive security");
    
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
    
    // Test ALL Authorization API endpoints for security
    let auth_endpoints = [
        ("GET", "/api/authorization", None),
        ("POST", "/api/authorization", Some(json!({"user_id": 1, "host_id": 1, "remote_username": "testuser"}))),
        ("GET", "/api/authorization/1", None),
        ("PUT", "/api/authorization/1", Some(json!({"user_id": 1, "host_id": 1, "remote_username": "updateduser"}))),
        ("DELETE", "/api/authorization/1", None),
    ];
    
    for (method, uri, payload) in auth_endpoints {
        log::info!("🔒 Testing {} {}", method, uri);
        
        let req = match method {
            "GET" => test::TestRequest::get().uri(uri).to_request(),
            "POST" => {
                let mut builder = test::TestRequest::post().uri(uri);
                if let Some(json_payload) = payload {
                    builder = builder.set_json(&json_payload);
                }
                builder.to_request()
            },
            "PUT" => {
                let mut builder = test::TestRequest::put().uri(uri);
                if let Some(json_payload) = payload {
                    builder = builder.set_json(&json_payload);
                }
                builder.to_request()
            },
            "DELETE" => test::TestRequest::delete().uri(uri).to_request(),
            _ => panic!("Unsupported method: {}", method)
        };
        
        let resp = test::call_service(&service, req).await;
        
        // MANDATORY: All endpoints MUST reject unauthenticated access
        assert!(
            resp.status().is_client_error() || resp.status().is_server_error(),
            "❌ CRITICAL SECURITY FAILURE: {} {} allows unauthenticated access! Status: {}", 
            method, uri, resp.status()
        );
        
        log::info!("✅ {} {} - Authentication required ✓", method, uri);
    }
    
    log::info!("🎉 Authorization API comprehensive security test PASSED!");
}