# SSH Key Manager Backend Test Suite

This directory contains comprehensive unit and integration tests for the SSH Key Manager backend API.

## Test Structure

The test suite is organized into modules that correspond to the main application components:

### Core Test Modules

- **`test_utils.rs`** - Common utilities, test configuration, and helper functions
- **`auth_tests.rs`** - Authentication and session management tests
- **`host_tests.rs`** - Host CRUD operations and SSH connection tests
- **`user_tests.rs`** - User management and profile tests
- **`key_tests.rs`** - SSH key operations and validation tests
- **`authorization_tests.rs`** - User-host authorization and permission tests
- **`diff_tests.rs`** - Key comparison and deployment logic tests
- **`api_types_tests.rs`** - API response types and serialization tests
- **`database_tests.rs`** - Database operations, constraints, and transaction tests
- **`ssh_tests.rs`** - SSH client operations with mocked connections

## Test Coverage Areas

### 1. Authentication Tests (`auth_tests.rs`)
- Login/logout functionality
- Password verification (bcrypt/Apache htpasswd)
- Session management
- Authentication status checks
- Invalid credential handling

### 2. Host Management Tests (`host_tests.rs`)
- CRUD operations for hosts
- SSH connection validation
- Host key fingerprint management
- Jumphost relationships
- Authorization management
- Host deletion with dependency checks

### 3. User Management Tests (`user_tests.rs`)
- User CRUD operations
- User enable/disable functionality
- User key associations
- User authorization listings
- Input validation and constraints

### 4. SSH Key Tests (`key_tests.rs`)
- Key creation and validation
- OpenSSH format parsing
- Key comment management
- Key deletion and cleanup
- SSH key format validation
- Bulk key operations

### 5. Authorization Tests (`authorization_tests.rs`)
- User-host permission mapping
- Authorization options handling
- Duplicate authorization prevention
- Authorization matrix operations
- Access control validation

### 6. Diff Tests (`diff_tests.rs`)
- Key comparison algorithms
- Authorized keys generation
- Deployment simulation
- Multi-user scenarios
- Disabled user handling
- Change detection logic

### 7. API Types Tests (`api_types_tests.rs`)
- Response serialization/deserialization
- Error handling and status codes
- Pagination functionality
- Input validation
- Edge cases and type safety

### 8. Database Tests (`database_tests.rs`)
- CRUD operations
- Foreign key constraints
- Cascade delete operations
- Transaction handling
- Concurrent operations
- Data integrity checks
- Performance benchmarks

### 9. SSH Client Tests (`ssh_tests.rs`)
- Mock SSH operations
- Connection error handling
- Key deployment simulation
- Cache behavior testing
- Timeout and retry logic
- Concurrent SSH operations

## Test Utilities

### TestConfig
The `TestConfig` struct provides isolated test environments:
- Temporary databases
- Test authentication files
- Mock SSH keys
- Clean test data setup

### Helper Functions
- `cleanup_test_data()` - Clean test database
- `insert_test_*()` - Create test entities
- `create_test_*_data()` - Generate test payloads
- `random_string()` - Generate unique identifiers

### Mock Services
- `MockSshClient` - SSH operations without real connections
- `MockSshOperations` - Configurable SSH response mocking

## Running Tests

### All Tests
```bash
cargo test
```

### Specific Module
```bash
cargo test auth_tests
cargo test host_tests
cargo test --test database_tests
```

### With Output
```bash
cargo test -- --nocapture
```

### Parallel Execution
```bash
cargo test -- --test-threads=4
```

### Integration Tests Only
```bash
cargo test --test '*'
```

## Test Configuration

### Environment Variables
- `RUST_LOG=debug` - Enable debug logging
- `DATABASE_URL` - Override test database
- `TEST_PARALLEL=false` - Disable parallel test execution

### Dependencies
The test suite uses these additional dependencies:
- `tempfile` - Temporary files and directories
- `rand` - Random test data generation
- `uuid` - Unique identifiers
- `mockall` - Mock object generation
- `serial_test` - Sequential test execution when needed

## Test Patterns

### 1. Isolated Tests
Each test creates its own test environment:
```rust
#[tokio::test]
async fn test_example() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    // Test implementation
}
```

### 2. Error Testing
Tests verify both success and failure scenarios:
```rust
// Test success case
let response = service.create_item(valid_data).await;
assert!(response.is_ok());

// Test error case
let response = service.create_item(invalid_data).await;
assert!(response.is_err());
```

### 3. Integration Testing
Tests use the full application stack:
```rust
let app = test::init_service(
    App::new()
        .app_data(pool)
        .configure(routes::config)
).await;

let req = test::TestRequest::post()
    .uri("/api/endpoint")
    .set_json(&payload)
    .to_request();

let resp = test::call_service(&app, req).await;
```

## Continuous Integration

The test suite is designed to run reliably in CI environments:
- All external dependencies are mocked
- Tests use isolated temporary resources
- Parallel execution is supported
- Tests clean up after themselves

## Coverage Goals

The test suite aims for comprehensive coverage:
- **Unit Tests**: All public functions and methods
- **Integration Tests**: All API endpoints
- **Error Paths**: All error conditions
- **Edge Cases**: Boundary conditions and invalid inputs
- **Concurrency**: Multi-threaded scenarios
- **Performance**: Reasonable execution times

## Best Practices

1. **Independence**: Tests don't depend on each other
2. **Clarity**: Test names describe the scenario being tested
3. **Reliability**: Tests pass consistently in any environment
4. **Speed**: Tests execute quickly for rapid feedback
5. **Maintainability**: Tests are easy to understand and modify

## Troubleshooting

### Common Issues

1. **Database Lock**: Ensure `cleanup_test_data()` is called
2. **Port Conflicts**: Use random ports or port 0
3. **File Permissions**: Ensure test directories are writable
4. **Async Issues**: Use `#[tokio::test]` for async tests

### Debug Tips

1. Enable logging: `RUST_LOG=debug cargo test`
2. Run single test: `cargo test test_name -- --exact`
3. Show output: `cargo test -- --nocapture`
4. Disable parallel: `cargo test -- --test-threads=1`

## Contributing

When adding new tests:

1. Follow the existing module organization
2. Use appropriate test utilities
3. Include both positive and negative test cases
4. Add proper cleanup
5. Document complex test scenarios
6. Ensure tests are deterministic