use std::sync::atomic::{AtomicBool, Ordering};
use std::net::IpAddr;
use std::path::Path;

/// Global flag to track if we're in test mode
static TEST_MODE: AtomicBool = AtomicBool::new(false);

// Thread-local flag to track if SSH operations are allowed
thread_local! {
    static SSH_OPERATIONS_BLOCKED: std::cell::Cell<bool> = std::cell::Cell::new(false);
}

/// Initialize test mode - MUST be called at the start of every test
pub fn init_test_mode() {
    TEST_MODE.store(true, Ordering::SeqCst);
    SSH_OPERATIONS_BLOCKED.with(|blocked| blocked.set(true));
    
    // Set environment variable for runtime checks
    std::env::set_var("SSH_KEY_MANAGER_TEST_MODE", "1");
    
    log::debug!("🛡️ Test mode initialized - SSH operations BLOCKED");
}

/// Check if we're in test mode
pub fn is_test_mode() -> bool {
    TEST_MODE.load(Ordering::SeqCst) || std::env::var("SSH_KEY_MANAGER_TEST_MODE").is_ok()
}

/// Check if SSH operations are blocked
pub fn are_ssh_operations_blocked() -> bool {
    SSH_OPERATIONS_BLOCKED.with(|blocked| blocked.get()) || is_test_mode()
}

/// Production safety guard - prevents real SSH connections during tests
pub fn assert_ssh_operations_allowed() -> Result<(), TestSafetyError> {
    if are_ssh_operations_blocked() {
        return Err(TestSafetyError::SshOperationBlocked);
    }
    
    if is_test_mode() {
        return Err(TestSafetyError::TestModeActive);
    }
    
    Ok(())
}

/// Validate that a host configuration is safe for testing
pub fn validate_test_host_config(address: &str, _port: u16, key_fingerprint: &str) -> Result<(), TestSafetyError> {
    if !is_test_mode() {
        return Ok(()); // Allow any config in production
    }
    
    // In test mode, only allow safe addresses
    let ip: IpAddr = address.parse().map_err(|_| TestSafetyError::InvalidAddress)?;
    
    match ip {
        IpAddr::V4(ipv4) => {
            // Only allow localhost and private test ranges
            if !ipv4.is_loopback() && !ipv4.is_private() {
                return Err(TestSafetyError::UnsafeTestAddress(address.to_string()));
            }
        },
        IpAddr::V6(ipv6) => {
            if !ipv6.is_loopback() {
                return Err(TestSafetyError::UnsafeTestAddress(address.to_string()));
            }
        }
    }
    
    // Ensure test fingerprints are clearly marked
    if !key_fingerprint.starts_with("TEST_") && !key_fingerprint.contains("test") {
        return Err(TestSafetyError::UnsafeTestFingerprint(key_fingerprint.to_string()));
    }
    
    Ok(())
}

/// Validate that SSH key path is safe for testing
pub fn validate_test_ssh_key_path(path: &Path) -> Result<(), TestSafetyError> {
    if !is_test_mode() {
        return Ok(()); // Allow any path in production
    }
    
    let path_str = path.to_string_lossy();
    
    // Prevent using production SSH keys in tests
    if path_str.contains("/home/") || path_str.contains("/Users/") || path_str.starts_with("/") {
        if !path_str.contains("test") && !path_str.contains("tmp") && !path_str.contains("temp") {
            return Err(TestSafetyError::UnsafeTestKeyPath(path_str.to_string()));
        }
    }
    
    Ok(())
}

/// Validate database URL is safe for testing
pub fn validate_test_database_url(url: &str) -> Result<(), TestSafetyError> {
    if !is_test_mode() {
        return Ok(()); // Allow any URL in production
    }
    
    // Ensure we're not connecting to production databases
    if url.contains("prod") || url.contains("production") || url.contains("live") {
        return Err(TestSafetyError::UnsafeTestDatabase(url.to_string()));
    }
    
    // Require test indicators in database path
    if !url.contains("test") && !url.contains("tmp") && !url.contains("temp") {
        return Err(TestSafetyError::UnsafeTestDatabase(url.to_string()));
    }
    
    Ok(())
}

#[derive(Debug)]
pub enum TestSafetyError {
    SshOperationBlocked,
    TestModeActive,
    InvalidAddress,
    UnsafeTestAddress(String),
    UnsafeTestFingerprint(String),
    UnsafeTestKeyPath(String),
    UnsafeTestDatabase(String),
}

impl std::fmt::Display for TestSafetyError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            TestSafetyError::SshOperationBlocked => write!(f, "SSH operations are blocked during testing"),
            TestSafetyError::TestModeActive => write!(f, "Test mode is active - production operations not allowed"),
            TestSafetyError::InvalidAddress => write!(f, "Invalid IP address format"),
            TestSafetyError::UnsafeTestAddress(addr) => write!(f, "Unsafe address for testing: {} (only localhost/private ranges allowed)", addr),
            TestSafetyError::UnsafeTestFingerprint(fp) => write!(f, "Unsafe SSH key fingerprint for testing: {} (must contain 'test' or start with 'TEST_')", fp),
            TestSafetyError::UnsafeTestKeyPath(path) => write!(f, "Unsafe SSH key path for testing: {} (must be in temp/test directory)", path),
            TestSafetyError::UnsafeTestDatabase(url) => write!(f, "Unsafe database URL for testing: {} (must contain 'test', 'tmp', or 'temp')", url),
        }
    }
}

impl std::error::Error for TestSafetyError {}

/// Macro to ensure a function can only be called in test mode
#[macro_export]
macro_rules! test_only {
    () => {
        if !crate::tests::safety::is_test_mode() {
            panic!("This function can only be called during testing");
        }
    };
}

/// Macro to block SSH operations during testing
#[macro_export]
macro_rules! block_ssh_in_tests {
    () => {
        if let Err(e) = crate::tests::safety::assert_ssh_operations_allowed() {
            return Err(crate::ssh::SshClientError::ExecutionError(format!("🛡️ SSH blocked in tests: {}", e)));
        }
    };
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::Ipv4Addr;

    #[test]
    fn test_mode_detection() {
        init_test_mode();
        assert!(is_test_mode());
        assert!(are_ssh_operations_blocked());
    }

    #[test]
    fn test_ssh_operation_blocking() {
        init_test_mode();
        assert!(assert_ssh_operations_allowed().is_err());
    }

    #[test]
    fn test_safe_addresses() {
        init_test_mode();
        
        // Should allow localhost
        assert!(validate_test_host_config("127.0.0.1", 22, "TEST_fingerprint").is_ok());
        assert!(validate_test_host_config("::1", 22, "test_fingerprint").is_ok());
        
        // Should allow private ranges
        assert!(validate_test_host_config("192.168.1.100", 22, "TEST_fingerprint").is_ok());
        assert!(validate_test_host_config("10.0.0.1", 22, "test_key").is_ok());
        
        // Should block public addresses
        assert!(validate_test_host_config("8.8.8.8", 22, "TEST_fingerprint").is_err());
        assert!(validate_test_host_config("1.1.1.1", 22, "test_fingerprint").is_err());
    }

    #[test]
    fn test_fingerprint_validation() {
        init_test_mode();
        
        // Should allow test fingerprints
        assert!(validate_test_host_config("127.0.0.1", 22, "TEST_fingerprint").is_ok());
        assert!(validate_test_host_config("127.0.0.1", 22, "sha256_test_key").is_ok());
        
        // Should block production-looking fingerprints
        assert!(validate_test_host_config("127.0.0.1", 22, "SHA256:realkey123").is_err());
        assert!(validate_test_host_config("127.0.0.1", 22, "production_key").is_err());
    }

    #[test]
    fn test_database_url_validation() {
        init_test_mode();
        
        // Should allow test databases
        assert!(validate_test_database_url("sqlite://test.db").is_ok());
        assert!(validate_test_database_url("sqlite:///tmp/test_database.db").is_ok());
        assert!(validate_test_database_url("postgresql://localhost/test_db").is_ok());
        
        // Should block production databases
        assert!(validate_test_database_url("postgresql://prod.company.com/main").is_err());
        assert!(validate_test_database_url("sqlite://production.db").is_err());
        assert!(validate_test_database_url("mysql://live-server/data").is_err());
    }
}