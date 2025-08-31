# SSH Key Manager API Documentation

This document describes the REST API for the SSH Key Manager application.

## Base URL

- **Development**: `http://localhost:8000`
- **Production**: `http://localhost/api` (proxied through nginx)

## Authentication

The API uses session-based authentication with cookies. All endpoints except authentication endpoints require a valid session.

### Authentication Endpoints

#### POST /api/auth/login

Authenticate user and create session.

**Request Body:**
```json
{
  "username": "admin",
  "password": "password123"
}
```

**Response (200 OK):**
```json
{
  "success": true,
  "data": null,
  "message": "Login successful"
}
```

**Response (401 Unauthorized):**
```json
{
  "success": false,
  "message": "Invalid credentials"
}
```

#### POST /api/auth/logout

Logout user and destroy session.

**Response (200 OK):**
```json
{
  "success": true,
  "data": null,
  "message": "Logout successful"
}
```

#### GET /api/auth/status

Check authentication status.

**Response (200 OK):**
```json
{
  "success": true,
  "data": {
    "logged_in": true,
    "username": "admin"
  }
}
```

## Hosts Management

### GET /api/hosts

List all hosts with pagination support.

**Query Parameters:**
- `page` (optional): Page number (default: 1)
- `per_page` (optional): Items per page (default: 20, max: 100)

**Response (200 OK):**
```json
{
  "success": true,
  "data": [
    {
      "id": 1,
      "name": "web-server-01",
      "address": "192.168.1.100",
      "port": 22,
      "username": "deploy",
      "key_fingerprint": "SHA256:abc123...",
      "jump_via": null,
      "jumphost_name": null
    },
    {
      "id": 2,
      "name": "db-server-01",
      "address": "192.168.1.200",
      "port": 22,
      "username": "admin",
      "key_fingerprint": "SHA256:def456...",
      "jump_via": 1,
      "jumphost_name": "web-server-01"
    }
  ]
}
```

### GET /api/hosts/{name}

Get details for a specific host by name.

**Response (200 OK):**
```json
{
  "success": true,
  "data": {
    "id": 1,
    "name": "web-server-01",
    "address": "192.168.1.100",
    "port": 22,
    "username": "deploy",
    "key_fingerprint": "SHA256:abc123...",
    "jump_via": null,
    "jumphost_name": null
  }
}
```

**Response (404 Not Found):**
```json
{
  "success": false,
  "message": "Host not found"
}
```

### POST /api/hosts

Create a new host.

**Request Body:**
```json
{
  "name": "new-server",
  "address": "192.168.1.150",
  "port": 22,
  "username": "deploy",
  "key_fingerprint": "SHA256:xyz789...",
  "jump_via": null
}
```

**Response (201 Created):**
```json
{
  "success": true,
  "data": {
    "id": 3,
    "name": "new-server",
    "address": "192.168.1.150",
    "port": 22,
    "username": "deploy",
    "key_fingerprint": "SHA256:xyz789...",
    "jump_via": null,
    "jumphost_name": null
  },
  "message": "Host created successfully"
}
```

**Note**: If `key_fingerprint` is not provided, the API will attempt to connect and return a confirmation request:

**Response (200 OK) - Requires Confirmation:**
```json
{
  "success": true,
  "data": {
    "host_name": "new-server",
    "login": "deploy",
    "address": "192.168.1.150",
    "port": 22,
    "key_fingerprint": "SHA256:detected_key...",
    "jumphost": null,
    "requires_confirmation": true
  }
}
```

### PUT /api/hosts/{name}

Update an existing host.

**Request Body:**
```json
{
  "name": "updated-server",
  "address": "192.168.1.151",
  "username": "admin",
  "port": 2222,
  "key_fingerprint": "SHA256:new_key...",
  "jump_via": null
}
```

**Response (200 OK):**
```json
{
  "success": true,
  "data": null,
  "message": "Host updated successfully"
}
```

### DELETE /api/hosts/{name}

Delete a host (with confirmation).

**Request Body:**
```json
{
  "confirm": false
}
```

**Response (200 OK) - Preview mode:**
```json
{
  "success": true,
  "data": {
    "authorizations": [
      {
        "user_id": 1,
        "username": "john.doe",
        "login": "deploy",
        "options": null
      }
    ],
    "affected_hosts": ["dependent-server"]
  }
}
```

**Request Body (Confirmed):**
```json
{
  "confirm": true
}
```

**Response (200 OK):**
```json
{
  "success": true,
  "data": null,
  "message": "Deleted 1 record(s)"
}
```

### GET /api/hosts/{name}/logins

Get available login accounts on a host.

**Query Parameters:**
- `force_update` (optional): Force refresh from host (default: false)

**Response (200 OK):**
```json
{
  "success": true,
  "data": {
    "logins": ["root", "deploy", "www-data", "backup"]
  }
}
```

### GET /api/hosts/{name}/authorizations

List all user authorizations for a specific host.

**Response (200 OK):**
```json
{
  "success": true,
  "data": {
    "authorizations": [
      {
        "user_id": 1,
        "username": "john.doe",
        "login": "deploy",
        "options": "no-port-forwarding"
      },
      {
        "user_id": 2,
        "username": "jane.smith",
        "login": "backup",
        "options": null
      }
    ]
  }
}
```

### POST /api/hosts/{id}/add_hostkey

Add or update host key fingerprint.

**Request Body:**
```json
{
  "key_fingerprint": "SHA256:new_fingerprint..."
}
```

**Response (200 OK):**
```json
{
  "success": true,
  "data": null,
  "message": "Host key updated successfully"
}
```

## Users Management

### GET /api/users

List all users with pagination support.

**Query Parameters:**
- `page` (optional): Page number (default: 1)
- `per_page` (optional): Items per page (default: 20, max: 100)

**Response (200 OK):**
```json
{
  "success": true,
  "data": [
    {
      "id": 1,
      "username": "john.doe",
      "enabled": true
    },
    {
      "id": 2,
      "username": "jane.smith",
      "enabled": true
    }
  ]
}
```

### GET /api/users/{id}

Get user details including SSH keys.

**Response (200 OK):**
```json
{
  "success": true,
  "data": {
    "id": 1,
    "username": "john.doe",
    "enabled": true,
    "keys": [
      {
        "id": 1,
        "key_type": "ssh-rsa",
        "key_base64": "AAAAB3NzaC1yc2EAAAA...",
        "comment": "john@laptop",
        "user_id": 1
      }
    ]
  }
}
```

### POST /api/users

Create a new user.

**Request Body:**
```json
{
  "username": "new.user"
}
```

**Response (201 Created):**
```json
{
  "success": true,
  "data": {
    "id": 3,
    "username": "new.user",
    "enabled": true
  },
  "message": "User created successfully"
}
```

### PUT /api/users/{id}

Update user information.

**Request Body:**
```json
{
  "username": "updated.user",
  "enabled": false
}
```

**Response (200 OK):**
```json
{
  "success": true,
  "data": null,
  "message": "User updated successfully"
}
```

### DELETE /api/users/{id}

Delete a user.

**Response (200 OK):**
```json
{
  "success": true,
  "data": null,
  "message": "User deleted successfully"
}
```

## SSH Keys Management

### GET /api/keys

List all SSH keys with user information.

**Response (200 OK):**
```json
{
  "success": true,
  "data": [
    {
      "id": 1,
      "key_type": "ssh-rsa",
      "key_base64": "AAAAB3NzaC1yc2EAAAA...",
      "comment": "john@laptop",
      "user_id": 1,
      "username": "john.doe"
    },
    {
      "id": 2,
      "key_type": "ssh-ed25519",
      "key_base64": "AAAAC3NzaC1lZDI1NTE5...",
      "comment": "jane@desktop",
      "user_id": 2,
      "username": "jane.smith"
    }
  ]
}
```

### POST /api/keys

Add a new SSH key to a user.

**Request Body:**
```json
{
  "user_id": 1,
  "public_key": "ssh-rsa AAAAB3NzaC1yc2EAAAA... user@hostname",
  "comment": "Optional comment"
}
```

**Response (201 Created):**
```json
{
  "success": true,
  "data": {
    "id": 3,
    "key_type": "ssh-rsa",
    "key_base64": "AAAAB3NzaC1yc2EAAAA...",
    "comment": "user@hostname",
    "user_id": 1
  },
  "message": "SSH key added successfully"
}
```

### DELETE /api/keys/{id}

Delete an SSH key.

**Response (200 OK):**
```json
{
  "success": true,
  "data": null,
  "message": "SSH key deleted successfully"
}
```

## Authorization Management

### GET /api/authorizations

List all user-host authorizations.

**Response (200 OK):**
```json
{
  "success": true,
  "data": [
    {
      "id": 1,
      "user_id": 1,
      "username": "john.doe",
      "host_id": 1,
      "host_name": "web-server-01",
      "login": "deploy",
      "options": "no-port-forwarding"
    },
    {
      "id": 2,
      "user_id": 2,
      "username": "jane.smith",
      "host_id": 1,
      "host_name": "web-server-01",
      "login": "backup",
      "options": null
    }
  ]
}
```

### POST /api/hosts/user/authorize

Authorize a user to access a specific host.

**Request Body:**
```json
{
  "host_id": 1,
  "user_id": 2,
  "login": "deploy",
  "options": "no-port-forwarding,no-agent-forwarding"
}
```

**Response (200 OK):**
```json
{
  "success": true,
  "data": null,
  "message": "User authorized successfully"
}
```

### DELETE /api/hosts/authorization/{id}

Remove a user authorization.

**Response (200 OK):**
```json
{
  "success": true,
  "data": null,
  "message": "Authorization deleted successfully"
}
```

## SSH Key Deployment

### POST /api/hosts/gen_authorized_keys

Generate authorized_keys file content for a specific host and login.

**Request Body:**
```json
{
  "host_name": "web-server-01",
  "login": "deploy"
}
```

**Response (200 OK):**
```json
{
  "success": true,
  "data": {
    "login": "deploy",
    "authorized_keys": "ssh-rsa AAAAB3NzaC1yc2EAAAA... john@laptop\\nssh-ed25519 AAAAC3NzaC1lZDI1NTE5... jane@desktop\\n",
    "diff_summary": "Found 2 differences"
  }
}
```

### POST /api/hosts/{name}/set_authorized_keys

Deploy authorized_keys content to a host.

**Request Body:**
```json
{
  "login": "deploy",
  "authorized_keys": "ssh-rsa AAAAB3NzaC1yc2EAAAA... john@laptop\\nssh-ed25519 AAAAC3NzaC1lZDI1NTE5... jane@desktop\\n"
}
```

**Response (200 OK):**
```json
{
  "success": true,
  "data": null,
  "message": "Authorized keys applied successfully"
}
```

## Key Difference Analysis

### GET /api/diff

Get differences between expected and actual SSH keys on hosts.

**Response (200 OK):**
```json
{
  "success": true,
  "data": {
    "differences": [
      {
        "host_name": "web-server-01",
        "login": "deploy",
        "missing_keys": [
          "ssh-rsa AAAAB3NzaC1yc2EAAAA... john@laptop"
        ],
        "extra_keys": [
          "ssh-rsa AAAAB3NzaC1yc2EOLD... old@key"
        ],
        "readonly_reason": null
      }
    ],
    "summary": {
      "total_hosts": 3,
      "hosts_with_differences": 1,
      "readonly_hosts": 0
    }
  }
}
```

## Error Responses

All API endpoints return consistent error responses:

### 400 Bad Request
```json
{
  "success": false,
  "message": "Invalid request data"
}
```

### 401 Unauthorized
```json
{
  "success": false,
  "message": "Unauthorized"
}
```

### 403 Forbidden
```json
{
  "success": false,
  "message": "Forbidden"
}
```

### 404 Not Found
```json
{
  "success": false,
  "message": "Resource not found"
}
```

### 500 Internal Server Error
```json
{
  "success": false,
  "message": "Internal server error description"
}
```

## Response Format

All successful API responses follow this format:

```json
{
  "success": true,
  "data": <response_data>,
  "message": "Optional success message"
}
```

- `success`: Boolean indicating if the request was successful
- `data`: The response payload (can be object, array, or null)
- `message`: Optional human-readable message

## Pagination

List endpoints support pagination with these query parameters:

- `page`: Page number (1-based, default: 1)
- `per_page`: Items per page (1-100, default: 20)

Paginated responses include:

```json
{
  "success": true,
  "data": {
    "items": [...],
    "total": 150,
    "page": 1,
    "per_page": 20,
    "total_pages": 8
  }
}
```

## Rate Limiting

No rate limiting is currently implemented, but consider implementing rate limiting for production deployments.

## CORS

The API supports CORS for frontend applications. In development, the frontend at `http://localhost:5173` is allowed.

## Security Considerations

1. **Authentication**: All endpoints require session authentication except `/api/auth/*`
2. **Input Validation**: All inputs are validated and sanitized
3. **SQL Injection**: Using parameterized queries via Diesel ORM
4. **XSS Protection**: JSON responses prevent XSS attacks
5. **Session Security**: Secure session cookies with appropriate flags
6. **SSH Security**: All SSH connections use key-based authentication

## Development and Testing

### Using curl

```bash
# Login
curl -X POST http://localhost:8000/api/auth/login \\
  -H "Content-Type: application/json" \\
  -d '{"username":"admin","password":"password"}' \\
  -c cookies.txt

# List hosts (using saved cookies)
curl -X GET http://localhost:8000/api/hosts \\
  -b cookies.txt

# Create host
curl -X POST http://localhost:8000/api/hosts \\
  -H "Content-Type: application/json" \\
  -b cookies.txt \\
  -d '{
    "name": "test-server",
    "address": "192.168.1.100",
    "port": 22,
    "username": "deploy"
  }'
```

### Postman Collection

A Postman collection with all endpoints and example requests is available in `/docs/postman/ssh-key-manager.json`.

### API Testing Tools

- **Thunder Client** (VS Code extension)
- **Insomnia** REST client
- **HTTPie** command-line tool

### Error Testing

Test error conditions:

1. **Authentication**: Try accessing protected endpoints without login
2. **Validation**: Send invalid data formats
3. **Not Found**: Request non-existent resources
4. **Duplicate Names**: Try creating hosts/users with existing names
5. **SSH Errors**: Test with unreachable hosts

---

For more information about the application architecture and development setup, see the main [README.md](../README.md) and [CLAUDE.md](../CLAUDE.md) files.