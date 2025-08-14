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
pub mod safety_verification;

// Core test modules
pub mod basic_tests;