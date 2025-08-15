/// Integration Tests for SSH Key Manager
/// 
/// Comprehensive end-to-end testing scenarios that test the entire system
/// including database operations, SSH mock interactions, and complex workflows

use crate::tests::{
    test_utils::TestConfig,
    mock_ssh::{MockSshClient, MockSshErrorType},
    safety::init_test_mode,
};
use crate::models::{Host, User, PublicUserKey, NewHost, NewUser, NewPublicUserKey};
use serial_test::serial;

#[tokio::test]
#[serial]
async fn test_complete_key_deployment_workflow() {
    init_test_mode();
    let test_config = TestConfig::new().await;
    let mut conn = test_config.db_pool.get().unwrap();
    
    // Create mock SSH client
    let mock_ssh = MockSshClient::new(test_config.db_pool.clone(), test_config.config.ssh.clone());
    
    // 1. Create test users
    let user1 = User::add_user(&mut conn, NewUser { username: "alice".to_string() }).unwrap();
    let user2 = User::add_user(&mut conn, NewUser { username: "bob".to_string() }).unwrap();
    
    // 2. Create test hosts
    let host1_id = Host::add_host(&mut conn, &NewHost {
        name: "web-server".to_string(),
        address: "192.168.1.10".to_string(),
        port: 22,
        username: "ubuntu".to_string(),
        key_fingerprint: Some("TEST_web_server_key".to_string()),
        jump_via: None,
    }).unwrap();
    
    let host2_id = Host::add_host(&mut conn, &NewHost {
        name: "db-server".to_string(),
        address: "192.168.1.20".to_string(),
        port: 22,
        username: "ubuntu".to_string(),
        key_fingerprint: Some("TEST_db_server_key".to_string()),
        jump_via: None,
    }).unwrap();
    
    // 3. Add SSH keys for users
    let alice_key = PublicUserKey::add_key(&mut conn, NewPublicUserKey {
        key_type: "ssh-rsa".to_string(),
        key_base64: "AAAAB3NzaC1yc2EAAAADAQABAAABAQC7ALICE".to_string(),
        comment: "alice@workstation".to_string(),
        fingerprint: "SHA256:alice_fingerprint".to_string(),
    }).unwrap();
    
    let bob_key = PublicUserKey::add_key(&mut conn, NewPublicUserKey {
        key_type: "ssh-ed25519".to_string(),
        key_base64: "AAAAC3NzaC1lZDI1NTE5AAAAIOBOB".to_string(),
        comment: "bob@laptop".to_string(),
        fingerprint: "SHA256:bob_fingerprint".to_string(),
    }).unwrap();
    
    // 4. Associate keys with users
    User::add_key_to_user(&mut conn, user1, alice_key).unwrap();
    User::add_key_to_user(&mut conn, user2, bob_key).unwrap();
    
    // 5. Authorize users on hosts
    Authorization::authorize_user(&mut conn, user1, host1_id, "ubuntu".to_string(), None).unwrap();
    Authorization::authorize_user(&mut conn, user1, host2_id, "deploy".to_string(), Some("no-port-forwarding".to_string())).unwrap();
    Authorization::authorize_user(&mut conn, user2, host1_id, "ubuntu".to_string(), None).unwrap();
    
    // 6. Test SSH operations with mock client
    let host1 = Host::get_host(&mut conn, host1_id).unwrap();
    let host2 = Host::get_host(&mut conn, host2_id).unwrap();
    
    // Mock successful key retrieval
    let keyfiles1 = mock_ssh.get_authorized_keys(host1).await.unwrap();
    let keyfiles2 = mock_ssh.get_authorized_keys(host2).await.unwrap();
    
    // Verify realistic keyfiles structure
    assert!(!keyfiles1.is_empty(), "Should have keyfiles for common logins");
    assert!(!keyfiles2.is_empty(), "Should have keyfiles for common logins");
    
    // Check that we got expected logins
    let logins1: Vec<String> = keyfiles1.iter().map(|kf| kf.login.clone()).collect();
    assert!(logins1.contains(&"ubuntu".to_string()));
    assert!(logins1.contains(&"root".to_string()));
    
    log::info!("✅ Complete key deployment workflow test passed");
}

#[tokio::test]
#[serial]
async fn test_ssh_error_handling_scenarios() {
    init_test_mode();
    let test_config = TestConfig::new().await;
    let mut conn = test_config.db_pool.get().unwrap();
    
    let mock_ssh = MockSshClient::new(test_config.db_pool.clone(), test_config.config.ssh.clone());
    
    // Create test host
    let host_id = Host::add_host(&mut conn, &NewHost {
        name: "error-test-host".to_string(),
        address: "192.168.1.100".to_string(),
        port: 22,
        username: "ubuntu".to_string(),
        key_fingerprint: Some("TEST_error_host_key".to_string()),
        jump_via: None,
    }).unwrap();
    
    let host = Host::get_host(&mut conn, host_id).unwrap();
    
    // Test different error scenarios
    let error_scenarios = vec![
        (MockSshErrorType::ConnectionTimeout, "Connection timed out"),
        (MockSshErrorType::AuthenticationFailed, "Authentication failed"),
        (MockSshErrorType::HostKeyMismatch, "Host key verification failed"),
        (MockSshErrorType::PermissionDenied, "Permission denied"),
        (MockSshErrorType::NetworkUnreachable, "Network is unreachable"),
    ];
    
    for (error_type, expected_message) in error_scenarios {
        // Clear previous errors
        mock_ssh.clear_all_mocks().await;
        
        // Simulate specific error
        mock_ssh.simulate_specific_error(&host.name, error_type.clone()).await;
        
        // Test that operation fails with expected error
        let result = mock_ssh.get_authorized_keys(host.clone()).await;
        assert!(result.is_err(), "Should fail for error type: {:?}", error_type);
        
        let error_msg = result.unwrap_err().to_string();
        assert!(error_msg.contains(expected_message), 
               "Error message should contain '{}', got: {}", expected_message, error_msg);
        
        log::info!("✅ SSH error handling test passed for: {:?}", error_type);
    }
}

#[tokio::test]
#[serial]
async fn test_concurrent_operations() {
    init_test_mode();
    let test_config = TestConfig::new().await;
    let mock_ssh = MockSshClient::new(test_config.db_pool.clone(), test_config.config.ssh.clone());
    
    // Create multiple hosts for concurrent testing
    let mut hosts = Vec::new();
    {
        let mut conn = test_config.db_pool.get().unwrap();
        for i in 0..5 {
            let host_id = Host::add_host(&mut conn, &NewHost {
                name: format!("concurrent-host-{}", i),
                address: format!("192.168.1.{}", 200 + i),
                port: 22,
                username: "ubuntu".to_string(),
                key_fingerprint: Some(format!("TEST_concurrent_{}_key", i)),
                jump_via: None,
            }).unwrap();
            
            let host = Host::get_host(&mut conn, host_id).unwrap();
            hosts.push(host);
        }
    }
    
    // Test concurrent SSH operations
    let mut tasks = Vec::new();
    for host in hosts {
        let mock_ssh_clone = mock_ssh.clone();
        let task = tokio::spawn(async move {
            // Simulate some network delay
            mock_ssh_clone.simulate_network_delay(&host.name, 50).await;
            
            // Perform SSH operation
            let result = mock_ssh_clone.get_authorized_keys(host.clone()).await;
            (host.name.clone(), result.is_ok())
        });
        tasks.push(task);
    }
    
    // Wait for all tasks to complete
    let results = futures::future::join_all(tasks).await;
    
    // Verify all operations succeeded
    for result in results {
        let (host_name, success) = result.unwrap();
        assert!(success, "Concurrent operation should succeed for host: {}", host_name);
    }
    
    // Verify operation logging
    let operations = mock_ssh.get_operation_log().await;
    assert!(operations.len() >= 10, "Should have logged multiple operations"); // Connect + GetKeyfiles for each host
    
    log::info!("✅ Concurrent operations test passed");
}

#[tokio::test]
#[serial]
async fn test_key_diff_scenarios() {
    init_test_mode();
    let test_config = TestConfig::new().await;
    let mock_ssh = MockSshClient::new(test_config.db_pool.clone(), test_config.config.ssh.clone());
    
    // Test different key diff scenarios
    let scenarios = vec![
        (
            "Adding new key",
            "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC7NEWKEY new@example.com",
            |diff: &Vec<_>| diff.iter().any(|d| d.to_string().contains("+ ssh-rsa"))
        ),
        (
            "Multiple keys",
            "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC7KEY1 key1@example.com\nssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOKEY2 key2@example.com",
            |diff: &Vec<_>| diff.len() >= 2
        ),
        (
            "Empty keyfile",
            "",
            |diff: &Vec<_>| diff.iter().any(|d| d.to_string().contains("- ssh-rsa"))
        ),
    ];
    
    for (scenario_name, new_keyfile, validation) in scenarios {
        let diff = mock_ssh.key_diff(
            new_keyfile,
            "test-host".to_string(),
            "ubuntu".to_string()
        ).await.unwrap();
        
        assert!(validation(&diff), "Validation failed for scenario: {}", scenario_name);
        log::info!("✅ Key diff test passed for scenario: {}", scenario_name);
    }
}

#[tokio::test]
#[serial]
async fn test_ssh_key_generation() {
    init_test_mode();
    
    let key_types = vec!["ssh-rsa", "ssh-ed25519", "ecdsa-sha2-nistp256"];
    
    for key_type in key_types {
        let generated_key = MockSshClient::generate_test_ssh_key(key_type, "test@example.com");
        
        // Verify key format
        assert!(generated_key.starts_with(key_type), "Key should start with correct type");
        assert!(generated_key.contains("test@example.com"), "Key should contain comment");
        assert!(generated_key.contains("TEST"), "Key should contain test marker");
        
        // Verify uniqueness
        let another_key = MockSshClient::generate_test_ssh_key(key_type, "test@example.com");
        assert_ne!(generated_key, another_key, "Generated keys should be unique");
        
        log::info!("✅ SSH key generation test passed for: {}", key_type);
    }
}

#[tokio::test]
#[serial]
async fn test_complex_authorization_matrix() {
    init_test_mode();
    let test_config = TestConfig::new().await;
    let mut conn = test_config.db_pool.get().unwrap();
    
    // Create multiple users and hosts for matrix testing
    let users = vec!["alice", "bob", "charlie", "david"];
    let hosts = vec!["web", "db", "cache", "backup"];
    let logins = vec!["ubuntu", "deploy", "admin"];
    
    let mut user_ids = Vec::new();
    let mut host_ids = Vec::new();
    
    // Create users
    for username in &users {
        let user_id = User::add_user(&mut conn, NewUser { 
            username: username.to_string() 
        }).unwrap();
        user_ids.push(user_id);
    }
    
    // Create hosts
    for (i, hostname) in hosts.iter().enumerate() {
        let host_id = Host::add_host(&mut conn, &NewHost {
            name: hostname.to_string(),
            address: format!("192.168.1.{}", 10 + i),
            port: 22,
            username: "ubuntu".to_string(),
            key_fingerprint: Some(format!("TEST_{}_key", hostname)),
            jump_via: None,
        }).unwrap();
        host_ids.push(host_id);
    }
    
    // Create complex authorization matrix
    // Alice: full access to web and db
    Authorization::authorize_user(&mut conn, user_ids[0], host_ids[0], "ubuntu".to_string(), None).unwrap();
    Authorization::authorize_user(&mut conn, user_ids[0], host_ids[0], "deploy".to_string(), None).unwrap();
    Authorization::authorize_user(&mut conn, user_ids[0], host_ids[1], "ubuntu".to_string(), None).unwrap();
    
    // Bob: limited access to web only
    Authorization::authorize_user(&mut conn, user_ids[1], host_ids[0], "deploy".to_string(), 
                                 Some("no-port-forwarding,no-x11-forwarding".to_string())).unwrap();
    
    // Charlie: admin access to all hosts
    for host_id in &host_ids {
        Authorization::authorize_user(&mut conn, user_ids[2], *host_id, "admin".to_string(), None).unwrap();
    }
    
    // David: backup access only
    Authorization::authorize_user(&mut conn, user_ids[3], host_ids[3], "backup".to_string(), 
                                 Some("command=\"rsync --server --daemon .\"".to_string())).unwrap();
    
    // Verify authorization matrix
    let alice_auths = Authorization::get_user_authorizations(&mut conn, user_ids[0]).unwrap();
    assert_eq!(alice_auths.len(), 3, "Alice should have 3 authorizations");
    
    let bob_auths = Authorization::get_user_authorizations(&mut conn, user_ids[1]).unwrap();
    assert_eq!(bob_auths.len(), 1, "Bob should have 1 authorization");
    assert!(bob_auths[0].options.is_some(), "Bob should have restricted access");
    
    let charlie_auths = Authorization::get_user_authorizations(&mut conn, user_ids[2]).unwrap();
    assert_eq!(charlie_auths.len(), 4, "Charlie should have admin access to all hosts");
    
    let david_auths = Authorization::get_user_authorizations(&mut conn, user_ids[3]).unwrap();
    assert_eq!(david_auths.len(), 1, "David should have backup access only");
    assert!(david_auths[0].options.as_ref().unwrap().contains("rsync"), "David should have rsync command restriction");
    
    log::info!("✅ Complex authorization matrix test passed");
}

#[tokio::test]
#[serial]
async fn test_database_constraints_and_integrity() {
    init_test_mode();
    let test_config = TestConfig::new().await;
    let mut conn = test_config.db_pool.get().unwrap();
    
    // Test user creation constraints
    let user1_id = User::add_user(&mut conn, NewUser { username: "test_user".to_string() }).unwrap();
    
    // Test duplicate user creation fails
    let duplicate_result = User::add_user(&mut conn, NewUser { username: "test_user".to_string() });
    assert!(duplicate_result.is_err(), "Duplicate user creation should fail");
    
    // Test host creation
    let host1_id = Host::add_host(&mut conn, &NewHost {
        name: "test_host".to_string(),
        address: "192.168.1.100".to_string(),
        port: 22,
        username: "ubuntu".to_string(),
        key_fingerprint: Some("TEST_fingerprint".to_string()),
        jump_via: None,
    }).unwrap();
    
    // Test duplicate host creation fails
    let duplicate_host_result = Host::add_host(&mut conn, &NewHost {
        name: "test_host".to_string(),
        address: "192.168.1.200".to_string(),
        port: 22,
        username: "ubuntu".to_string(),
        key_fingerprint: Some("TEST_fingerprint2".to_string()),
        jump_via: None,
    });
    assert!(duplicate_host_result.is_err(), "Duplicate host name should fail");
    
    // Test key creation
    let key1_id = PublicUserKey::add_key(&mut conn, NewPublicUserKey {
        key_type: "ssh-rsa".to_string(),
        key_base64: "AAAAB3NzaC1yc2EAAAADAQABAAABAQC7UNIQUE".to_string(),
        comment: "test@example.com".to_string(),
        fingerprint: "SHA256:unique_fingerprint".to_string(),
    }).unwrap();
    
    // Test duplicate key fingerprint fails
    let duplicate_key_result = PublicUserKey::add_key(&mut conn, NewPublicUserKey {
        key_type: "ssh-rsa".to_string(),
        key_base64: "AAAAB3NzaC1yc2EAAAADAQABAAABAQC7DIFFERENT".to_string(),
        comment: "different@example.com".to_string(),
        fingerprint: "SHA256:unique_fingerprint".to_string(), // Same fingerprint
    });
    assert!(duplicate_key_result.is_err(), "Duplicate key fingerprint should fail");
    
    // Test foreign key constraints
    Authorization::authorize_user(&mut conn, user1_id, host1_id, "ubuntu".to_string(), None).unwrap();
    
    // Test cascade delete (when deleting user, their authorizations should be removed)
    User::delete_user(&mut conn, user1_id).unwrap();
    
    let remaining_auths = Authorization::get_user_authorizations(&mut conn, user1_id);
    assert!(remaining_auths.is_err() || remaining_auths.unwrap().is_empty(), 
           "User authorizations should be cleaned up on user deletion");
    
    log::info!("✅ Database constraints and integrity test passed");
}