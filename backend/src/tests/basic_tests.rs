/// Ultra-Basic Test - just check if we can run tests
/// 
/// Let's get ONE working test, then build from there

use actix_web::{test, web, App, http::StatusCode};
use actix_identity::IdentityMiddleware;
use actix_session::{SessionMiddleware, storage::CookieSessionStore};
use actix_web::cookie::Key;
use serial_test::serial;

use crate::{test_only, tests::{test_config::*, safety::init_test_mode}};

#[tokio::test]
#[serial]
async fn test_simple_app() {
    test_only!();
    init_test_mode();
    
    // Create test database and config
    let db_pool = create_test_db_pool().await;
    let config = TestAppConfig::new();
    
    // Create app with minimal required middleware
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
    
    // Test basic endpoint access
    let req = test::TestRequest::get()
        .uri("/api/host")
        .to_request();
    
    let resp = test::call_service(&service, req).await;
    
    // Should be unauthorized (401) which means the API is working
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
    
    log::info!("✅ Basic test passed - app works without database");
}

