/// HTTP Test Helpers
/// 
/// Shared utilities for HTTP API testing across all test modules.
/// Provides common functions for service creation, JSON extraction, and test setup.

use actix_web::{test, http::StatusCode};


/// Helper macro to create a test service inline (avoids trait bound issues)
#[macro_export]
macro_rules! create_inline_test_service {
    () => {{
        use crate::tests::{safety::init_test_mode, test_utils::TestConfig};
        use crate::ssh::{SshClient, CachingSshClient};
        use russh::keys::load_secret_key;
        use actix_web::{test, web, App};
        use actix_session::{SessionMiddleware, storage::CookieSessionStore};
        use actix_web::cookie::Key;
        use actix_identity::IdentityMiddleware;
        use std::sync::Arc;
        
        init_test_mode();
        let test_config = TestConfig::new().await;
        
        let test_key = load_secret_key(&test_config.config.ssh.private_key_file, None)
            .expect("Failed to load test SSH key");
            
        let ssh_client = SshClient::new(
            test_config.db_pool.clone(), 
            test_key, 
            test_config.config.ssh.clone()
        );
        
        let caching_ssh = CachingSshClient::new(
            test_config.db_pool.clone(), 
            ssh_client
        );
        
        let app = test::init_service(
            App::new()
                .app_data(web::Data::new(test_config.db_pool.clone()))
                .app_data(web::Data::new(Arc::new(test_config.config.clone())))
                .app_data(web::Data::new(caching_ssh))
                .wrap(IdentityMiddleware::default())
                .wrap(
                    SessionMiddleware::builder(
                        CookieSessionStore::default(),
                        Key::from(test_config.config.session_key.as_bytes()),
                    )
                    .cookie_secure(false)
                    .build(),
                )
                .configure(crate::routes::route_config)
        ).await;
        
        (app, test_config)
    }};
}

/// Extract JSON from an actix-web service response
pub async fn extract_json(resp: actix_web::dev::ServiceResponse) -> serde_json::Value {
    let body = test::read_body(resp).await;
    serde_json::from_slice(&body).expect("Failed to parse JSON response")
}

/// Assert that response has successful status and valid JSON structure
pub async fn assert_success_response(resp: actix_web::dev::ServiceResponse) -> serde_json::Value {
    assert_eq!(resp.status(), StatusCode::OK);
    let json = extract_json(resp).await;
    assert_eq!(json["success"], true);
    json
}

/// Assert that response has error status and valid error structure
pub async fn assert_error_response(resp: actix_web::dev::ServiceResponse, expected_status: StatusCode) -> serde_json::Value {
    assert_eq!(resp.status(), expected_status);
    let json = extract_json(resp).await;
    assert_eq!(json["success"], false);
    json
}

/// Assert that response has NOT_FOUND status with flexible error structure
pub async fn assert_not_found_response(resp: actix_web::dev::ServiceResponse) -> serde_json::Value {
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
    let json = extract_json(resp).await;
    assert_eq!(json["success"], false);
    
    // Error structure may vary - check for any error indication
    assert!(
        json["error"]["code"] == "NOT_FOUND" || 
        json["error"].is_object() ||
        json["message"].as_str().is_some(),
        "Expected error response structure"
    );
    
    json
}