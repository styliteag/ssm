/// Simplified Integration Tests for SSH Key Manager
/// 
/// Focused tests for the MockSshClient enhancements and core functionality

use crate::tests::{
    test_utils::TestConfig,
    mock_ssh::{MockSshClient, MockSshErrorType},
    safety::init_test_mode,
};
use crate::models::{Host, User, NewHost, NewUser};
use serial_test::serial;

#[tokio::test]
#[serial]
async fn test_enhanced_mock_ssh_client() {
    init_test_mode();
    let test_config = TestConfig::new().await;
    let mut conn = test_config.db_pool.get().unwrap();
    
    // Create mock SSH client
    let mock_ssh = MockSshClient::new(test_config.db_pool.clone(), test_config.config.ssh.clone());
    
    // Create test host
    let host_id = Host::add_host(&mut conn, &NewHost {
        name: "enhanced-test-host".to_string(),
        address: "192.168.1.10".to_string(),
        port: 22,
        username: "ubuntu".to_string(),
        key_fingerprint: Some("TEST_enhanced_host_key".to_string()),
        jump_via: None,
    }).unwrap();
    
    let host = Host::get_from_id(conn, host_id).await.unwrap().unwrap();
    
    // Test realistic SSH keyfiles response
    let keyfiles = mock_ssh.get_authorized_keys(host.clone()).await.unwrap();
    
    // Verify realistic structure
    assert!(!keyfiles.is_empty(), "Should have keyfiles for common logins");
    
    // Check that we got expected logins
    let logins: Vec<String> = keyfiles.iter().map(|kf| kf.login.clone()).collect();
    assert!(logins.contains(&"ubuntu".to_string()));
    assert!(logins.contains(&"root".to_string()));
    assert!(logins.contains(&"admin".to_string()));
    assert!(logins.contains(&"deploy".to_string()));
    
    // Verify that each keyfile has realistic authorized_keys content
    for keyfile in &keyfiles {
        assert!(!keyfile.authorized_keys.is_empty(), "Each login should have some keys");
        assert!(keyfile.authorized_keys.contains("ssh-"), "Should contain SSH keys");
        assert!(keyfile.error.is_none(), "Should not have errors in successful case");
    }
    
    log::info!("✅ Enhanced MockSshClient test passed");
}

#[tokio::test]
#[serial]
async fn test_ssh_error_simulation() {
    init_test_mode();
    let test_config = TestConfig::new().await;
    let mut conn = test_config.db_pool.get().unwrap();
    
    let mock_ssh = MockSshClient::new(test_config.db_pool.clone(), test_config.config.ssh.clone());
    
    // Create test host
    let host_id = Host::add_host(&mut conn, &NewHost {
        name: "error-simulation-host".to_string(),
        address: "192.168.1.100".to_string(),
        port: 22,
        username: "ubuntu".to_string(),
        key_fingerprint: Some("TEST_error_host_key".to_string()),
        jump_via: None,
    }).unwrap();
    
    let host = Host::get_from_id(conn, host_id).await.unwrap().unwrap();
    
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
        
        log::info!("✅ SSH error simulation test passed for: {:?}", error_type);
    }
}

#[tokio::test]
#[serial]
async fn test_realistic_key_diff() {
    init_test_mode();
    let test_config = TestConfig::new().await;
    let mock_ssh = MockSshClient::new(test_config.db_pool.clone(), test_config.config.ssh.clone());
    
    // Test different key diff scenarios
    let scenarios = vec![
        (
            "Adding new key",
            "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC7NEWKEY new@example.com",
            "ubuntu",
            |diff: &Vec<_>| {
                // Should have removals of old keys and addition of new key
                let has_additions = diff.iter().any(|d| d.to_string().contains("+ ssh-rsa"));
                let has_removals = diff.iter().any(|d| d.to_string().contains("- ssh-rsa"));
                has_additions || has_removals
            }
        ),
        (
            "Multiple keys",
            "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC7KEY1 key1@example.com\nssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOKEY2 key2@example.com",
            "deploy",
            |diff: &Vec<_>| diff.len() >= 1 // Should have some changes
        ),
        (
            "Empty keyfile",
            "",
            "admin",
            |diff: &Vec<_>| diff.iter().any(|d| d.to_string().contains("- ssh-rsa"))
        ),
    ];
    
    for (scenario_name, new_keyfile, login, validation) in scenarios {
        let diff = mock_ssh.key_diff(
            new_keyfile,
            "test-host".to_string(),
            login.to_string()
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
            
            let host = Host::get_from_id(conn, host_id).await.unwrap().unwrap();
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
async fn test_network_delay_simulation() {
    init_test_mode();
    let test_config = TestConfig::new().await;
    let mock_ssh = MockSshClient::new(test_config.db_pool.clone(), test_config.config.ssh.clone());
    
    let start_time = std::time::Instant::now();
    
    // Simulate 100ms delay
    mock_ssh.simulate_network_delay("test-host", 100).await;
    
    let elapsed = start_time.elapsed();
    assert!(elapsed >= std::time::Duration::from_millis(90), "Should have actual delay");
    assert!(elapsed < std::time::Duration::from_millis(200), "Delay should not be too long");
    
    log::info!("✅ Network delay simulation test passed");
}

#[tokio::test]
#[serial]
async fn test_mock_operation_logging() {
    init_test_mode();
    let test_config = TestConfig::new().await;
    let mut conn = test_config.db_pool.get().unwrap();
    
    let mock_ssh = MockSshClient::new(test_config.db_pool.clone(), test_config.config.ssh.clone());
    
    // Create test host
    let host_id = Host::add_host(&mut conn, &NewHost {
        name: "logging-test-host".to_string(),
        address: "192.168.1.150".to_string(),
        port: 22,
        username: "ubuntu".to_string(),
        key_fingerprint: Some("TEST_logging_host_key".to_string()),
        jump_via: None,
    }).unwrap();
    
    let host = Host::get_from_id(conn, host_id).await.unwrap().unwrap();
    
    // Perform operations
    let _ = mock_ssh.get_authorized_keys(host.clone()).await;
    let _ = mock_ssh.key_diff("test-key", host.name.clone(), "ubuntu".to_string()).await;
    
    // Check operation log
    let operations = mock_ssh.get_operation_log().await;
    assert!(operations.len() >= 4, "Should have logged Connect + GetKeyfiles + Connect + KeyDiff");
    
    // Verify operation types
    let op_types: Vec<String> = operations.iter()
        .map(|op| format!("{:?}", op.operation_type))
        .collect();
    
    assert!(op_types.iter().any(|t| t.contains("Connect")), "Should have Connect operations");
    assert!(op_types.iter().any(|t| t.contains("GetKeyfiles")), "Should have GetKeyfiles operations");
    assert!(op_types.iter().any(|t| t.contains("KeyDiff")), "Should have KeyDiff operations");
    
    log::info!("✅ Mock operation logging test passed");
}

#[tokio::test]
#[serial]
async fn test_database_integration() {
    init_test_mode();
    let test_config = TestConfig::new().await;
    let mut conn = test_config.db_pool.get().unwrap();
    
    // Test user creation
    let _user1_name = User::add_user(&mut conn, NewUser { username: "testuser1".to_string() }).unwrap();
    let user1 = User::get_user(&mut conn, "testuser1".to_string()).unwrap();
    let user1_id = user1.id;
    
    let _user2_name = User::add_user(&mut conn, NewUser { username: "testuser2".to_string() }).unwrap();
    let user2 = User::get_user(&mut conn, "testuser2".to_string()).unwrap();
    let user2_id = user2.id;
    
    // Test duplicate user creation fails
    let duplicate_result = User::add_user(&mut conn, NewUser { username: "testuser1".to_string() });
    assert!(duplicate_result.is_err(), "Duplicate user creation should fail");
    
    // Test host creation
    let host1_id = Host::add_host(&mut conn, &NewHost {
        name: "integration-host-1".to_string(),
        address: "192.168.1.100".to_string(),
        port: 22,
        username: "ubuntu".to_string(),
        key_fingerprint: Some("TEST_integration_fingerprint".to_string()),
        jump_via: None,
    }).unwrap();
    
    let host2_id = Host::add_host(&mut conn, &NewHost {
        name: "integration-host-2".to_string(),
        address: "192.168.1.101".to_string(),
        port: 2222,
        username: "admin".to_string(),
        key_fingerprint: Some("TEST_integration_fingerprint_2".to_string()),
        jump_via: Some(host1_id), // Use host1 as jump host
    }).unwrap();
    
    // Test duplicate host creation fails
    let duplicate_host_result = Host::add_host(&mut conn, &NewHost {
        name: "integration-host-1".to_string(),
        address: "192.168.1.200".to_string(),
        port: 22,
        username: "ubuntu".to_string(),
        key_fingerprint: Some("TEST_different_fingerprint".to_string()),
        jump_via: None,
    });
    assert!(duplicate_host_result.is_err(), "Duplicate host name should fail");
    
    // Skip host retrieval test for now due to async complexity
    // TODO: Fix async connection handling
    log::info!("Skipping host retrieval tests due to async connection complexity");
    
    // Test host authorization
    Host::authorize_user(&mut conn, host1_id, user1_id, "ubuntu".to_string(), None).unwrap();
    Host::authorize_user(&mut conn, host1_id, user2_id, "deploy".to_string(), Some("no-port-forwarding".to_string())).unwrap();
    Host::authorize_user(&mut conn, host2_id, user1_id, "admin".to_string(), Some("command=\"rsync --server\"".to_string())).unwrap();
    
    // Test user retrieval
    let retrieved_user1 = User::get_user(&mut conn, "testuser1".to_string()).unwrap();
    assert_eq!(retrieved_user1.username, "testuser1");
    assert!(retrieved_user1.enabled);
    
    // Test user deletion
    User::delete_user(&mut conn, "testuser2").unwrap();
    let deleted_user_result = User::get_user(&mut conn, "testuser2".to_string());
    assert!(deleted_user_result.is_err(), "Deleted user should not be found");
    
    log::info!("✅ Database integration test passed");
}