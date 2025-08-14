/// Test modules for SSH Key Manager backend
/// 
/// This module contains comprehensive unit and integration tests for all major components
/// of the SSH Key Manager backend API, including authentication, CRUD operations,
/// SSH client functionality, and database operations.
///
/// 🛡️ SAFETY: All tests use mock SSH clients and isolated test databases to prevent
/// any modifications to production systems.

// Safety and mocking infrastructure (always enabled)
pub mod safety;
pub mod mock_ssh;
pub mod test_utils;

// Core test modules
pub mod simple_tests;
pub mod auth_tests;
pub mod host_tests;
pub mod user_tests;
pub mod key_tests;
pub mod authorization_tests;
pub mod diff_tests;
pub mod api_types_tests;
pub mod database_tests;
pub mod ssh_tests;