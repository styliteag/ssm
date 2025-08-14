/// Safety verification tests
/// 
/// These tests verify that the safety infrastructure prevents
/// real SSH connections and production database access during testing.

use super::safety::*;
use std::env;

#[test]
fn test_safety_mode_enabled() {
    // Initialize test mode
    init_test_mode();
    
    // Verify test mode is active
    assert!(is_test_mode(), "Test mode should be active");
    assert!(are_ssh_operations_blocked(), "SSH operations should be blocked");
    
    // Verify environment variable is set
    assert!(env::var("SSH_KEY_MANAGER_TEST_MODE").is_ok(), "Test mode env var should be set");
}

#[test]
fn test_ssh_operations_blocked() {
    init_test_mode();
    
    // Try to assert SSH operations are allowed (should fail)
    let result = assert_ssh_operations_allowed();
    assert!(result.is_err(), "SSH operations should be blocked in test mode");
    
    match result {
        Err(TestSafetyError::SshOperationBlocked) => {},
        Err(TestSafetyError::TestModeActive) => {},
        _ => panic!("Expected SSH operations to be blocked"),
    }
}

#[test]
fn test_production_database_blocked() {
    init_test_mode();
    
    // Try to use production database (should fail)
    let result = validate_test_database_url("sqlite://ssm.db");
    assert!(result.is_err(), "Production database should be blocked");
    
    // Try to use production-looking databases (should fail)
    assert!(validate_test_database_url("postgresql://prod.company.com/main").is_err());
    assert!(validate_test_database_url("mysql://production/data").is_err());
    assert!(validate_test_database_url("sqlite://live.db").is_err());
    
    // Test databases should be allowed
    assert!(validate_test_database_url("sqlite://test.db").is_ok());
    assert!(validate_test_database_url("sqlite:///tmp/test_db.db").is_ok());
    assert!(validate_test_database_url("postgresql://localhost/test_database").is_ok());
}

#[test]
fn test_production_host_blocked() {
    init_test_mode();
    
    // Public IPs should be blocked
    assert!(validate_test_host_config("8.8.8.8", 22, "TEST_key").is_err());
    assert!(validate_test_host_config("1.1.1.1", 22, "TEST_key").is_err());
    assert!(validate_test_host_config("93.184.216.34", 22, "TEST_key").is_err());
    
    // Localhost and private IPs should be allowed
    assert!(validate_test_host_config("127.0.0.1", 22, "TEST_key").is_ok());
    assert!(validate_test_host_config("192.168.1.100", 22, "TEST_key").is_ok());
    assert!(validate_test_host_config("10.0.0.1", 22, "TEST_key").is_ok());
    assert!(validate_test_host_config("172.16.0.1", 22, "TEST_key").is_ok());
    
    // Production-looking fingerprints should be blocked
    assert!(validate_test_host_config("127.0.0.1", 22, "SHA256:realproductionkey").is_err());
    assert!(validate_test_host_config("127.0.0.1", 22, "production_key").is_err());
}

#[test]
fn test_production_ssh_keys_blocked() {
    init_test_mode();
    
    use std::path::Path;
    
    // Production key paths should be blocked
    assert!(validate_test_ssh_key_path(Path::new("/home/user/.ssh/id_rsa")).is_err());
    assert!(validate_test_ssh_key_path(Path::new("/Users/admin/.ssh/id_ed25519")).is_err());
    assert!(validate_test_ssh_key_path(Path::new("/root/.ssh/id_rsa")).is_err());
    
    // Test key paths should be allowed
    assert!(validate_test_ssh_key_path(Path::new("/tmp/test_key")).is_ok());
    assert!(validate_test_ssh_key_path(Path::new("/tmp/test/ssh_key")).is_ok());
    assert!(validate_test_ssh_key_path(Path::new("test_keys/id_rsa")).is_ok());
}

#[test]
fn test_safety_error_messages() {
    init_test_mode();
    
    // Test that error messages are clear and helpful
    let err = validate_test_database_url("sqlite://production.db").unwrap_err();
    assert!(format!("{}", err).contains("Unsafe database URL"));
    
    let err = validate_test_host_config("8.8.8.8", 22, "TEST_key").unwrap_err();
    assert!(format!("{}", err).contains("Unsafe address for testing"));
    
    let err = validate_test_host_config("127.0.0.1", 22, "real_key").unwrap_err();
    assert!(format!("{}", err).contains("Unsafe SSH key fingerprint"));
}

#[test]
fn test_safety_infrastructure_comprehensive() {
    init_test_mode();
    
    // Comprehensive test of all safety checks
    println!("🛡️ Safety Infrastructure Verification:");
    println!("  ✅ Test mode activated");
    
    assert!(is_test_mode());
    println!("  ✅ SSH operations blocked");
    
    assert!(are_ssh_operations_blocked());
    println!("  ✅ Production databases blocked");
    
    assert!(validate_test_database_url("ssm.db").is_err());
    println!("  ✅ Public IP addresses blocked");
    
    assert!(validate_test_host_config("github.com", 22, "TEST_key").is_err());
    println!("  ✅ Production SSH keys blocked");
    
    assert!(validate_test_ssh_key_path(std::path::Path::new("/home/user/.ssh/id_rsa")).is_err());
    println!("  ✅ All safety checks passed!");
    
    println!("\n🎉 Safety infrastructure is fully functional!");
    println!("   Tests CANNOT modify production systems.");
}