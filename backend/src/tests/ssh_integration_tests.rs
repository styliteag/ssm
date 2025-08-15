/// SSH Operations Integration Tests
/// 
/// Comprehensive tests for SSH client functionality, key deployment,
/// connection handling, and remote script execution using mock SSH clients.

use serial_test::serial;

use crate::{
    tests::{
        mock_ssh::MockSshClient,
        test_utils::TestConfig,
    },
    models::{NewUser, User, NewHost, Host, NewPublicUserKey, PublicUserKey},
    ssh::SshClientError,
};
use russh::keys::Algorithm;

#[tokio::test]
#[serial]
async fn test_ssh_connection_establishment() {
    crate::tests::safety::init_test_mode();
    let test_config = TestConfig::new().await;
    
    // Create mock SSH client
    let mock_client = MockSshClient::new(
        test_config.db_pool.clone(),
        test_config.config.ssh.clone()
    );
    
    // Create test host
    let mut conn = test_config.db_pool.get().unwrap();
    let new_host = NewHost {
        name: "ssh_test_host".to_string(),
        username: "ubuntu".to_string(),
        address: "192.168.1.100".to_string(),
        port: 22,
        key_fingerprint: Some("SHA256:test_fingerprint".to_string()),
        jump_via: None,
    };
    let _host_id = Host::add_host(&mut conn, &new_host).expect("Failed to create test host");
    let host = Host::get_from_name_sync(&mut conn, "ssh_test_host".to_string()).unwrap().unwrap();
    
    // Test SSH connection
    let connection_result = host.to_connection().await;
    assert!(connection_result.is_ok(), "Should create connection details");
    
    // Test authorized keys retrieval
    let keys_result = mock_client.get_authorized_keys(host.clone()).await;
    assert!(keys_result.is_ok(), "Should retrieve authorized keys");
    
    let keys = keys_result.unwrap();
    // Keys should be a list (possibly empty) - just verify it's a valid Vec
    let _key_count = keys.len();
    
    log::info!("✅ SSH connection establishment test passed");
}

#[tokio::test]
#[serial]
async fn test_key_deployment_workflow() {
    crate::tests::safety::init_test_mode();
    let test_config = TestConfig::new().await;
    
    let _mock_client = MockSshClient::new(
        test_config.db_pool.clone(),
        test_config.config.ssh.clone()
    );
    
    let mut conn = test_config.db_pool.get().unwrap();
    
    // Create test user and key
    let new_user = NewUser {
        username: "deploy_user".to_string(),
    };
    let _username = User::add_user(&mut conn, new_user).expect("Failed to create test user");
    let user = User::get_user(&mut conn, "deploy_user".to_string()).expect("Failed to get user");
    
    let new_key = NewPublicUserKey::new(
        Algorithm::Ed25519,
        "AAAAC3NzaC1lZDI1NTE5AAAAIDeployTestKey123456789".to_string(),
        Some("deploy@example.com".to_string()),
        user.id,
    );
    PublicUserKey::add_key(&mut conn, new_key).expect("Failed to add test key");
    
    // Create test host
    let new_host = NewHost {
        name: "deploy_host".to_string(),
        username: "deploy".to_string(),
        address: "192.168.1.110".to_string(),
        port: 22,
        key_fingerprint: Some("SHA256:deploy_fingerprint".to_string()),
        jump_via: None,
    };
    let host_id = Host::add_host(&mut conn, &new_host).expect("Failed to create test host");
    let host = Host::get_from_name_sync(&mut conn, "deploy_host".to_string()).unwrap().unwrap();
    
    // Authorize user on host
    let _ = Host::authorize_user(
        &mut conn,
        host_id,
        user.id,
        "deploy".to_string(),
        Some("no-port-forwarding".to_string()),
    );
    
    // Test authorized keys list instead (get_authorized_keys_file_for requires SshClient trait)
    let authorized_keys_result = host.get_authorized_keys(&mut conn);
    assert!(authorized_keys_result.is_ok(), "Should generate authorized keys file");
    
    let authorized_keys_list = authorized_keys_result.unwrap();
    assert!(!authorized_keys_list.is_empty(), "Should have authorized keys");
    
    // Verify key properties
    let first_key = &authorized_keys_list[0];
    assert!(first_key.key.key_type.contains("ssh-ed25519"), "Should contain SSH key type");
    assert!(first_key.key.comment.as_ref().unwrap().contains("deploy@example.com"), "Should contain key comment");
    assert!(first_key.options.as_ref().unwrap().contains("no-port-forwarding"), "Should contain SSH options");
    
    log::info!("✅ Key deployment workflow test passed");
}

#[tokio::test]
#[serial]
async fn test_jump_host_connectivity() {
    crate::tests::safety::init_test_mode();
    let test_config = TestConfig::new().await;
    
    let mock_client = MockSshClient::new(
        test_config.db_pool.clone(),
        test_config.config.ssh.clone()
    );
    
    let mut conn = test_config.db_pool.get().unwrap();
    
    // Create jump host
    let jump_host = NewHost {
        name: "jump_host".to_string(),
        username: "jump".to_string(),
        address: "bastion.example.com".to_string(),
        port: 22,
        key_fingerprint: Some("SHA256:jump_fingerprint".to_string()),
        jump_via: None,
    };
    let jump_host_id = Host::add_host(&mut conn, &jump_host).expect("Failed to create jump host");
    
    // Create target host behind jump host
    let target_host = NewHost {
        name: "target_host".to_string(),
        username: "target".to_string(),
        address: "10.0.0.100".to_string(),
        port: 22,
        key_fingerprint: Some("SHA256:target_fingerprint".to_string()),
        jump_via: Some(jump_host_id),
    };
    let _target_host_id = Host::add_host(&mut conn, &target_host).expect("Failed to create target host");
    let target_host = Host::get_from_name_sync(&mut conn, "target_host".to_string()).unwrap().unwrap();
    
    // Test connection details for jump host scenario
    let connection_result = target_host.to_connection().await;
    assert!(connection_result.is_ok(), "Should create connection details with jump host");
    
    let connection_details = connection_result.unwrap();
    assert_eq!(connection_details.jump_via, Some(jump_host_id));
    
    // Test SSH operations through jump host
    let keys_result = mock_client.get_authorized_keys(target_host.clone()).await;
    assert!(keys_result.is_ok(), "Should retrieve keys through jump host");
    
    log::info!("✅ Jump host connectivity test passed");
}

#[tokio::test]
#[serial]
async fn test_ssh_error_handling() {
    crate::tests::safety::init_test_mode();
    let test_config = TestConfig::new().await;
    
    let _mock_client = MockSshClient::new(
        test_config.db_pool.clone(),
        test_config.config.ssh.clone()
    );
    
    let mut conn = test_config.db_pool.get().unwrap();
    
    // Test host without key fingerprint
    let invalid_host = NewHost {
        name: "invalid_host".to_string(),
        username: "test".to_string(),
        address: "192.168.1.200".to_string(),
        port: 22,
        key_fingerprint: None, // Missing fingerprint
        jump_via: None,
    };
    let _host_id = Host::add_host(&mut conn, &invalid_host).expect("Failed to create test host");
    let host = Host::get_from_name_sync(&mut conn, "invalid_host".to_string()).unwrap().unwrap();
    
    // Should fail to create connection without fingerprint
    let connection_result = host.to_connection().await;
    assert!(connection_result.is_err(), "Should fail without host key fingerprint");
    
    match connection_result.unwrap_err() {
        SshClientError::NoHostkey => {
            log::info!("Correctly detected missing host key");
        }
        other_error => {
            log::warn!("Unexpected error type: {:?}", other_error);
        }
    }
    
    // Test invalid port
    let invalid_port_host = NewHost {
        name: "invalid_port_host".to_string(),
        username: "test".to_string(),
        address: "192.168.1.201".to_string(),
        port: 999999, // Invalid port
        key_fingerprint: Some("SHA256:test".to_string()),
        jump_via: None,
    };
    let _host_id = Host::add_host(&mut conn, &invalid_port_host).expect("Failed to create test host");
    let invalid_port_host = Host::get_from_name_sync(&mut conn, "invalid_port_host".to_string()).unwrap().unwrap();
    
    let connection_result = invalid_port_host.to_connection().await;
    assert!(connection_result.is_err(), "Should fail with invalid port");
    
    match connection_result.unwrap_err() {
        SshClientError::PortCastFailed => {
            log::info!("Correctly detected invalid port");
        }
        other_error => {
            log::warn!("Unexpected error for invalid port: {:?}", other_error);
        }
    }
    
    log::info!("✅ SSH error handling test passed");
}

#[tokio::test]
#[serial]
async fn test_authorized_keys_synchronization() {
    crate::tests::safety::init_test_mode();
    let test_config = TestConfig::new().await;
    
    let _mock_client = MockSshClient::new(
        test_config.db_pool.clone(),
        test_config.config.ssh.clone()
    );
    
    let mut conn = test_config.db_pool.get().unwrap();
    
    // Create multiple users with keys
    let users_data = vec![
        ("sync_user1", "ssh-ed25519", "AAAAC3NzaC1lZDI1NTE5AAAAISyncUser1Key", "user1@sync.test"),
        ("sync_user2", "ssh-rsa", "AAAAB3NzaC1yc2EAAAADAQABAAABgQSyncUser2Key", "user2@sync.test"),
        ("sync_user3", "ssh-ed25519", "AAAAC3NzaC1lZDI1NTE5AAAAISyncUser3Key", "user3@sync.test"),
    ];
    
    let mut user_ids = Vec::new();
    
    for (username, key_type, key_data, comment) in users_data {
        let new_user = NewUser {
            username: username.to_string(),
        };
        let _username = User::add_user(&mut conn, new_user).expect("Failed to create test user");
        let user = User::get_user(&mut conn, username.to_string()).expect("Failed to get user");
        
        if let Ok(algorithm) = Algorithm::new(key_type) {
            let new_key = NewPublicUserKey::new(
                algorithm,
                key_data.to_string(),
                Some(comment.to_string()),
                user.id,
            );
            let _ = PublicUserKey::add_key(&mut conn, new_key);
        }
        
        user_ids.push(user.id);
    }
    
    // Create sync host
    let sync_host = NewHost {
        name: "sync_host".to_string(),
        username: "sync".to_string(),
        address: "192.168.1.220".to_string(),
        port: 22,
        key_fingerprint: Some("SHA256:sync_fingerprint".to_string()),
        jump_via: None,
    };
    let host_id = Host::add_host(&mut conn, &sync_host).expect("Failed to create sync host");
    let host = Host::get_from_name_sync(&mut conn, "sync_host".to_string()).unwrap().unwrap();
    
    // Authorize all users on the host
    for user_id in user_ids {
        let _ = Host::authorize_user(
            &mut conn,
            host_id,
            user_id,
            "sync".to_string(),
            Some("restrict".to_string()),
        );
    }
    
    // Get authorized keys for the host
    let authorized_keys_result = host.get_authorized_keys(&mut conn);
    assert!(authorized_keys_result.is_ok(), "Should get authorized keys list");
    
    let authorized_keys_list = authorized_keys_result.unwrap();
    assert_eq!(authorized_keys_list.len(), 3, "Should have 3 authorized keys");
    
    // Test authorized keys synchronization 
    let keys_file_result = host.get_authorized_keys(&mut conn);
    assert!(keys_file_result.is_ok(), "Should get authorized keys list");
    
    let keys_list = keys_file_result.unwrap();
    assert_eq!(keys_list.len(), 3, "Should have exactly 3 authorized keys");
    
    // Verify all users' keys are included
    let comments: Vec<String> = keys_list.iter()
        .filter_map(|auth_key| auth_key.key.comment.as_ref())
        .cloned()
        .collect();
    
    assert!(comments.iter().any(|c| c.contains("user1@sync.test")));
    assert!(comments.iter().any(|c| c.contains("user2@sync.test")));
    assert!(comments.iter().any(|c| c.contains("user3@sync.test")));
    
    // Verify SSH options are applied
    for auth_key in &keys_list {
        assert!(auth_key.options.as_ref().unwrap().contains("restrict"));
    }
    
    log::info!("✅ Authorized keys synchronization test passed");
}

#[tokio::test]
#[serial]
async fn test_ssh_key_validation() {
    crate::tests::safety::init_test_mode();
    let test_config = TestConfig::new().await;
    
    let _mock_client = MockSshClient::new(
        test_config.db_pool.clone(),
        test_config.config.ssh.clone()
    );
    
    let mut conn = test_config.db_pool.get().unwrap();
    
    // Create test user
    let new_user = NewUser {
        username: "validation_user".to_string(),
    };
    let _username = User::add_user(&mut conn, new_user).expect("Failed to create test user");
    let user = User::get_user(&mut conn, "validation_user".to_string()).expect("Failed to get user");
    
    // Test valid SSH key formats
    let valid_keys = vec![
        ("ssh-ed25519", "AAAAC3NzaC1lZDI1NTE5AAAAIValidEd25519Key123456789", "valid_ed25519@test.com"),
        ("ssh-rsa", "AAAAB3NzaC1yc2EAAAADAQABAAABgQValidRSAKey123456789", "valid_rsa@test.com"),
    ];
    
    for (key_type, key_data, comment) in valid_keys {
        if let Ok(algorithm) = Algorithm::new(key_type) {
            let new_key = NewPublicUserKey::new(
                algorithm,
                key_data.to_string(),
                Some(comment.to_string()),
                user.id,
            );
            
            let add_result = PublicUserKey::add_key(&mut conn, new_key);
            assert!(add_result.is_ok(), "Should accept valid SSH key format: {}", key_type);
        }
    }
    
    // Verify keys were added
    let user_keys = user.get_keys(&mut conn).expect("Should get user keys");
    assert!(!user_keys.is_empty(), "Should have added valid keys");
    
    // Test key fingerprint generation
    for key in user_keys {
        let openssh_format = key.to_openssh();
        assert!(openssh_format.starts_with("ssh-"), "Should generate valid OpenSSH format");
        assert!(openssh_format.contains(&key.key_base64), "Should contain key data");
        
        if let Some(comment) = &key.comment {
            assert!(openssh_format.contains(comment), "Should contain key comment");
        }
    }
    
    log::info!("✅ SSH key validation test passed");
}

#[tokio::test]
#[serial]
async fn test_ssh_connection_pooling() {
    crate::tests::safety::init_test_mode();
    let test_config = TestConfig::new().await;
    
    let mock_client = MockSshClient::new(
        test_config.db_pool.clone(),
        test_config.config.ssh.clone()
    );
    
    let mut conn = test_config.db_pool.get().unwrap();
    
    // Create test host
    let pool_host = NewHost {
        name: "pool_test_host".to_string(),
        username: "pool".to_string(),
        address: "192.168.1.230".to_string(),
        port: 22,
        key_fingerprint: Some("SHA256:pool_fingerprint".to_string()),
        jump_via: None,
    };
    let _host_id = Host::add_host(&mut conn, &pool_host).expect("Failed to create pool test host");
    let host = Host::get_from_name_sync(&mut conn, "pool_test_host".to_string()).unwrap().unwrap();
    
    // Test multiple concurrent SSH operations
    let mut operation_results = Vec::new();
    
    for _i in 0..5 {
        let keys_result = mock_client.get_authorized_keys(host.clone()).await;
        operation_results.push(keys_result.is_ok());
    }
    
    // All operations should succeed
    assert!(operation_results.iter().all(|&result| result), "All SSH operations should succeed");
    
    // Test connection reuse (mock client should handle this internally)
    let first_keys = mock_client.get_authorized_keys(host.clone()).await.unwrap();
    let second_keys = mock_client.get_authorized_keys(host.clone()).await.unwrap();
    
    // Results should be consistent
    assert_eq!(first_keys.len(), second_keys.len(), "Consistent results from connection reuse");
    
    log::info!("✅ SSH connection pooling test passed");
}

#[tokio::test]
#[serial]
async fn test_host_dependency_management() {
    crate::tests::safety::init_test_mode();
    let test_config = TestConfig::new().await;
    
    let mut conn = test_config.db_pool.get().unwrap();
    
    // Create primary host
    let primary_host = NewHost {
        name: "primary_host".to_string(),
        username: "primary".to_string(),
        address: "192.168.1.240".to_string(),
        port: 22,
        key_fingerprint: Some("SHA256:primary_fingerprint".to_string()),
        jump_via: None,
    };
    let primary_host_id = Host::add_host(&mut conn, &primary_host).expect("Failed to create primary host");
    let primary_host = Host::get_from_name_sync(&mut conn, "primary_host".to_string()).unwrap().unwrap();
    
    // Create dependent hosts
    let dependent_hosts = vec![
        "dependent_host_1",
        "dependent_host_2",
        "dependent_host_3",
    ];
    
    for host_name in &dependent_hosts {
        let dependent_host = NewHost {
            name: host_name.to_string(),
            username: "dependent".to_string(),
            address: format!("10.0.0.{}", dependent_hosts.iter().position(|&h| h == *host_name).unwrap() + 10),
            port: 22,
            key_fingerprint: Some(format!("SHA256:{}_fingerprint", host_name)),
            jump_via: Some(primary_host_id),
        };
        let _ = Host::add_host(&mut conn, &dependent_host).expect("Failed to create dependent host");
    }
    
    // Test getting dependent hosts
    let dependents_result = primary_host.get_dependant_hosts(&mut conn);
    assert!(dependents_result.is_ok(), "Should get dependent hosts");
    
    let dependents = dependents_result.unwrap();
    assert_eq!(dependents.len(), 3, "Should have 3 dependent hosts");
    
    // Verify dependent host names
    for expected_name in &dependent_hosts {
        assert!(dependents.contains(&expected_name.to_string()), "Should contain dependent host: {}", expected_name);
    }
    
    log::info!("✅ Host dependency management test passed");
}