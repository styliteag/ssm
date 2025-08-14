use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::Mutex;
use serde::{Deserialize, Serialize};

use crate::tests::safety::{init_test_mode, test_only};
use crate::ssh::{SshKeyfiles, KeyDiffItem, PlainSshKeyfileResponse};
use crate::models::Host;
use crate::{ConnectionPool, SshConfig};

/// Comprehensive mock SSH client for testing without real connections
#[derive(Clone)]
pub struct MockSshClient {
    inner: Arc<MockSshClientInner>,
}

struct MockSshClientInner {
    // Mock responses for different operations
    keyfiles_responses: Mutex<HashMap<String, SshKeyfiles>>,
    diff_responses: Mutex<HashMap<String, Vec<KeyDiffItem>>>,
    execution_responses: Mutex<HashMap<String, (u32, String)>>,
    
    // Track operation calls for verification
    operation_log: Mutex<Vec<MockOperation>>,
    
    // Simulate connection failures
    connection_failures: Mutex<HashMap<String, String>>,
    
    // Simulate script installation results
    script_install_results: Mutex<HashMap<String, bool>>,
}

#[derive(Debug, Clone)]
pub struct MockOperation {
    pub operation_type: MockOperationType,
    pub host: String,
    pub login: Option<String>,
    pub timestamp: std::time::SystemTime,
    pub success: bool,
}

#[derive(Debug, Clone)]
pub enum MockOperationType {
    Connect,
    GetKeyfiles,
    SetAuthorizedKeys,
    KeyDiff,
    InstallScript,
    Execute,
}

impl MockSshClient {
    pub fn new(_pool: ConnectionPool, _config: SshConfig) -> Self {
        test_only!();
        init_test_mode();
        
        log::info!("🤖 MockSshClient created - NO REAL SSH CONNECTIONS WILL BE MADE");
        
        Self {
            inner: Arc::new(MockSshClientInner {
                keyfiles_responses: Mutex::new(HashMap::new()),
                diff_responses: Mutex::new(HashMap::new()),
                execution_responses: Mutex::new(HashMap::new()),
                operation_log: Mutex::new(Vec::new()),
                connection_failures: Mutex::new(HashMap::new()),
                script_install_results: Mutex::new(HashMap::new()),
            }),
        }
    }

    /// Configure mock response for get_authorized_keys
    pub async fn mock_keyfiles_response(&self, host_name: &str, response: SshKeyfiles) {
        test_only!();
        let mut responses = self.inner.keyfiles_responses.lock().await;
        responses.insert(host_name.to_string(), response);
        log::debug!("🤖 Mock keyfiles response set for host: {}", host_name);
    }

    /// Configure mock response for key_diff
    pub async fn mock_diff_response(&self, host_name: &str, login: &str, diff: Vec<KeyDiffItem>) {
        test_only!();
        let key = format!("{}:{}", host_name, login);
        let mut responses = self.inner.diff_responses.lock().await;
        responses.insert(key, diff);
        log::debug!("🤖 Mock diff response set for {}:{}", host_name, login);
    }

    /// Configure mock response for command execution
    pub async fn mock_execution_response(&self, command: &str, exit_code: u32, output: &str) {
        test_only!();
        let mut responses = self.inner.execution_responses.lock().await;
        responses.insert(command.to_string(), (exit_code, output.to_string()));
        log::debug!("🤖 Mock execution response set for command: {}", command);
    }

    /// Simulate connection failure for a host
    pub async fn simulate_connection_failure(&self, host_name: &str, error_message: &str) {
        test_only!();
        let mut failures = self.inner.connection_failures.lock().await;
        failures.insert(host_name.to_string(), error_message.to_string());
        log::debug!("🤖 Mock connection failure set for host: {}", host_name);
    }

    /// Configure script installation result
    pub async fn mock_script_install_result(&self, host_name: &str, success: bool) {
        test_only!();
        let mut results = self.inner.script_install_results.lock().await;
        results.insert(host_name.to_string(), success);
        log::debug!("🤖 Mock script install result set for host: {} -> {}", host_name, success);
    }

    /// Get operation log for verification in tests
    pub async fn get_operation_log(&self) -> Vec<MockOperation> {
        test_only!();
        let log = self.inner.operation_log.lock().await;
        log.clone()
    }

    /// Clear all mock data
    pub async fn clear_all_mocks(&self) {
        test_only!();
        self.inner.keyfiles_responses.lock().await.clear();
        self.inner.diff_responses.lock().await.clear();
        self.inner.execution_responses.lock().await.clear();
        self.inner.operation_log.lock().await.clear();
        self.inner.connection_failures.lock().await.clear();
        self.inner.script_install_results.lock().await.clear();
        log::debug!("🤖 All mock data cleared");
    }

    /// Verify that an operation was called
    pub async fn verify_operation_called(&self, op_type: MockOperationType, host: &str) -> bool {
        test_only!();
        let log = self.inner.operation_log.lock().await;
        log.iter().any(|op| {
            matches!(&op.operation_type, op_type) && op.host == host
        })
    }

    /// Get count of operations by type
    pub async fn get_operation_count(&self, op_type: MockOperationType) -> usize {
        test_only!();
        let log = self.inner.operation_log.lock().await;
        log.iter().filter(|op| matches!(&op.operation_type, op_type)).count()
    }

    // Mock implementations of SSH client methods
    
    async fn log_operation(&self, operation_type: MockOperationType, host: &str, login: Option<&str>, success: bool) {
        let operation = MockOperation {
            operation_type,
            host: host.to_string(),
            login: login.map(|s| s.to_string()),
            timestamp: std::time::SystemTime::now(),
            success,
        };
        
        let mut log = self.inner.operation_log.lock().await;
        log.push(operation);
    }

    pub async fn get_authorized_keys(&self, host: Host) -> Result<SshKeyfiles, crate::ssh::SshClientError> {
        test_only!();
        log::info!("🤖 MockSshClient::get_authorized_keys called for host: {}", host.name);
        
        // Check for simulated connection failure
        {
            let failures = self.inner.connection_failures.lock().await;
            if let Some(error_msg) = failures.get(&host.name) {
                self.log_operation(MockOperationType::Connect, &host.name, None, false).await;
                return Err(crate::ssh::SshClientError::ExecutionError(error_msg.clone()));
            }
        }
        
        self.log_operation(MockOperationType::Connect, &host.name, None, true).await;
        self.log_operation(MockOperationType::GetKeyfiles, &host.name, None, true).await;
        
        // Return mock response
        let responses = self.inner.keyfiles_responses.lock().await;
        let response = responses.get(&host.name).cloned().unwrap_or_else(|| {
            // Default mock response
            SshKeyfiles(vec![
                PlainSshKeyfileResponse {
                    login: "root".to_string(),
                    has_pragma: true,
                    readonly_condition: None,
                    keyfile: "# Auto-generated by Secure SSH Manager. DO NOT EDIT!\nssh-rsa AAAAB3... root@localhost\n".to_string(),
                },
                PlainSshKeyfileResponse {
                    login: "ubuntu".to_string(),
                    has_pragma: true,
                    readonly_condition: None,
                    keyfile: "# Auto-generated by Secure SSH Manager. DO NOT EDIT!\nssh-rsa AAAAB3... ubuntu@localhost\n".to_string(),
                },
            ])
        });
        
        Ok(response)
    }

    pub async fn set_authorized_keys(
        &self,
        host_name: String,
        login: String,
        authorized_keys: String,
    ) -> Result<(), crate::ssh::SshClientError> {
        test_only!();
        log::info!("🤖 MockSshClient::set_authorized_keys called for {}:{}", host_name, login);
        
        // Check for simulated connection failure
        {
            let failures = self.inner.connection_failures.lock().await;
            if let Some(error_msg) = failures.get(&host_name) {
                self.log_operation(MockOperationType::Connect, &host_name, Some(&login), false).await;
                return Err(crate::ssh::SshClientError::ExecutionError(error_msg.clone()));
            }
        }
        
        self.log_operation(MockOperationType::Connect, &host_name, Some(&login), true).await;
        self.log_operation(MockOperationType::SetAuthorizedKeys, &host_name, Some(&login), true).await;
        
        log::debug!("🤖 Mock authorized_keys updated for {}:{} ({} bytes)", host_name, login, authorized_keys.len());
        Ok(())
    }

    pub async fn key_diff(
        &self,
        new_keyfile: &str,
        host_name: String,
        login: String,
    ) -> Result<Vec<KeyDiffItem>, crate::ssh::SshClientError> {
        test_only!();
        log::info!("🤖 MockSshClient::key_diff called for {}:{}", host_name, login);
        
        let key = format!("{}:{}", host_name, login);
        
        // Check for simulated connection failure
        {
            let failures = self.inner.connection_failures.lock().await;
            if let Some(error_msg) = failures.get(&host_name) {
                self.log_operation(MockOperationType::Connect, &host_name, Some(&login), false).await;
                return Err(crate::ssh::SshClientError::ExecutionError(error_msg.clone()));
            }
        }
        
        self.log_operation(MockOperationType::Connect, &host_name, Some(&login), true).await;
        self.log_operation(MockOperationType::KeyDiff, &host_name, Some(&login), true).await;
        
        // Return mock diff response
        let responses = self.inner.diff_responses.lock().await;
        let diff = responses.get(&key).cloned().unwrap_or_else(|| {
            // Default mock diff - simulate adding a key
            vec![
                KeyDiffItem::Added(format!("+ {}", new_keyfile.lines().next().unwrap_or("ssh-rsa AAAAB3... test@example.com"))),
            ]
        });
        
        log::debug!("🤖 Mock diff generated for {}:{} ({} changes)", host_name, login, diff.len());
        Ok(diff)
    }

    pub async fn install_script_on_host(&self, host_id: i32) -> Result<(), crate::ssh::SshClientError> {
        test_only!();
        log::info!("🤖 MockSshClient::install_script_on_host called for host_id: {}", host_id);
        
        let host_name = format!("host_{}", host_id);
        
        // Check for simulated connection failure
        {
            let failures = self.inner.connection_failures.lock().await;
            if let Some(error_msg) = failures.get(&host_name) {
                self.log_operation(MockOperationType::Connect, &host_name, None, false).await;
                return Err(crate::ssh::SshClientError::ExecutionError(error_msg.clone()));
            }
        }
        
        // Check script install result
        let results = self.inner.script_install_results.lock().await;
        let success = results.get(&host_name).copied().unwrap_or(true);
        
        self.log_operation(MockOperationType::Connect, &host_name, None, true).await;
        self.log_operation(MockOperationType::InstallScript, &host_name, None, success).await;
        
        if success {
            log::debug!("🤖 Mock script installation successful for host_id: {}", host_id);
            Ok(())
        } else {
            Err(crate::ssh::SshClientError::ExecutionError("Mock script installation failed".to_string()))
        }
    }

    /// Mock get own SSH key (returns test key)
    pub fn get_own_key_openssh(&self) -> String {
        test_only!();
        "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC7vbqajDw5XJjfsQM1dLDEeuxWiZQ test-ssm-key".to_string()
    }

    pub fn get_own_key_b64(&self) -> String {
        test_only!();
        "AAAAB3NzaC1yc2EAAAADAQABAAABgQC7vbqajDw5XJjfsQM1dLDEeuxWiZQ".to_string()
    }
}

/// Helper functions for creating common mock responses

pub fn create_mock_keyfiles_response(logins: Vec<&str>) -> SshKeyfiles {
    test_only!();
    SshKeyfiles(
        logins
            .into_iter()
            .map(|login| PlainSshKeyfileResponse {
                login: login.to_string(),
                has_pragma: true,
                readonly_condition: None,
                keyfile: format!(
                    "# Auto-generated by Secure SSH Manager. DO NOT EDIT!\nssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC7vbqajDw5XJjfsQM1dLDEeuxWiZQ test-key-{}@example.com\n",
                    login
                ),
            })
            .collect(),
    )
}

pub fn create_mock_diff_response(added_keys: Vec<&str>, removed_keys: Vec<&str>) -> Vec<KeyDiffItem> {
    test_only!();
    let mut diff = Vec::new();
    
    for key in added_keys {
        diff.push(KeyDiffItem::Added(format!("+ {}", key)));
    }
    
    for key in removed_keys {
        diff.push(KeyDiffItem::Removed(format!("- {}", key)));
    }
    
    diff
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tests::test_utils::TestConfig;

    #[tokio::test]
    async fn test_mock_ssh_client_creation() {
        let test_config = TestConfig::new().await;
        let mock_client = MockSshClient::new(test_config.db_pool, test_config.config.ssh);
        
        // Verify no operations logged initially
        let log = mock_client.get_operation_log().await;
        assert!(log.is_empty());
    }

    #[tokio::test]
    async fn test_mock_keyfiles_response() {
        let test_config = TestConfig::new().await;
        let mock_client = MockSshClient::new(test_config.db_pool, test_config.config.ssh);
        
        // Set up mock response
        let mock_response = create_mock_keyfiles_response(vec!["root", "ubuntu"]);
        mock_client.mock_keyfiles_response("test-host", mock_response.clone()).await;
        
        // Create test host
        let host = Host {
            id: 1,
            name: "test-host".to_string(),
            address: "127.0.0.1".to_string(),
            port: 22,
            username: "ubuntu".to_string(),
            key_fingerprint: "TEST_fingerprint".to_string(),
            jump_via: None,
        };
        
        // Test the mock response
        let result = mock_client.get_authorized_keys(host).await.unwrap();
        assert_eq!(result.0.len(), 2);
        assert_eq!(result.0[0].login, "root");
        assert_eq!(result.0[1].login, "ubuntu");
        
        // Verify operations were logged
        assert!(mock_client.verify_operation_called(MockOperationType::Connect, "test-host").await);
        assert!(mock_client.verify_operation_called(MockOperationType::GetKeyfiles, "test-host").await);
    }

    #[tokio::test]
    async fn test_mock_connection_failure() {
        let test_config = TestConfig::new().await;
        let mock_client = MockSshClient::new(test_config.db_pool, test_config.config.ssh);
        
        // Simulate connection failure
        mock_client.simulate_connection_failure("test-host", "Connection refused").await;
        
        let host = Host {
            id: 1,
            name: "test-host".to_string(),
            address: "127.0.0.1".to_string(),
            port: 22,
            username: "ubuntu".to_string(),
            key_fingerprint: "TEST_fingerprint".to_string(),
            jump_via: None,
        };
        
        // Test connection failure
        let result = mock_client.get_authorized_keys(host).await;
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("Connection refused"));
    }
}