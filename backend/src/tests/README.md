# API Test Suite Documentation

This directory contains comprehensive API tests for the SSH Key Manager backend, implementing multiple testing patterns for different scenarios.

## Test Structure Overview

### Core Test Modules

1. **`safety.rs`** - Test safety utilities and logger initialization
2. **`test_config.rs`** - Minimal test configuration and database setup
3. **`basic_tests.rs`** - Basic HTTP endpoint tests (legacy)
4. **`test_api.rs`** - Simple API endpoint tests with security verification
5. **`security_first_api_tests.rs`** - **THE NEW STANDARD** - Comprehensive security testing
6. **`real_http_auth_test.rs`** - Real HTTP authentication with htpasswd files
7. **`real_http_auth_success.rs`** - Proven working HTTP authentication tests  
8. **`user_lifecycle_simple.rs`** - End-to-end user workflow testing

## Test Categories

### 🔒 Security Tests (PRIMARY)
- **File**: `security_first_api_tests.rs`
- **Purpose**: Verify ALL API endpoints require authentication
- **Coverage**: 33 endpoints across 5 modules (User, Host, Key, Authorization, Diff)
- **Pattern**: Comprehensive security-first testing

### 🌐 Real HTTP Authentication Tests
- **File**: `real_http_auth_test.rs`
- **Purpose**: Test actual HTTP login with cookies, sessions, and CSRF tokens
- **Features**: bcrypt password hashing, session persistence, real authentication flow

### 🔄 User Lifecycle Tests
- **File**: `user_lifecycle_simple.rs`
- **Purpose**: End-to-end workflow testing (create → modify → assign key → delete)
- **Pattern**: Demonstrates complete API usage patterns

### 📡 Basic API Tests
- **File**: `test_api.rs`
- **Purpose**: Simple endpoint verification with inline app creation
- **Pattern**: Proven inline test pattern for quick verification

## Running Tests

### Standard Test Commands

```bash
# Run all tests (minimal output)
cargo test

# Run tests with info logging
cargo test -- --nocapture

# Run specific test modules
cargo test security_first_api     # Security tests
cargo test real_http_auth         # Authentication tests  
cargo test user_lifecycle         # Workflow tests
cargo test basic_tests            # Basic endpoint tests
```

### Justfile Commands (Recommended)

```bash
# Convenient test commands with appropriate logging
just test              # Clean output (no logs)
just test-verbose      # Shows log::info! messages
just test-debug        # Shows all debug logs
just test-quiet        # Only warnings/errors

# Specific test suites
just test-auth         # Authentication tests with output
just test-security     # Security tests with output
just test-lifecycle    # User lifecycle tests with output
```

### Logging Levels

The test suite automatically detects logging preferences:

- **Default**: `warn` level (minimal output)
- **With `--nocapture`**: `info` level (detailed test progress)
- **Manual override**: Set `RUST_LOG=debug` for full logging

## Writing New Tests

### 🏆 Recommended Pattern: Security-First Testing

Use the pattern from `security_first_api_tests.rs` for comprehensive endpoint testing:

```rust
use actix_web::{test, web, App};
use actix_identity::IdentityMiddleware;
use actix_session::{SessionMiddleware, storage::CookieSessionStore};
use actix_web::cookie::Key;
use serial_test::serial;
use serde_json::json;

use crate::{test_only, tests::{test_config::*, safety::init_test_mode}};

#[tokio::test]
#[serial]
async fn test_your_api_security() {
    test_only!();
    init_test_mode();
    
    log::info!("🧪 Testing Your API with comprehensive security");
    
    // Create test app inline (proven pattern)
    let db_pool = create_test_db_pool().await;
    let config = TestAppConfig::new();
    
    let app = App::new()
        .app_data(web::Data::new(db_pool))
        .app_data(web::Data::new(config.clone()))
        .wrap(IdentityMiddleware::default())
        .wrap(
            SessionMiddleware::builder(
                CookieSessionStore::default(),
                Key::from(config.session_key.as_bytes()),
            )
            .cookie_secure(false)
            .build(),
        )
        .configure(crate::routes::route_config);
        
    let service = test::init_service(app).await;
    
    // Test endpoints for security
    let endpoints = [
        ("GET", "/api/your_endpoint", None),
        ("POST", "/api/your_endpoint", Some(json!({"data": "test"}))),
        // ... more endpoints
    ];
    
    for (method, uri, payload) in endpoints {
        log::info!("🔒 Testing {} {}", method, uri);
        
        let req = match method {
            "GET" => test::TestRequest::get().uri(uri).to_request(),
            "POST" => {
                let mut builder = test::TestRequest::post().uri(uri);
                if let Some(json_payload) = payload {
                    builder = builder.set_json(&json_payload);
                }
                builder.to_request()
            },
            _ => panic!("Add support for method: {}", method)
        };
        
        let resp = test::call_service(&service, req).await;
        
        // MANDATORY: All endpoints MUST reject unauthenticated access
        assert!(
            resp.status().is_client_error() || resp.status().is_server_error(),
            "❌ CRITICAL SECURITY FAILURE: {} {} allows unauthenticated access! Status: {}", 
            method, uri, resp.status()
        );
        
        log::info!("✅ {} {} - Authentication required ✓", method, uri);
    }
    
    log::info!("🎉 Your API comprehensive security test PASSED!");
}
```

### 🔐 Real Authentication Pattern

For tests requiring actual login, use the pattern from `real_http_auth_test.rs`:

```rust
use bcrypt::{hash, DEFAULT_COST};
use std::fs;

fn create_test_config_with_auth() -> Configuration {
    let htpasswd_path = "/tmp/test_htpasswd";
    let password_hash = hash("testpass123", DEFAULT_COST).expect("Failed to hash password");
    let htpasswd_content = format!("testadmin:{}\n", password_hash);
    fs::write(&htpasswd_path, htpasswd_content).expect("Failed to write htpasswd file");
    
    Configuration {
        session_key: "test-session-key-64-bytes-long-for-cookie-session-middleware-xxx".to_string(),
        htpasswd_path,
        // ... other config
    }
}

// Then use real login flow with session cookies and CSRF tokens
```

### Essential Test Components

#### 1. Required Imports
```rust
use crate::{test_only, tests::{test_config::*, safety::init_test_mode}};
use serial_test::serial;
```

#### 2. Test Function Structure
```rust
#[tokio::test]
#[serial]  // Prevents database conflicts
async fn test_name() {
    test_only!();        // Ensures test-only execution
    init_test_mode();    // Sets up logging and safety
    
    // Your test logic here
}
```

#### 3. Inline App Creation (Proven Pattern)
```rust
let db_pool = create_test_db_pool().await;
let config = TestAppConfig::new();

let app = App::new()
    .app_data(web::Data::new(db_pool))
    .app_data(web::Data::new(config.clone()))
    .wrap(IdentityMiddleware::default())
    .wrap(
        SessionMiddleware::builder(
            CookieSessionStore::default(),
            Key::from(config.session_key.as_bytes()),
        )
        .cookie_secure(false)
        .build(),
    )
    .configure(crate::routes::route_config);
```

## Test Patterns and Standards

### ✅ DO (Best Practices)

1. **Use `#[serial]`** - Prevents database conflicts between tests
2. **Use `test_only!()`** - Ensures safety in production
3. **Use `init_test_mode()`** - Sets up logging and environment
4. **Use inline app creation** - Proven reliable pattern
5. **Test security first** - Verify authentication requirements
6. **Use descriptive logging** - `log::info!("🧪 Testing...")` for progress
7. **Test all HTTP methods** - GET, POST, PUT, DELETE as applicable
8. **Assert security failures** - Expect 4xx/5xx for unauthenticated requests

### ❌ DON'T (Anti-patterns)

1. **Don't use shared test setup** - Causes complex type issues
2. **Don't skip `#[serial]`** - Leads to database race conditions  
3. **Don't test without authentication checks** - Security vulnerability
4. **Don't assume specific status codes** - Use `.is_client_error()` instead
5. **Don't forget error logging** - Use descriptive error messages
6. **Don't create global test state** - Each test should be independent

## API Endpoint Coverage

### Current Test Coverage (33 endpoints)

#### User API (9 endpoints)
- `GET /api/user` - List users
- `POST /api/user` - Create user
- `GET /api/user/:username` - Get user
- `PUT /api/user/:username` - Update user
- `DELETE /api/user/:username` - Delete user
- `GET /api/user/:username/keys` - Get user's keys
- `GET /api/user/:username/authorizations` - Get user's authorizations
- `POST /api/user/assign_key` - Assign key to user
- `POST /api/user/add_key` - Add key to user

#### Host API (11 endpoints)
- `GET /api/host` - List hosts
- `POST /api/host` - Create host
- `GET /api/host/:name` - Get host
- `DELETE /api/host/:name` - Delete host
- `GET /api/host/:name/logins` - Get host logins
- `POST /api/host/:name/authorize` - Authorize user on host
- `DELETE /api/host/authorization/:id` - Remove authorization
- `GET /api/host/:name/authorizations` - Get host authorizations
- `POST /api/host/:name/authorized_keys` - Generate authorized_keys
- `PUT /api/host/:name/authorized_keys` - Update authorized_keys
- `POST /api/host/:name/add_key` - Add key to host

#### Key API (5 endpoints)
- `GET /api/key` - List keys
- `POST /api/key` - Create key
- `GET /api/key/:id` - Get key
- `PUT /api/key/:id` - Update key
- `DELETE /api/key/:id` - Delete key

#### Authorization API (5 endpoints)
- `GET /api/authorization` - List authorizations
- `POST /api/authorization` - Create authorization
- `GET /api/authorization/:id` - Get authorization
- `PUT /api/authorization/:id` - Update authorization
- `DELETE /api/authorization/:id` - Delete authorization

#### Diff API (3 endpoints)
- `GET /api/diff` - List hosts for diff
- `GET /api/diff/:host` - Get host diff
- `GET /api/diff/:host/details` - Get detailed diff

## Test Database

- **Type**: In-memory SQLite (`:memory:`)
- **Isolation**: Each test gets a fresh database
- **Speed**: Fast test execution
- **Safety**: No persistence between tests

## Logging and Debugging

### Log Levels in Tests
```rust
log::info!("🧪 Starting test...");     // Test progress
log::info!("🔒 Testing security...");  // Security checks
log::info!("✅ Test passed");          // Success
log::warn!("⚠️ Unexpected behavior");  // Warnings
```

### Debug Failed Tests
```bash
# Run specific failing test with full output
cargo test test_name -- --nocapture

# Run with debug logging
RUST_LOG=debug cargo test test_name -- --nocapture

# Use justfile for convenience
just test-debug
```

## Current Statistics

- **Total Test Files**: 8 modules
- **Test Functions**: 26 tests
- **API Endpoints Covered**: 33 endpoints
- **Security Tests**: 100% endpoint coverage
- **Authentication Tests**: Real HTTP auth with sessions
- **Status**: All tests passing ✅

## Migration Notes

This test suite evolved from basic endpoint tests to comprehensive security-first testing. The current structure represents battle-tested patterns that avoid common pitfalls in Rust/Actix-Web testing.

Key improvements over time:
1. Moved from shared setup to inline app creation
2. Added comprehensive security testing
3. Implemented real HTTP authentication
4. Added smart logging detection
5. Created convenient justfile commands
6. Established clear testing standards

For new features, follow the security-first testing pattern to maintain high code quality and security standards.