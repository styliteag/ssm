# SSH Key Manager Backend - Testing Guide

This document provides comprehensive instructions for running and understanding the test suite for the SSH Key Manager backend.

## Overview

The SSH Key Manager backend includes a comprehensive test suite with **107 tests** covering all major functionality areas. All tests use mock SSH clients and isolated test databases to ensure safety and prevent any modifications to production systems.

## Quick Start

### Prerequisites

- Rust 1.70+ installed
- SQLite development libraries
- All dependencies from `Cargo.toml`

### Running All Tests

```bash
# Run all tests
cargo test

# Run tests with output
cargo test -- --nocapture

# Run specific test modules
cargo test http_user_tests
cargo test ssh_integration_tests
```

### Running Tests by Category

```bash
# HTTP API tests
cargo test http_

# SSH integration tests
cargo test ssh_integration_tests

# Security tests
cargo test http_security_tests

# Authentication tests
cargo test http_authentication_tests
```

## Test Categories

### 1. Core Functionality Tests (65 tests)

#### HTTP User Management Tests (21 tests)
**Module:** `src/tests/http_user_tests.rs`

Tests comprehensive user management API functionality:
- User creation, retrieval, update, deletion (CRUD)
- Data validation and structure verification
- User key assignment and management
- Error handling for invalid operations

```bash
cargo test http_user_tests
```

**Key Test Examples:**
- `test_create_user_with_validation` - Validates user data structure
- `test_user_crud_operations` - Complete CRUD workflow
- `test_user_key_management` - SSH key assignment

#### HTTP Host Management Tests (21 tests)
**Module:** `src/tests/http_host_tests.rs`

Tests host management API with comprehensive validation:
- Host creation, retrieval, update, deletion
- Jump host configuration testing
- Host data structure validation
- Network configuration validation

```bash
cargo test http_host_tests
```

**Key Test Examples:**
- `test_create_host_with_validation` - Host data structure verification
- `test_host_crud_operations` - Complete host lifecycle
- `test_jump_host_functionality` - Jump host configuration

#### HTTP Key Management Tests (23 tests)
**Module:** `src/tests/http_key_tests.rs`

Tests SSH key management with multiple algorithms:
- Ed25519, RSA, ECDSA key testing
- Key format validation and fingerprint generation
- Key assignment and authorization
- Algorithm-specific validation

```bash
cargo test http_key_tests
```

**Key Test Examples:**
- `test_key_algorithm_validation` - Multiple SSH key types
- `test_key_fingerprint_generation` - Fingerprint validation
- `test_key_crud_operations` - Key lifecycle management

### 2. Advanced API Tests (42 tests)

#### Diff Endpoint Tests (7 tests)
**Module:** `src/tests/http_diff_tests.rs`

Tests key difference calculation and display:
- Host-to-host key comparisons
- Login-specific key differences
- Authorization filtering in diffs
- Complex scenarios with jump hosts

```bash
cargo test http_diff_tests
```

#### Authorization Management Tests (8 tests)
**Module:** `src/tests/http_authorization_tests.rs`

Tests user-host authorization management:
- Authorization CRUD operations
- Permission validation and filtering
- SSH options testing
- Multi-user authorization scenarios

```bash
cargo test http_authorization_tests
```

#### Security and Input Validation Tests (10 tests)
**Module:** `src/tests/http_security_tests.rs`

Comprehensive security testing:
- SQL injection prevention
- XSS (Cross-Site Scripting) protection
- Malformed JSON handling
- Oversized payload protection
- Special character handling

```bash
cargo test http_security_tests
```

**Security Test Examples:**
- `test_sql_injection_prevention` - SQL injection attack prevention
- `test_xss_prevention` - Cross-site scripting protection
- `test_malformed_json_handling` - Malformed input handling

#### Authentication and Session Tests (10 tests)
**Module:** `src/tests/http_authentication_tests.rs`

Tests authentication and session management:
- Session creation and validation
- Login/logout functionality
- Session isolation and security
- Authentication bypass prevention
- Cookie tampering protection

```bash
cargo test http_authentication_tests
```

#### SSH Integration Tests (8 tests)
**Module:** `src/tests/ssh_integration_tests.rs`

Tests SSH operations with mock clients:
- SSH connection establishment
- Key deployment workflows
- Jump host connectivity
- Error handling and validation
- Authorized keys synchronization

```bash
cargo test ssh_integration_tests
```

## Test Architecture

### Safety Framework

All tests use a comprehensive safety framework to prevent production system modifications:

**Safety Features:**
- **Mock SSH Clients**: No real SSH connections
- **Isolated Databases**: Each test uses a separate SQLite database
- **Test Mode**: Safety flag prevents actual deployment operations
- **Serial Execution**: Tests run sequentially to prevent conflicts

### Test Utilities

**Core Components:**
- `TestConfig`: Isolated test environment setup
- `MockSshClient`: Safe SSH operation simulation
- `create_inline_test_service!`: HTTP service creation macro
- `extract_json`: Response parsing helper

### Test Data Management

**Database Isolation:**
```rust
// Each test gets isolated database
let test_config = TestConfig::new().await;
let mut conn = test_config.db_pool.get().unwrap();
```

**Mock SSH Operations:**
```rust
// Safe SSH client for testing
let mock_client = MockSshClient::new(
    test_config.db_pool.clone(),
    test_config.config.ssh.clone()
);
```

## Running Specific Test Scenarios

### Development Workflow Tests

```bash
# Test complete user workflow
cargo test test_user_crud_operations

# Test host management with jump hosts
cargo test test_jump_host_functionality

# Test key deployment workflow
cargo test test_key_deployment_workflow
```

### Security Validation Tests

```bash
# Run all security tests
cargo test http_security_tests

# Test specific security scenarios
cargo test test_sql_injection_prevention
cargo test test_xss_prevention
cargo test test_authentication_bypass_attempts
```

### Integration Tests

```bash
# SSH integration tests
cargo test ssh_integration_tests

# Authorization tests
cargo test http_authorization_tests

# Authentication flow tests
cargo test http_authentication_tests
```

## Test Configuration

### Environment Variables

```bash
# Enable detailed logging
export RUST_LOG=debug

# Test database configuration
export TEST_DATABASE_URL=sqlite::memory:

# SSH client configuration for tests
export SSH_TEST_MODE=true
```

### Test Dependencies

The test suite includes these additional dependencies:
- `serial_test` - Prevents test conflicts
- `urlencoding` - URL encoding for security tests
- `actix-web::test` - HTTP service testing
- `serde_json` - JSON manipulation

## Common Test Patterns

### HTTP API Testing Pattern

```rust
#[tokio::test]
#[serial]
async fn test_example() {
    let (app, test_config) = create_inline_test_service!();
    
    // Create test data
    let mut conn = test_config.db_pool.get().unwrap();
    
    // Make HTTP request
    let req = test::TestRequest::get()
        .uri("/api/endpoint")
        .to_request();
    
    let resp = test::call_service(&app, req).await;
    
    // Validate response
    assert_eq!(resp.status(), StatusCode::OK);
    let json = extract_json(resp).await;
    assert_eq!(json["success"], true);
}
```

### Database Operation Testing

```rust
// Create test models
let new_user = NewUser {
    username: "testuser".to_string(),
};
let username = User::add_user(&mut conn, new_user).expect("Failed to create user");

// Validate database state
let user = User::get_user(&mut conn, username).expect("Failed to get user");
assert_eq!(user.username, "testuser");
```

### SSH Integration Testing

```rust
let mock_client = MockSshClient::new(
    test_config.db_pool.clone(),
    test_config.config.ssh.clone()
);

// Test SSH operations safely
let keys_result = mock_client.get_authorized_keys(host).await;
assert!(keys_result.is_ok());
```

## Test Output and Debugging

### Verbose Output

```bash
# Show all test output
cargo test -- --nocapture

# Show specific test output
cargo test test_name -- --nocapture --exact
```

### Logging Configuration

```bash
# Enable debug logging for all modules
RUST_LOG=debug cargo test

# Enable logging for specific modules
RUST_LOG=ssm::tests=debug cargo test

# Show SQL queries (useful for debugging)
RUST_LOG=diesel=debug cargo test
```

### Test Filtering

```bash
# Run only user-related tests
cargo test user

# Run only integration tests
cargo test integration

# Run tests matching pattern
cargo test "test_create_*"

# Skip slow tests
cargo test --skip integration
```

## Continuous Integration

### GitHub Actions Example

```yaml
name: Tests
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v2
      - uses: actions-rs/toolchain@v1
        with:
          toolchain: stable
      - name: Run tests
        run: cargo test --verbose
```

### Pre-commit Testing

```bash
# Quick validation
cargo test --lib

# Full test suite
cargo test

# Security-focused tests
cargo test http_security_tests http_authentication_tests
```

## Troubleshooting

### Common Issues

**Database Connection Errors:**
```bash
# Ensure SQLite is available
sudo apt-get install libsqlite3-dev  # Ubuntu/Debian
brew install sqlite                   # macOS
```

**Test Conflicts:**
```bash
# Run tests sequentially if conflicts occur
cargo test -- --test-threads=1
```

**Mock SSH Issues:**
```bash
# Verify test mode is enabled
export SSH_TEST_MODE=true
cargo test ssh_integration_tests
```

### Performance Issues

**Slow Test Execution:**
```bash
# Run subset of tests
cargo test --package backend --test http_user_tests

# Skip integration tests for faster feedback
cargo test --skip integration --skip ssh_
```

## Contributing New Tests

### Test Structure

1. Create test in appropriate module
2. Use `#[tokio::test]` and `#[serial]` attributes
3. Include safety initialization: `crate::tests::safety::init_test_mode()`
4. Use isolated test configuration
5. Include comprehensive assertions

### Example New Test

```rust
#[tokio::test]
#[serial]
async fn test_new_feature() {
    crate::tests::safety::init_test_mode();
    let (app, test_config) = create_inline_test_service!();
    
    // Test implementation
    // ...
    
    log::info!("✅ New feature test passed");
}
```

### Security Test Guidelines

- Always test for injection attacks
- Validate input sanitization
- Test authorization bypass attempts
- Verify error message safety
- Test with malformed inputs

## Test Coverage Summary

- **Total Tests**: 107
- **HTTP API Tests**: 65
- **Advanced API Tests**: 42
- **Security Tests**: 20+
- **Integration Tests**: 15+
- **Coverage Areas**: Authentication, CRUD operations, SSH integration, security validation, error handling

This comprehensive test suite ensures the SSH Key Manager backend is robust, secure, and reliable across all major functionality areas.