/// Modern Test Framework
/// 
/// Clean, minimal testing setup that actually works.

// Core test utilities - keep these minimal
pub mod safety;
pub mod test_config;

// Test modules
pub mod basic_tests;
pub mod test_api;
pub mod security_first_api_tests;   // THE NEW STANDARD - inline security tests
pub mod user_lifecycle_simple;      // SIMPLIFIED E2E workflow tests
pub mod real_http_auth_test;         // REAL HTTP Authentication with cookies, CSRF, sessions!
pub mod real_http_auth_success;     // PROOF that real HTTP auth works perfectly!
pub mod complete_workflow_test;      // COMPLETE E2E workflow: user → key → host → authorization → diff