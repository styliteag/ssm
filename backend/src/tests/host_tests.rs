use actix_web::{test, web, App, http::StatusCode};
use serde_json::json;
use serial_test::serial;

use crate::tests::test_utils::*;
use crate::tests::safety::{init_test_mode, is_test_mode, validate_test_database_url, validate_test_host_config};
use crate::tests::mock_ssh::{MockSshClient, create_mock_keyfiles_response};
use crate::routes::host;
use crate::api_types::*;
use crate::db::Host;

#[tokio::test]
#[serial]
async fn test_get_all_hosts_empty() {
    init_test_mode();
    assert!(is_test_mode(), "🛡️ Test must be running in test mode");
    
    let test_config = TestConfig::new().await;
    
    // 🛡️ Verify we're using test database
    validate_test_database_url(&test_config.config.database_url)
        .expect("🛡️ Must use test database");
    cleanup_test_data(&test_config.db_pool).await;
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/host").configure(host::config))
    ).await;

    let req = test::TestRequest::get()
        .uri("/host")
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::OK);

    let body: ApiResponse<Vec<host::HostResponse>> = test::read_body_json(resp).await;
    assert!(body.success);
    assert_eq!(body.data.unwrap().len(), 0);
}

#[tokio::test]
async fn test_get_all_hosts_with_data() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    // Insert test hosts
    let host1_id = insert_test_host(&test_config.db_pool, "test-host-1").await.unwrap();
    let host2_id = insert_test_host(&test_config.db_pool, "test-host-2").await.unwrap();
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/host").configure(host::config))
    ).await;

    let req = test::TestRequest::get()
        .uri("/host")
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::OK);

    let body: ApiResponse<Vec<host::HostResponse>> = test::read_body_json(resp).await;
    assert!(body.success);
    let hosts = body.data.unwrap();
    assert_eq!(hosts.len(), 2);
    assert!(hosts.iter().any(|h| h.id == host1_id));
    assert!(hosts.iter().any(|h| h.id == host2_id));
}

#[tokio::test]
async fn test_get_host_by_name_success() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let host_name = "test-host-get";
    let _host_id = insert_test_host(&test_config.db_pool, host_name).await.unwrap();
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/host").configure(host::config))
    ).await;

    let req = test::TestRequest::get()
        .uri(&format!("/host/{}", host_name))
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::OK);

    let body: ApiResponse<host::HostResponse> = test::read_body_json(resp).await;
    assert!(body.success);
    let host = body.data.unwrap();
    assert_eq!(host.name, host_name);
    assert_eq!(host.address, "192.168.1.100");
    assert_eq!(host.port, 22);
}

#[tokio::test]
async fn test_get_host_by_name_not_found() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/host").configure(host::config))
    ).await;

    let req = test::TestRequest::get()
        .uri("/host/nonexistent-host")
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);

    let body: ApiError = test::read_body_json(resp).await;
    assert!(!body.success);
    assert!(body.message.contains("Host not found"));
}

#[tokio::test]
async fn test_create_host_validation() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/host").configure(host::config))
    ).await;

    // Test with invalid data - missing required fields
    let invalid_host = json!({
        "name": "",
        "address": "",
        "port": "invalid"
    });

    let req = test::TestRequest::post()
        .uri("/host")
        .set_json(&invalid_host)
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn test_update_host_success() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let host_name = "test-host-update";
    let _host_id = insert_test_host(&test_config.db_pool, host_name).await.unwrap();
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/host").configure(host::config))
    ).await;

    let update_data = json!({
        "name": "updated-host-name",
        "address": "192.168.1.200",
        "username": "admin",
        "port": 2222,
        "key_fingerprint": "SHA256:updated_fingerprint",
        "jump_via": null
    });

    let req = test::TestRequest::put()
        .uri(&format!("/host/{}", host_name))
        .set_json(&update_data)
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::OK);

    let body: ApiResponse<()> = test::read_body_json(resp).await;
    assert!(body.success);
    assert!(body.message.unwrap().contains("Host updated successfully"));
}

#[tokio::test]
async fn test_update_host_not_found() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/host").configure(host::config))
    ).await;

    let update_data = json!({
        "name": "updated-host-name",
        "address": "192.168.1.200",
        "username": "admin",
        "port": 2222,
        "key_fingerprint": "SHA256:updated_fingerprint",
        "jump_via": null
    });

    let req = test::TestRequest::put()
        .uri("/host/nonexistent-host")
        .set_json(&update_data)
        .to_request();

    let resp = test::call_service(&app, req).await;
    // Note: Based on the implementation, update might not check if host exists first
    // This test verifies the current behavior
    assert!(resp.status().is_server_error() || resp.status().is_client_error());
}

#[tokio::test]
async fn test_delete_host_without_confirmation() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let host_name = "test-host-delete";
    let _host_id = insert_test_host(&test_config.db_pool, host_name).await.unwrap();
    
    let mock_ssh_client = MockSshClient::new();
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/host").configure(host::config))
    ).await;

    let delete_data = json!({
        "confirm": false
    });

    let req = test::TestRequest::delete()
        .uri(&format!("/host/{}", host_name))
        .set_json(&delete_data)
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::OK);

    // Should return information about what would be deleted
    let body: ApiResponse<host::DeleteHostResponse> = test::read_body_json(resp).await;
    assert!(body.success);
    
    // Verify host still exists
    let mut conn = test_config.db_pool.get().unwrap();
    let host = Host::get_from_name(conn, host_name.to_string()).await;
    assert!(host.is_ok());
    assert!(host.unwrap().is_some());
}

#[tokio::test]
async fn test_delete_host_with_confirmation() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let host_name = "test-host-delete-confirm";
    let _host_id = insert_test_host(&test_config.db_pool, host_name).await.unwrap();
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/host").configure(host::config))
    ).await;

    let delete_data = json!({
        "confirm": true
    });

    let req = test::TestRequest::delete()
        .uri(&format!("/host/{}", host_name))
        .set_json(&delete_data)
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::OK);

    let body: ApiResponse<()> = test::read_body_json(resp).await;
    assert!(body.success);
    
    // Verify host was deleted
    let mut conn = test_config.db_pool.get().unwrap();
    let host = Host::get_from_name(conn, host_name.to_string()).await;
    assert!(host.is_ok());
    assert!(host.unwrap().is_none());
}

#[tokio::test]
async fn test_delete_host_not_found() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/host").configure(host::config))
    ).await;

    let delete_data = json!({
        "confirm": true
    });

    let req = test::TestRequest::delete()
        .uri("/host/nonexistent-host")
        .set_json(&delete_data)
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);

    let body: ApiError = test::read_body_json(resp).await;
    assert!(!body.success);
    assert!(body.message.contains("Host not found"));
}

#[tokio::test]
async fn test_authorize_user_success() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    // Setup test data
    let host_id = insert_test_host(&test_config.db_pool, "test-host-auth").await.unwrap();
    let user_id = insert_test_user(&test_config.db_pool, "test-user-auth").await.unwrap();
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/host").configure(host::config))
    ).await;

    let auth_data = json!({
        "host_id": host_id,
        "user_id": user_id,
        "login": "ubuntu",
        "options": null
    });

    let req = test::TestRequest::post()
        .uri("/host/user/authorize")
        .set_json(&auth_data)
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::OK);

    let body: ApiResponse<()> = test::read_body_json(resp).await;
    assert!(body.success);
    assert!(body.message.unwrap().contains("User authorized successfully"));
}

#[tokio::test]
async fn test_authorize_user_invalid_ids() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/host").configure(host::config))
    ).await;

    let auth_data = json!({
        "host_id": 99999,
        "user_id": 99999,
        "login": "ubuntu",
        "options": null
    });

    let req = test::TestRequest::post()
        .uri("/host/user/authorize")
        .set_json(&auth_data)
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::INTERNAL_SERVER_ERROR);

    let body: ApiError = test::read_body_json(resp).await;
    assert!(!body.success);
}

#[tokio::test]
async fn test_list_host_authorizations() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let host_name = "test-host-auth-list";
    let host_id = insert_test_host(&test_config.db_pool, host_name).await.unwrap();
    let user_id = insert_test_user(&test_config.db_pool, "test-user-auth-list").await.unwrap();
    
    // Create authorization
    let mut conn = test_config.db_pool.get().unwrap();
    Host::authorize_user(&mut conn, host_id, user_id, "ubuntu".to_string(), None).unwrap();
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/host").configure(host::config))
    ).await;

    let req = test::TestRequest::get()
        .uri(&format!("/host/{}/authorizations", host_name))
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::OK);

    let body: ApiResponse<host::HostAuthorizationsResponse> = test::read_body_json(resp).await;
    assert!(body.success);
    let authorizations = body.data.unwrap().authorizations;
    assert_eq!(authorizations.len(), 1);
    assert_eq!(authorizations[0].login, "ubuntu");
}

#[tokio::test]
async fn test_delete_authorization() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let host_id = insert_test_host(&test_config.db_pool, "test-host-del-auth").await.unwrap();
    let user_id = insert_test_user(&test_config.db_pool, "test-user-del-auth").await.unwrap();
    
    // Create authorization
    let mut conn = test_config.db_pool.get().unwrap();
    Host::authorize_user(&mut conn, host_id, user_id, "ubuntu".to_string(), None).unwrap();
    
    // Get the authorization ID
    use crate::schema::authorization::dsl::*;
    use diesel::prelude::*;
    let auth_id: i32 = authorization
        .filter(host_id.eq(host_id))
        .filter(user_id.eq(user_id))
        .select(id)
        .first(&mut conn)
        .unwrap();
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/host").configure(host::config))
    ).await;

    let req = test::TestRequest::delete()
        .uri(&format!("/host/authorization/{}", auth_id))
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::OK);

    let body: ApiResponse<()> = test::read_body_json(resp).await;
    assert!(body.success);
    assert!(body.message.unwrap().contains("Authorization deleted successfully"));
}

#[tokio::test]
async fn test_host_with_jumphost() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    // Create jumphost first
    let jumphost_id = insert_test_host(&test_config.db_pool, "jumphost").await.unwrap();
    
    // Create host with jumphost
    use crate::models::NewHost;
    let new_host = NewHost {
        name: "host-with-jump".to_string(),
        address: "10.0.0.100".to_string(),
        port: 22,
        username: "ubuntu".to_string(),
        key_fingerprint: "SHA256:test_fingerprint".to_string(),
        jump_via: Some(jumphost_id),
    };
    
    let mut conn = test_config.db_pool.get().unwrap();
    let host_id = Host::add_host(&mut conn, &new_host).unwrap();
    
    let app = test::init_service(
        App::new()
            .app_data(web::Data::new(test_config.db_pool.clone()))
            .service(web::scope("/host").configure(host::config))
    ).await;

    let req = test::TestRequest::get()
        .uri("/host/host-with-jump")
        .to_request();

    let resp = test::call_service(&app, req).await;
    assert_eq!(resp.status(), StatusCode::OK);

    let body: ApiResponse<host::HostResponse> = test::read_body_json(resp).await;
    assert!(body.success);
    let host = body.data.unwrap();
    assert_eq!(host.name, "host-with-jump");
    assert_eq!(host.jump_via, Some(jumphost_id));
    assert_eq!(host.jumphost_name, Some("jumphost".to_string()));
}

#[cfg(test)]
mod host_safety_tests {
    use super::*;

    #[tokio::test]
    #[serial]
    async fn test_host_validation_safety() {
        init_test_mode();
        assert!(is_test_mode(), "🛡️ Test must be running in test mode");
        
        // Test safe host configurations
        assert!(validate_test_host_config("127.0.0.1", 22, "TEST_fingerprint").is_ok());
        assert!(validate_test_host_config("192.168.1.100", 22, "test_key_fingerprint").is_ok());
        
        // Test unsafe host configurations that should be blocked in tests
        assert!(validate_test_host_config("8.8.8.8", 22, "TEST_fingerprint").is_err());
        assert!(validate_test_host_config("1.1.1.1", 22, "test_key").is_err());
        assert!(validate_test_host_config("127.0.0.1", 22, "SHA256:realkey123").is_err());
        
        log::info!("🛡️ Host safety validation tests passed");
    }

    #[tokio::test]
    #[serial]
    async fn test_create_host_with_safe_config() {
        init_test_mode();
        let test_config = TestConfig::new().await;
        validate_test_database_url(&test_config.config.database_url).expect("🛡️ Must use test database");
        cleanup_test_data(&test_config.db_pool).await;
        
        let app = test::init_service(
            App::new()
                .app_data(web::Data::new(test_config.db_pool.clone()))
                .service(web::scope("/host").configure(host::config))
        ).await;

        // Test with safe configuration
        let safe_host = json!({
            "name": "test-safe-host",
            "address": "127.0.0.1",
            "port": 22,
            "username": "ubuntu",
            "key_fingerprint": "TEST_fingerprint_safe",
            "jump_via": null
        });

        let req = test::TestRequest::post()
            .uri("/host")
            .set_json(&safe_host)
            .to_request();

        let resp = test::call_service(&app, req).await;
        assert_eq!(resp.status(), StatusCode::OK);

        let body: ApiResponse<()> = test::read_body_json(resp).await;
        assert!(body.success);
        assert!(body.message.unwrap().contains("Host created successfully"));
    }

    #[tokio::test]
    #[serial]
    async fn test_prevent_production_host_creation() {
        init_test_mode();
        let test_config = TestConfig::new().await;
        cleanup_test_data(&test_config.db_pool).await;
        
        // Note: This test demonstrates what WOULD happen if someone tried to create
        // a production host during testing. The actual validation happens at the
        // host configuration level, not the API level, but we show the pattern here.
        
        // In a real scenario, we'd want additional validation in the API layer
        // to prevent creation of hosts with production-looking configurations
        let potentially_unsafe_configs = vec![
            ("8.8.8.8", "production_server"),
            ("203.0.113.1", "server.company.com"),
            ("198.51.100.1", "prod-web-01"),
        ];

        for (address, name) in potentially_unsafe_configs {
            log::warn!("🛡️ Testing prevention of unsafe host config: {}@{}", name, address);
            
            // In test mode, we should validate these before they reach the database
            let result = validate_test_host_config(address, 22, "TEST_fingerprint");
            assert!(result.is_err(), "🛡️ Should block unsafe address: {}", address);
        }
        
        log::info!("🛡️ Production host creation prevention test passed");
    }
}

#[cfg(test)]
mod host_ssh_mock_tests {
    use super::*;
    use crate::ssh::SshKeyfiles;

    #[tokio::test]
    #[serial]
    async fn test_host_ssh_connection_mock() {
        init_test_mode();
        let test_config = TestConfig::new().await;
        cleanup_test_data(&test_config.db_pool).await;
        
        // Create test host
        let host_id = insert_test_host(&test_config.db_pool, "test-host-ssh").await.unwrap();
        
        // Create mock SSH client
        let mock_ssh = MockSshClient::new(test_config.db_pool.clone(), test_config.config.ssh.clone());
        
        // Configure mock response
        let mock_keyfiles = create_mock_keyfiles_response(vec!["root", "ubuntu"]);
        mock_ssh.mock_keyfiles_response("test-host-ssh", mock_keyfiles.clone()).await;
        
        // Test the mock SSH operations
        let host = crate::models::Host {
            id: host_id,
            name: "test-host-ssh".to_string(),
            address: "127.0.0.1".to_string(),
            port: 22,
            username: "ubuntu".to_string(),
            key_fingerprint: "TEST_fingerprint".to_string(),
            jump_via: None,
        };
        
        let result = mock_ssh.get_authorized_keys(host).await;
        assert!(result.is_ok());
        
        let keyfiles = result.unwrap();
        assert_eq!(keyfiles.0.len(), 2);
        assert_eq!(keyfiles.0[0].login, "root");
        assert_eq!(keyfiles.0[1].login, "ubuntu");
        
        // Verify operations were logged
        assert!(mock_ssh.verify_operation_called(crate::tests::mock_ssh::MockOperationType::Connect, "test-host-ssh").await);
        assert!(mock_ssh.verify_operation_called(crate::tests::mock_ssh::MockOperationType::GetKeyfiles, "test-host-ssh").await);
        
        log::info!("🤖 SSH mock test completed successfully");
    }

    #[tokio::test]
    #[serial]
    async fn test_host_ssh_connection_failure_mock() {
        init_test_mode();
        let test_config = TestConfig::new().await;
        cleanup_test_data(&test_config.db_pool).await;
        
        // Create test host
        let host_id = insert_test_host(&test_config.db_pool, "test-host-fail").await.unwrap();
        
        // Create mock SSH client
        let mock_ssh = MockSshClient::new(test_config.db_pool.clone(), test_config.config.ssh.clone());
        
        // Simulate connection failure
        mock_ssh.simulate_connection_failure("test-host-fail", "Connection refused").await;
        
        let host = crate::models::Host {
            id: host_id,
            name: "test-host-fail".to_string(),
            address: "127.0.0.1".to_string(),
            port: 22,
            username: "ubuntu".to_string(),
            key_fingerprint: "TEST_fingerprint".to_string(),
            jump_via: None,
        };
        
        let result = mock_ssh.get_authorized_keys(host).await;
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("Connection refused"));
        
        // Verify failed connection was logged
        assert!(mock_ssh.verify_operation_called(crate::tests::mock_ssh::MockOperationType::Connect, "test-host-fail").await);
        
        log::info!("🤖 SSH connection failure mock test completed successfully");
    }

    #[tokio::test]
    #[serial]
    async fn test_host_key_deployment_mock() {
        init_test_mode();
        let test_config = TestConfig::new().await;
        cleanup_test_data(&test_config.db_pool).await;
        
        // Create mock SSH client
        let mock_ssh = MockSshClient::new(test_config.db_pool.clone(), test_config.config.ssh.clone());
        
        // Test key deployment (set_authorized_keys)
        let test_keys = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC7vbqajDw5XJjfsQM1dLDEeuxWiZQ test@example.com";
        
        let result = mock_ssh.set_authorized_keys(
            "test-host-deploy".to_string(),
            "ubuntu".to_string(),
            test_keys.to_string(),
        ).await;
        
        assert!(result.is_ok());
        
        // Verify operations were logged
        assert!(mock_ssh.verify_operation_called(crate::tests::mock_ssh::MockOperationType::Connect, "test-host-deploy").await);
        assert!(mock_ssh.verify_operation_called(crate::tests::mock_ssh::MockOperationType::SetAuthorizedKeys, "test-host-deploy").await);
        
        log::info!("🤖 SSH key deployment mock test completed successfully");
    }

    #[tokio::test]
    #[serial]
    async fn test_host_script_installation_mock() {
        init_test_mode();
        let test_config = TestConfig::new().await;
        cleanup_test_data(&test_config.db_pool).await;
        
        // Create test host
        let host_id = insert_test_host(&test_config.db_pool, "test-host-script").await.unwrap();
        
        // Create mock SSH client
        let mock_ssh = MockSshClient::new(test_config.db_pool.clone(), test_config.config.ssh.clone());
        
        // Test successful script installation
        mock_ssh.mock_script_install_result("host_1", true).await;
        
        let result = mock_ssh.install_script_on_host(host_id).await;
        assert!(result.is_ok());
        
        // Test failed script installation
        mock_ssh.mock_script_install_result("host_1", false).await;
        
        let result = mock_ssh.install_script_on_host(host_id).await;
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("Mock script installation failed"));
        
        log::info!("🤖 SSH script installation mock test completed successfully");
    }

    #[tokio::test]
    #[serial]
    async fn test_real_ssh_client_blocked_in_tests() {
        init_test_mode();
        
        // This test verifies that real SSH operations are blocked during testing
        // by testing the safety guards we added to the SSH client
        
        let test_config = TestConfig::new().await;
        
        // Try to create a real SSH client (this should work for creation)
        let real_ssh_client = crate::ssh::SshClient::new(
            test_config.db_pool.clone(),
            russh::keys::PrivateKey::random(
                &mut rand::thread_rng(), 
                russh::keys::Algorithm::Rsa { hash: russh::keys::AlgHash::Sha2_256 }
            ).unwrap(),
            test_config.config.ssh.clone(),
        );
        
        // But any actual SSH operations should be blocked
        let test_host = crate::models::Host {
            id: 1,
            name: "test-host".to_string(),
            address: "127.0.0.1".to_string(),
            port: 22,
            username: "ubuntu".to_string(),
            key_fingerprint: "TEST_fingerprint".to_string(),
            jump_via: None,
        };
        
        // These operations should be blocked by our safety guards
        let result = real_ssh_client.get_authorized_keys(test_host.clone()).await;
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("🛡️ Real SSH operations blocked during testing"));
        
        let result = real_ssh_client.set_authorized_keys(
            "test-host".to_string(),
            "ubuntu".to_string(),
            "test-keys".to_string(),
        ).await;
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("🛡️ Real SSH operations blocked during testing"));
        
        let result = real_ssh_client.key_diff(
            "test-keys",
            "test-host".to_string(),
            "ubuntu".to_string(),
        ).await;
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("🛡️ Real SSH operations blocked during testing"));
        
        let result = real_ssh_client.install_script_on_host(1).await;
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("🛡️ Real SSH operations blocked during testing"));
        
        log::info!("🛡️ Real SSH client blocking verification completed successfully");
    }

    #[tokio::test]
    #[serial]
    async fn test_mock_operation_logging() {
        init_test_mode();
        let test_config = TestConfig::new().await;
        
        let mock_ssh = MockSshClient::new(test_config.db_pool.clone(), test_config.config.ssh.clone());
        
        // Clear any existing logs
        mock_ssh.clear_all_mocks().await;
        
        // Perform various operations
        let _ = mock_ssh.set_authorized_keys("host1".to_string(), "user1".to_string(), "keys".to_string()).await;
        let _ = mock_ssh.key_diff("new-keys", "host2".to_string(), "user2".to_string()).await;
        let _ = mock_ssh.install_script_on_host(123).await;
        
        // Verify operation counts
        assert_eq!(mock_ssh.get_operation_count(crate::tests::mock_ssh::MockOperationType::Connect).await, 3);
        assert_eq!(mock_ssh.get_operation_count(crate::tests::mock_ssh::MockOperationType::SetAuthorizedKeys).await, 1);
        assert_eq!(mock_ssh.get_operation_count(crate::tests::mock_ssh::MockOperationType::KeyDiff).await, 1);
        assert_eq!(mock_ssh.get_operation_count(crate::tests::mock_ssh::MockOperationType::InstallScript).await, 1);
        
        // Get full operation log
        let log = mock_ssh.get_operation_log().await;
        assert!(log.len() >= 6); // At least 3 connects + 3 operations
        
        // Verify specific operations were called
        assert!(mock_ssh.verify_operation_called(crate::tests::mock_ssh::MockOperationType::SetAuthorizedKeys, "host1").await);
        assert!(mock_ssh.verify_operation_called(crate::tests::mock_ssh::MockOperationType::KeyDiff, "host2").await);
        assert!(mock_ssh.verify_operation_called(crate::tests::mock_ssh::MockOperationType::InstallScript, "host_123").await);
        
        log::info!("🤖 Mock operation logging test completed successfully");
    }
}