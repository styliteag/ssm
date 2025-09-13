# SSH Key Manager API Documentation

This document provides information about the auto-generated OpenAPI specification and API documentation for the SSH Key Manager.

## 🚀 Live API Documentation

The SSH Key Manager now includes **built-in, auto-generated API documentation** powered by utoipa and Swagger UI.

### Access Documentation

When the application is running:

- **Interactive Swagger UI**: `http://localhost:8000/swagger-ui/`
  - Browse all endpoints with full descriptions
  - View request/response schemas
  - Test API calls directly from the browser
  - Authenticate and maintain sessions

- **OpenAPI JSON Specification**: `http://localhost:8000/api-docs/openapi.json`
  - Complete OpenAPI 3.0 specification
  - Auto-generated from Rust code
  - Always in sync with implementation
  - Import into any OpenAPI-compatible tool

## 📋 API Coverage

The auto-generated documentation covers all API endpoints:

### Authentication (`/api/auth/*`)
- `POST /api/auth/login` - User login with credentials
- `POST /api/auth/logout` - User logout
- `GET /api/auth/status` - Check authentication status

### Host Management (`/api/host/*`)
- `GET /api/host` - List all hosts (includes `disabled` field)
- `GET /api/host/{name}` - Get host by name (includes `disabled` field)
- `POST /api/host` - Create new host (supports `disabled` field to prevent SSH operations)
- `PUT /api/host/{name}` - Update host (supports `disabled` field to enable/disable host)
- `DELETE /api/host/{name}` - Delete host
- `GET /api/host/{name}/logins` - Get available logins
- `POST /api/host/{id}/add_hostkey` - Add host SSH key
- `POST /api/host/{name}/set_authorized_keys` - Set authorized keys

**Note**: Setting `disabled: true` on a host prevents all SSH connections, polling, and sync operations. The `comment` field allows adding optional notes to hosts.

### User Management (`/api/user/*`)
- `GET /api/user` - List all users
- `GET /api/user/{name}` - Get user by username
- `POST /api/user` - Create new user
- `PUT /api/user/{old_username}` - Update user
- `DELETE /api/user/{username}` - Delete user
- `GET /api/user/{username}/keys` - Get user's SSH keys
- `GET /api/user/{username}/authorizations` - Get user's host authorizations
- `POST /api/user/assign_key` - Assign SSH key to user
- `POST /api/user/add_key` - Preview SSH key before assignment

**Note**: The `comment` field allows adding optional notes to users. Usernames can now include "@" characters for email-style usernames.

### SSH Key Management (`/api/key/*`)
- `GET /api/key` - List all SSH keys
- `DELETE /api/key/{id}` - Delete SSH key
- `PUT /api/key/{id}/comment` - Update key name and/or extra comment

**Note**: SSH keys now have two comment fields:
- `key_name`: The primary name/identifier for the key (formerly "comment")
- `extra_comment`: Additional notes about the key

### Authorization Management (`/api/authorization/*`)
- `POST /api/authorization/dialog_data` - Get authorization dialog data
- `POST /api/authorization/change_options` - Change authorization options (TODO)

### Diff Analysis (`/api/diff/*`)
- `GET /api/diff` - Get hosts available for diff (includes `disabled` field)
- `GET /api/diff/{host_name}` - Get SSH key differences for a host (returns "Host is disabled" for disabled hosts)
- `GET /api/diff/{name}/details` - Get detailed diff information (returns empty for disabled hosts)
- `POST /api/diff/{name}/sync` - Sync SSH keys to host (blocked for disabled hosts)

## 🛠️ Using the API

### Authentication Flow

The API uses session-based authentication with HTTP-only cookies:

```bash
# Login
curl -X POST http://localhost:8000/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username": "admin", "password": "password123"}' \
  -c cookies.txt

# Use session for subsequent requests
curl -X GET http://localhost:8000/api/host \
  -b cookies.txt

# Logout
curl -X POST http://localhost:8000/api/auth/logout \
  -b cookies.txt
```

### Response Structure

All API responses follow a consistent structure:

#### Success Response
```json
{
  "success": true,
  "data": { ... },
  "message": "Optional success message"
}
```

#### Error Response
```json
{
  "success": false,
  "message": "Error description"
}
```

### Status Codes

- **200** - Success
- **201** - Created
- **400** - Bad Request
- **401** - Unauthorized
- **404** - Not Found
- **500** - Internal Server Error
- **501** - Not Implemented

## 🔧 Client SDK Generation

The auto-generated OpenAPI specification can be used to generate client SDKs in any language:

### Using OpenAPI Generator

```bash
# First, get the OpenAPI spec
curl http://localhost:8000/api-docs/openapi.json -o openapi.json

# Generate TypeScript/Axios client
npx @openapitools/openapi-generator-cli generate \
  -i openapi.json \
  -g typescript-axios \
  -o ./clients/typescript

# Generate Python client
npx @openapitools/openapi-generator-cli generate \
  -i openapi.json \
  -g python \
  -o ./clients/python

# Generate Go client
npx @openapitools/openapi-generator-cli generate \
  -i openapi.json \
  -g go \
  -o ./clients/go

# Generate Rust client
npx @openapitools/openapi-generator-cli generate \
  -i openapi.json \
  -g rust \
  -o ./clients/rust
```

### Import into API Tools

The OpenAPI specification can be imported directly into:

- **Postman**: Import → Link → `http://localhost:8000/api-docs/openapi.json`
- **Insomnia**: Import → From URL → `http://localhost:8000/api-docs/openapi.json`
- **Bruno**: Import → OpenAPI → Paste the JSON
- **Thunder Client**: Import → OpenAPI → From URL

## 📚 Detailed API Reference

**🔐 Authentication Required**: All API endpoints except authentication require session-based authentication via `.htpasswd` credentials.

### Quick Start with curl

```bash
# 1. Login to establish session
curl -X POST http://localhost:8000/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"your_password"}' \
  -c cookies.txt

# 2. Use session cookie for authenticated requests
curl -b cookies.txt http://localhost:8000/api/host

# 3. Logout when done
curl -X POST http://localhost:8000/api/auth/logout -b cookies.txt
```

### Authentication Endpoints

#### Login (Establishes Session)
```http
POST /api/auth/login
Content-Type: application/json

{
  "username": "admin",
  "password": "password"
}
```

**curl example:**
```bash
curl -X POST http://localhost:8000/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"your_password"}' \
  -c cookies.txt
```

#### Logout
```http
POST /api/auth/logout
DELETE /api/auth/session
```

**curl example:**
```bash
curl -X POST http://localhost:8000/api/auth/logout -b cookies.txt
```

### Host Management (🔐 Authentication Required)

```http
# List all hosts
GET /api/host
```

**curl example:**
```bash
curl -b cookies.txt http://localhost:8000/api/host
```

```http
# Get specific host
GET /api/host/{name}

# Create host
POST /api/host
Content-Type: application/json

{
  "name": "web-server-01",
  "address": "192.168.1.100",
  "port": 22,
  "username": "deploy",
  "disabled": false,  # Optional: Set to true to disable SSH connections
  "comment": "Production web server"  # Optional: Add notes about the host
}

# Update host
PUT /api/host/{name}
Content-Type: application/json

{
  "name": "web-server-01",
  "address": "192.168.1.100",
  "port": 22,
  "username": "deploy",
  "disabled": true,  # Disable host to prevent SSH connections
  "comment": "Production web server - Under maintenance"  # Update host notes
}

# Delete host
DELETE /api/host/{name}
```

**Disabled Hosts Feature:**
- Set `disabled: true` to prevent all SSH connections to a host
- Disabled hosts will not be polled for connection status
- Diff operations return "Host is disabled" without SSH attempts
- Sync operations are blocked for disabled hosts
- Useful for maintenance windows or decommissioned servers

### User Management (🔐 Authentication Required)

```http
# List all users
GET /api/user
```

**curl example:**
```bash
curl -b cookies.txt http://localhost:8000/api/user
```

```http
# Get specific user
GET /api/user/{username}

# Create user
POST /api/user
Content-Type: application/json

{
  "username": "john.doe@example.com",
  "enabled": true,
  "comment": "Developer account"
}
```

### SSH Key Management (🔐 Authentication Required)

```http
# List all keys
GET /api/key
```

**curl example:**
```bash
curl -b cookies.txt http://localhost:8000/api/key
```

```http
# Delete key
DELETE /api/key/{id}

# Update key name and/or extra comment
PUT /api/key/{id}/comment
Content-Type: application/json

{
  "name": "Updated key name",
  "extra_comment": "Additional notes about this key"
}
```

### Authorization Management (🔐 Authentication Required)

```http
# Get authorization dialog data
GET /api/authorization

# Update authorization options
PUT /api/authorization
Content-Type: application/json

{
  "authorization_id": 1,
  "options": "no-port-forwarding,command=\"rsync --server\""
}
```

### Diff Analysis (🔐 Authentication Required)

```http
# Get hosts available for diff analysis
GET /api/diff

# Get differences for specific host
GET /api/diff/{host_name}

# Get detailed diff information
GET /api/diff/{host_name}/{login}
```

**curl example:**
```bash
curl -b cookies.txt http://localhost:8000/api/diff
```

## 📚 Additional API Examples

### Host Management

```bash
# Create a new host
curl -X POST http://localhost:8000/api/host \
  -H "Content-Type: application/json" \
  -b cookies.txt \
  -d '{
    "name": "web-server-01",
    "address": "192.168.1.100",
    "port": 22,
    "username": "ubuntu",
    "disabled": false,
    "comment": "Production web server"
  }'

# Get host details
curl -X GET http://localhost:8000/api/host/web-server-01 \
  -b cookies.txt

# Get available logins on host
curl -X GET "http://localhost:8000/api/host/web-server-01/logins?force_update=true" \
  -b cookies.txt
```

### User and Key Management

```bash
# Create a user
curl -X POST http://localhost:8000/api/user \
  -H "Content-Type: application/json" \
  -b cookies.txt \
  -d '{"username": "john.doe@example.com", "comment": "Developer account"}'

# Assign SSH key to user
curl -X POST http://localhost:8000/api/user/assign_key \
  -H "Content-Type: application/json" \
  -b cookies.txt \
  -d '{
    "user_id": 1,
    "key_type": "ssh-rsa",
    "key_base64": "AAAAB3NzaC1yc2EAAAADAQABAAABAQ...",
    "key_name": "john@laptop",
    "extra_comment": "Primary laptop key"
  }'

# Get user's SSH keys
curl -X GET "http://localhost:8000/api/user/john.doe@example.com/keys" \
  -b cookies.txt
```

### Diff Analysis

```bash
# Get SSH key differences for a host
curl -X GET "http://localhost:8000/api/diff/web-server-01?show_empty=false&force_update=true" \
  -b cookies.txt
```

## 🔒 Security Considerations

- **Authentication Required**: All endpoints except `/api/auth/*` require authentication
- **Session Management**: HTTP-only cookies prevent XSS attacks
- **Host Key Verification**: SSH host key fingerprints prevent MITM attacks
- **Key Validation**: All SSH keys are validated before storage
- **Access Control**: Fine-grained authorization system for user-host access

## ⚡ Performance Features

### Caching
The API implements intelligent caching for:
- SSH connection results
- Host login enumeration
- Diff analysis results

Use `force_update=true` query parameter to bypass cache when needed.

### Connection Pooling
- Database connections are pooled for efficiency
- SSH connections are reused when possible

## 🏗️ Architecture

The API is built with:
- **Framework**: Actix-Web 4.x
- **Documentation**: utoipa 4.x with Swagger UI
- **Database**: Diesel ORM with SQLite/PostgreSQL/MySQL support
- **Authentication**: Session-based with bcrypt password hashing
- **SSH**: russh library for SSH operations

## 📖 Additional Resources

- **Source Code**: Check the `src/routes/` directory for endpoint implementations
- **Data Models**: See `src/models.rs` for entity definitions
- **API Types**: Review `src/api_types.rs` for request/response structures
- **OpenAPI Module**: `src/openapi.rs` contains the documentation configuration

## 🐛 Troubleshooting

### Common Issues

1. **401 Unauthorized**: Ensure you're including the session cookie in requests
2. **404 Not Found**: Check the exact endpoint path in Swagger UI
3. **500 Internal Error**: Check server logs for detailed error messages
4. **Cache Issues**: Use `force_update=true` to refresh cached data

### Debug Mode

Enable debug logging for detailed API information:
```bash
RUST_LOG=debug cargo run
```

## 📝 Notes

- The OpenAPI specification is auto-generated from Rust code using utoipa
- Documentation is always in sync with the implementation
- All changes to API endpoints automatically update the documentation
- The Swagger UI provides an interactive testing environment