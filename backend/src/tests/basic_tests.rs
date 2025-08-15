/// Basic tests for SSH Key Manager
/// 
/// These tests verify core functionality using the actual API
/// All tests use mock SSH clients and isolated test databases

use super::safety::init_test_mode;
use super::test_utils::TestConfig;
use crate::models::{NewUser, User, NewHost, Host, NewPublicUserKey, PublicUserKey};

#[cfg(test)]
mod user_tests {
    use super::*;

    #[tokio::test]
    async fn test_create_and_get_user() {
        init_test_mode();
        let test_config = TestConfig::new().await;
        let mut conn = test_config.db_pool.get().unwrap();
        
        // Create a new user
        let new_user = NewUser {
            username: "test_user".to_string(),
        };
        
        // Insert using the actual API method
        let result = User::add_user(&mut conn, new_user);
        assert!(result.is_ok(), "Should be able to add user");
        
        // Get the user using the actual API method
        let user = User::get_user(&mut conn, "test_user".to_string());
        assert!(user.is_ok(), "Should be able to get user");
        let user = user.unwrap();
        assert_eq!(user.username, "test_user");
        assert!(user.enabled);
    }

    #[tokio::test]
    async fn test_disable_user() {
        init_test_mode();
        let test_config = TestConfig::new().await;
        let mut conn = test_config.db_pool.get().unwrap();
        
        // Create a user
        let new_user = NewUser {
            username: "disable_test".to_string(),
        };
        User::add_user(&mut conn, new_user).unwrap();
        
        // Get the user to verify it's enabled
        let user = User::get_user(&mut conn, "disable_test".to_string()).unwrap();
        assert!(user.enabled, "User should be enabled by default");
        
        // Disable the user using update_user
        let result = User::update_user(&mut conn, "disable_test", "disable_test", false);
        assert!(result.is_ok(), "Should be able to disable user");
        
        // Verify user is disabled
        let user = User::get_user(&mut conn, "disable_test".to_string()).unwrap();
        assert!(!user.enabled, "User should be disabled");
    }
}

#[cfg(test)]
mod host_tests {
    use super::*;

    #[tokio::test]
    async fn test_create_and_get_host() {
        init_test_mode();
        let test_config = TestConfig::new().await;
        let mut conn = test_config.db_pool.get().unwrap();
        
        // Create a new host
        let new_host = NewHost {
            name: "test_host".to_string(),
            address: "192.168.1.100".to_string(),
            port: 22,
            username: "ubuntu".to_string(),
            key_fingerprint: Some("TEST_fingerprint".to_string()),
            jump_via: None,
        };
        
        // Insert the host
        let result = Host::add_host(&mut conn, &new_host);
        assert!(result.is_ok(), "Should be able to add host: {:?}", result);
        
        // Get the host using async method
        let host = Host::get_from_name(conn, "test_host".to_string()).await;
        assert!(host.is_ok(), "Should be able to get host");
        let host = host.unwrap();
        assert!(host.is_some(), "Host should exist");
        let host = host.unwrap();
        assert_eq!(host.name, "test_host");
        assert_eq!(host.address, "192.168.1.100");
        assert_eq!(host.port, 22);
    }
}

#[cfg(test)]
mod key_tests {
    use super::*;

    #[tokio::test]
    async fn test_add_and_get_key() {
        init_test_mode();
        let test_config = TestConfig::new().await;
        let mut conn = test_config.db_pool.get().unwrap();
        
        // First create a user
        let new_user = NewUser {
            username: "key_test_user".to_string(),
        };
        User::add_user(&mut conn, new_user).unwrap();
        
        // Get the user to get the ID
        let user = User::get_user(&mut conn, "key_test_user".to_string()).unwrap();
        
        // Create a new key
        let algorithm = russh::keys::Algorithm::new("ssh-rsa").unwrap();
        let new_key = NewPublicUserKey::new(
            algorithm,
            "AAAAB3NzaC1yc2EAAAADAQABAAABgQC7vbqajDw".to_string(),
            Some("test@example.com".to_string()),
            user.id,
        );
        
        // Add the key
        let result = PublicUserKey::add_key(&mut conn, new_key);
        assert!(result.is_ok(), "Should be able to add key");
        
        // Get user's keys
        let keys = user.get_keys(&mut conn);
        assert!(keys.is_ok(), "Should be able to get keys");
        let keys = keys.unwrap();
        assert_eq!(keys.len(), 1, "User should have one key");
        assert_eq!(keys[0].key_type, "ssh-rsa");
    }
}

#[cfg(test)]
mod authorization_tests {
    use super::*;

    #[tokio::test]
    async fn test_authorize_user_on_host() {
        init_test_mode();
        let test_config = TestConfig::new().await;
        let pool = test_config.db_pool.clone();
        let mut conn = pool.get().unwrap();
        
        // Create a user
        let new_user = NewUser {
            username: "auth_user".to_string(),
        };
        User::add_user(&mut conn, new_user).unwrap();
        let user = User::get_user(&mut conn, "auth_user".to_string()).unwrap();
        
        // Create a host
        let new_host = NewHost {
            name: "auth_host".to_string(),
            address: "192.168.1.200".to_string(),
            port: 22,
            username: "ubuntu".to_string(),
            key_fingerprint: Some("TEST_auth_key".to_string()),
            jump_via: None,
        };
        Host::add_host(&mut conn, &new_host).unwrap();
        
        // Get host to get ID - need to get a new connection for async
        let conn2 = pool.get().unwrap();
        let host = Host::get_from_name(conn2, "auth_host".to_string()).await.unwrap().unwrap();
        
        // Authorize user on host
        let mut conn3 = pool.get().unwrap();
        let result = Host::authorize_user(
            &mut conn3,
            host.id,
            user.id,
            "ubuntu".to_string(),
            Some("no-port-forwarding".to_string()),
        );
        assert!(result.is_ok(), "Should be able to authorize user");
        
        // Get authorizations for the host
        let auths = host.get_authorized_users(&mut conn3);
        assert!(auths.is_ok(), "Should be able to get authorized users");
        let auths = auths.unwrap();
        assert_eq!(auths.len(), 1, "Should have one authorization");
    }
}

#[cfg(test)]
mod safety_integration_tests {
    use super::*;
    use crate::tests::mock_ssh::MockSshClient;

    #[tokio::test]
    async fn test_mock_ssh_client_safety() {
        init_test_mode();
        let test_config = TestConfig::new().await;
        
        // Create a mock SSH client
        let mock_client = MockSshClient::new(
            test_config.db_pool.clone(),
            test_config.config.ssh.clone()
        );
        
        // Verify it's safe to use
        assert!(mock_client.is_mock(), "Should be using mock client");
        
        // Create a mock host
        let mock_host = Host {
            id: 1,
            name: "test_host".to_string(),
            address: "127.0.0.1".to_string(),
            port: 22,
            username: "ubuntu".to_string(),
            key_fingerprint: Some("TEST_mock_key".to_string()),
            jump_via: None,
        };
        
        // Try to get authorized keys (should return mock data)
        let result = mock_client.get_authorized_keys(mock_host).await;
        
        // It should work without real SSH
        assert!(result.is_ok(), "Mock SSH should work");
    }
}