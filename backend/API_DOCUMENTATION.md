# SSH Key Manager API Documentation

This document provides information about the OpenAPI specification and how to use it for the SSH Key Manager API.

## OpenAPI Specification

The complete OpenAPI 3.0 specification is available in `openapi.yaml`. This specification includes:

- **Complete API endpoint documentation** for all 6 main areas:
  - Authentication (`/api/auth/*`)
  - Host management (`/api/host/*`) 
  - User management (`/api/user/*`)
  - SSH key management (`/api/key/*`)
  - Authorization management (`/api/authorization/*`)
  - Diff analysis (`/api/diff/*`)

- **Request/Response schemas** with detailed examples
- **Authentication documentation** for session-based auth
- **Error response schemas** with consistent error handling
- **Comprehensive examples** for all endpoints

## Key Features

### Authentication
- Session-based authentication using HTTP cookies
- Login/logout endpoints with proper session management
- Authentication status checking

### Host Management
- CRUD operations for SSH hosts
- Host key fingerprint verification
- Jump host support for SSH tunneling
- Login enumeration and authorized_keys management

### User Management  
- User account CRUD operations
- SSH key assignment and management
- User authorization tracking

### SSH Key Operations
- Key parsing and validation
- Comment management
- Association with users
- Fingerprint calculation

### Authorization System
- User-to-host access control
- SSH key options management
- Authorization tracking and cleanup

### Diff Analysis
- Compare expected vs actual authorized_keys files
- Identify missing, unknown, or misconfigured keys
- Force cache refresh capabilities

## Using the OpenAPI Specification

### Swagger UI
To view the interactive documentation:

1. Install swagger-ui or use online version
2. Load the `openapi.yaml` file
3. Test endpoints directly from the UI

### Generate Client SDKs
Use OpenAPI Generator to create client libraries:

```bash
# Generate TypeScript client
openapi-generator-cli generate -i openapi.yaml -g typescript-axios -o ./clients/typescript

# Generate Python client  
openapi-generator-cli generate -i openapi.yaml -g python -o ./clients/python

# Generate Go client
openapi-generator-cli generate -i openapi.yaml -g go -o ./clients/go
```

### Postman Collection
Import the OpenAPI spec directly into Postman:
1. Open Postman
2. Import → Link → Paste path to `openapi.yaml`
3. Generate collection with all endpoints and examples

## API Usage Examples

### Authentication Flow
```bash
# Login
curl -X POST http://localhost:8080/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username": "admin", "password": "password123"}' \
  -c cookies.txt

# Use session for subsequent requests
curl -X GET http://localhost:8080/api/host \
  -b cookies.txt
```

### Host Management
```bash
# Create new host
curl -X POST http://localhost:8080/api/host \
  -H "Content-Type: application/json" \
  -b cookies.txt \
  -d '{
    "name": "web-server-01", 
    "address": "192.168.1.100",
    "port": 22,
    "username": "ubuntu",
    "key_fingerprint": null
  }'

# Get host logins
curl -X GET "http://localhost:8080/api/host/web-server-01/logins?force_update=true" \
  -b cookies.txt
```

### User and Key Management
```bash
# Create user
curl -X POST http://localhost:8080/api/user \
  -H "Content-Type: application/json" \
  -b cookies.txt \
  -d '{"username": "john.doe"}'

# Assign SSH key to user
curl -X POST http://localhost:8080/api/user/assign_key \
  -H "Content-Type: application/json" \
  -b cookies.txt \
  -d '{
    "user_id": 1,
    "key_type": "ssh-rsa",
    "key_base64": "AAAAB3NzaC1yc2EAAAADAQABAAABAQ...",
    "key_comment": "user@laptop"
  }'
```

### Authorization Management
```bash
# Authorize user on host
curl -X POST http://localhost:8080/api/host/user/authorize \
  -H "Content-Type: application/json" \
  -b cookies.txt \
  -d '{
    "host_id": 1,
    "user_id": 1, 
    "login": "ubuntu",
    "options": null
  }'
```

### Diff Analysis
```bash
# Get host diff analysis
curl -X GET "http://localhost:8080/api/diff/web-server-01?show_empty=false&force_update=true" \
  -b cookies.txt
```

## Response Structure

### Success Response
```json
{
  "success": true,
  "data": { ... },
  "message": "Optional success message"
}
```

### Error Response  
```json
{
  "success": false,
  "message": "Error description"
}
```

## Status Codes

- **200** - Success
- **201** - Created
- **400** - Bad Request
- **401** - Unauthorized  
- **404** - Not Found
- **500** - Internal Server Error
- **501** - Not Implemented

## Data Types

### Core Entities

**Host**
- `id`: integer - Unique identifier
- `name`: string - Host name  
- `address`: string - IP or hostname
- `port`: integer - SSH port
- `username`: string - SSH login
- `key_fingerprint`: string? - Host key fingerprint
- `jump_via`: integer? - Jump host ID

**User**  
- `id`: integer - Unique identifier
- `username`: string - Username
- `enabled`: boolean - Account status

**SSH Key**
- `id`: integer - Unique identifier  
- `key_type`: string - Algorithm (ssh-rsa, ssh-ed25519, etc.)
- `key_base64`: string - Base64 encoded key data
- `key_comment`: string? - Optional comment
- `username`: string - Associated user

**Authorization**
- `authorization_id`: integer - Unique identifier
- `username`: string - User account
- `login`: string - Host login account  
- `options`: string? - SSH key options

## Security Considerations

- All endpoints require authentication except `/api/auth/*`
- Session cookies are HTTP-only and secure
- Host key fingerprints prevent MITM attacks
- SSH key validation prevents malformed keys
- Authorization system prevents unauthorized access

## Rate Limiting

The API doesn't currently implement rate limiting, but consider adding it for:
- Authentication endpoints (prevent brute force)
- SSH operations (prevent host overload)
- Diff analysis (resource intensive)

## Caching

The API implements intelligent caching for:
- SSH connection results
- Host login enumeration  
- Diff analysis results

Use `force_update=true` parameter to bypass cache when needed.