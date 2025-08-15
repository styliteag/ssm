/// Test modules for SSH Key Manager backend
/// 
/// This module contains comprehensive unit and integration tests for all major components
/// of the SSH Key Manager backend API, including authentication, CRUD operations,
/// SSH client functionality, and database operations.
///
/// 🛡️ SAFETY: All tests use mock SSH clients and isolated test databases to prevent
/// any modifications to production systems.
///
/// ## Test Organization
/// - **Safety & Mocking**: Core safety infrastructure and mock SSH clients
/// - **Basic Tests**: Database operations and core functionality 
/// - **HTTP API Tests**: Organized by functionality (auth, users, hosts, keys, errors)
/// - **Shared Utilities**: Common test helpers and service creation macros

// Safety and mocking infrastructure (always enabled)
pub mod safety;
pub mod mock_ssh;
pub mod test_utils;
pub mod safety_verification;

// Core test modules
pub mod basic_tests;
pub mod mock_ssh_tests;

// Shared HTTP test utilities
pub mod http_test_helpers;

// HTTP API tests organized by functionality
pub mod http_auth_tests;
pub mod http_user_tests;
pub mod http_host_tests;
pub mod http_key_tests;
pub mod http_error_tests;
pub mod http_diff_tests;
pub mod http_authorization_tests;
pub mod http_security_tests;
pub mod http_authentication_tests;

// Comprehensive authentication protection and session tests
pub mod http_endpoint_auth_protection_tests;
pub mod http_session_auth_tests;
pub mod http_session_auth_functional_tests;

// SSH and integration tests
pub mod ssh_integration_tests;