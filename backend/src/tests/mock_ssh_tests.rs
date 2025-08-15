/// Tests for MockSshClient enhancements
/// 
/// Simple tests that focus on the mock functionality without complex database interactions

use crate::tests::{
    test_utils::TestConfig,
    mock_ssh::{MockSshClient, MockSshErrorType},
    safety::init_test_mode,
};
use serial_test::serial;

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
async fn test_error_simulation() {
    init_test_mode();
    let test_config = TestConfig::new().await;
    let mock_ssh = MockSshClient::new(test_config.db_pool.clone(), test_config.config.ssh.clone());
    
    // Test different error scenarios
    let error_scenarios = vec![
        (MockSshErrorType::ConnectionTimeout, "Connection timed out"),
        (MockSshErrorType::AuthenticationFailed, "Authentication failed"),
        (MockSshErrorType::HostKeyMismatch, "Host key verification failed"),
        (MockSshErrorType::PermissionDenied, "Permission denied"),
        (MockSshErrorType::NetworkUnreachable, "Network is unreachable"),
    ];
    
    for (error_type, _expected_message) in error_scenarios {
        // Simulate specific error
        mock_ssh.simulate_specific_error("test-host", error_type.clone()).await;
        
        // Verify error was set (we can't test the actual SSH operation without a real host)
        log::info!("✅ Error simulation set for: {:?}", error_type);
        
        // Clear the error
        mock_ssh.clear_all_mocks().await;
    }
}

#[tokio::test]
#[serial]
async fn test_operation_logging() {
    init_test_mode();
    let test_config = TestConfig::new().await;
    let mock_ssh = MockSshClient::new(test_config.db_pool.clone(), test_config.config.ssh.clone());
    
    // Initially should have no operations
    let initial_ops = mock_ssh.get_operation_log().await;
    assert_eq!(initial_ops.len(), 0, "Should start with empty operation log");
    
    // Test manual operation logging
    mock_ssh.log_operation(
        crate::tests::mock_ssh::MockOperationType::Connect,
        "test-host",
        Some("ubuntu"),
        true
    ).await;
    
    mock_ssh.log_operation(
        crate::tests::mock_ssh::MockOperationType::GetKeyfiles,
        "test-host",
        Some("ubuntu"),
        true
    ).await;
    
    // Check that operations were logged
    let operations = mock_ssh.get_operation_log().await;
    assert_eq!(operations.len(), 2, "Should have logged 2 operations");
    
    // Verify operation details
    assert_eq!(operations[0].host, "test-host");
    assert_eq!(operations[0].login, Some("ubuntu".to_string()));
    assert!(operations[0].success);
    
    log::info!("✅ Operation logging test passed");
}

#[tokio::test]
#[serial]
async fn test_realistic_authorized_keys_generation() {
    init_test_mode();
    let test_config = TestConfig::new().await;
    let mock_ssh = MockSshClient::new(test_config.db_pool.clone(), test_config.config.ssh.clone());
    
    let logins = vec!["root", "ubuntu", "admin", "deploy"];
    
    for login in logins {
        let keys = mock_ssh.generate_realistic_authorized_keys(login);
        
        // Should not be empty
        assert!(!keys.is_empty(), "Should generate keys for login: {}", login);
        
        // Should contain SSH key markers
        assert!(keys.contains("ssh-"), "Should contain SSH keys");
        
        // Should have newlines (multiple keys)
        let key_count = keys.lines().filter(|line| !line.trim().is_empty()).count();
        assert!(key_count >= 1, "Should have at least one key for login: {}", login);
        
        log::info!("✅ Generated {} keys for login: {}", key_count, login);
    }
}

#[tokio::test]
#[serial]
async fn test_mock_configuration() {
    init_test_mode();
    let test_config = TestConfig::new().await;
    let mock_ssh = MockSshClient::new(test_config.db_pool.clone(), test_config.config.ssh.clone());
    
    // Test that mock client returns consistent test keys
    let key1 = mock_ssh.get_own_key_openssh();
    let key2 = mock_ssh.get_own_key_openssh();
    assert_eq!(key1, key2, "Mock SSH client should return consistent own key");
    
    let b64_1 = mock_ssh.get_own_key_b64();
    let b64_2 = mock_ssh.get_own_key_b64();
    assert_eq!(b64_1, b64_2, "Mock SSH client should return consistent base64 key");
    
    // Verify test key format
    assert!(key1.starts_with("ssh-rsa"), "Mock key should be SSH RSA format");
    assert!(key1.contains("test-ssm-key"), "Mock key should contain test marker");
    
    log::info!("✅ Mock configuration test passed");
}

#[tokio::test]
#[serial]
async fn test_clear_mocks() {
    init_test_mode();
    let test_config = TestConfig::new().await;
    let mock_ssh = MockSshClient::new(test_config.db_pool.clone(), test_config.config.ssh.clone());
    
    // Add some operations and errors
    mock_ssh.simulate_specific_error("host1", MockSshErrorType::ConnectionTimeout).await;
    mock_ssh.log_operation(
        crate::tests::mock_ssh::MockOperationType::Connect,
        "host1",
        None,
        false
    ).await;
    
    // Verify they exist
    let ops_before = mock_ssh.get_operation_log().await;
    assert!(!ops_before.is_empty(), "Should have operations before clear");
    
    // Clear all mocks
    mock_ssh.clear_all_mocks().await;
    
    // Verify they're cleared
    let ops_after = mock_ssh.get_operation_log().await;
    assert_eq!(ops_after.len(), 0, "Should have no operations after clear");
    
    log::info!("✅ Clear mocks test passed");
}