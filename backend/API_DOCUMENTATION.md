# SSH Key Manager API Documentation

This document provides information about the auto-generated OpenAPI specification and API documentation for the SSH Key Manager.

## 🚀 Live API Documentation

The SSH Key Manager now includes **built-in, auto-generated API documentation** powered by utoipa and Swagger UI.

### Access Documentation

When the application is running:

- **Interactive Swagger UI**: `http://localhost:8080/swagger-ui/`
  - Browse all endpoints with full descriptions
  - View request/response schemas
  - Test API calls directly from the browser
  - Authenticate and maintain sessions

- **OpenAPI JSON Specification**: `http://localhost:8080/api-docs/openapi.json`
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

### Host Management (`/api/hosts/*`)
- `GET /api/hosts` - List all hosts
- `GET /api/hosts/{name}` - Get host by name
- `POST /api/hosts` - Create new host
- `PUT /api/hosts/{name}` - Update host
- `DELETE /api/hosts/{name}` - Delete host
- `GET /api/hosts/{name}/logins` - Get available logins
- `POST /api/hosts/{id}/add_hostkey` - Add host SSH key
- `POST /api/hosts/{name}/set_authorized_keys` - Set authorized keys

### User Management (`/api/users/*`)
- `GET /api/users` - List all users
- `GET /api/users/{name}` - Get user by username
- `POST /api/users` - Create new user
- `PUT /api/users/{old_username}` - Update user
- `DELETE /api/users/{username}` - Delete user
- `GET /api/users/{username}/keys` - Get user's SSH keys
- `GET /api/users/{username}/authorizations` - Get user's host authorizations
- `POST /api/users/assign_key` - Assign SSH key to user
- `POST /api/users/add_key` - Preview SSH key before assignment

### SSH Key Management (`/api/keys/*`)
- `GET /api/keys` - List all SSH keys
- `DELETE /api/keys/{id}` - Delete SSH key
- `PUT /api/keys/{id}/comment` - Update key comment

### Authorization Management (`/api/authorization/*`)
- `POST /api/authorization/dialog_data` - Get authorization dialog data
- `POST /api/authorization/change_options` - Change authorization options (TODO)

### Diff Analysis (`/api/diff/*`)
- `GET /api/diff` - Get hosts available for diff
- `GET /api/diff/{host_name}` - Get SSH key differences for a host
- `GET /api/diff/{name}/details` - Get detailed diff information

## 🛠️ Using the API

### Authentication Flow

The API uses session-based authentication with HTTP-only cookies:

```bash
# Login
curl -X POST http://localhost:8080/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username": "admin", "password": "password123"}' \
  -c cookies.txt

# Use session for subsequent requests
curl -X GET http://localhost:8080/api/hosts \
  -b cookies.txt

# Logout
curl -X POST http://localhost:8080/api/auth/logout \
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
curl http://localhost:8080/api-docs/openapi.json -o openapi.json

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

- **Postman**: Import → Link → `http://localhost:8080/api-docs/openapi.json`
- **Insomnia**: Import → From URL → `http://localhost:8080/api-docs/openapi.json`
- **Bruno**: Import → OpenAPI → Paste the JSON
- **Thunder Client**: Import → OpenAPI → From URL

## 📚 API Examples

### Host Management

```bash
# Create a new host
curl -X POST http://localhost:8080/api/hosts \
  -H "Content-Type: application/json" \
  -b cookies.txt \
  -d '{
    "name": "web-server-01",
    "address": "192.168.1.100",
    "port": 22,
    "username": "ubuntu",
    "key_fingerprint": null,
    "jump_via": null
  }'

# Get host details
curl -X GET http://localhost:8080/api/hosts/web-server-01 \
  -b cookies.txt

# Get available logins on host
curl -X GET "http://localhost:8080/api/hosts/web-server-01/logins?force_update=true" \
  -b cookies.txt
```

### User and Key Management

```bash
# Create a user
curl -X POST http://localhost:8080/api/users \
  -H "Content-Type: application/json" \
  -b cookies.txt \
  -d '{"username": "john.doe"}'

# Assign SSH key to user
curl -X POST http://localhost:8080/api/users/assign_key \
  -H "Content-Type: application/json" \
  -b cookies.txt \
  -d '{
    "user_id": 1,
    "key_type": "ssh-rsa",
    "key_base64": "AAAAB3NzaC1yc2EAAAADAQABAAABAQ...",
    "key_comment": "john@laptop"
  }'

# Get user's SSH keys
curl -X GET http://localhost:8080/api/users/john.doe/keys \
  -b cookies.txt
```

### Diff Analysis

```bash
# Get SSH key differences for a host
curl -X GET "http://localhost:8080/api/diff/web-server-01?show_empty=false&force_update=true" \
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