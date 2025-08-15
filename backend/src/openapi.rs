use utoipa::OpenApi;
use utoipa_swagger_ui::SwaggerUi;
use utoipauto::utoipauto;

use crate::{
    api_types::*,
    models::*,
    db::UserAndOptions,
    routes::ApiInfo,
};

#[utoipauto(paths = "./src/routes")]
#[derive(OpenApi)]
#[openapi(
    components(
        schemas(
            // API types
            ApiError,
            TokenResponse,
            PaginationQuery,
            ApiInfo,
            
            // Models
            Host,
            NewHost,
            User,
            NewUser,
            PublicUserKey,
            NewPublicUserKey,
            UserAndOptions,
            
            // Additional schemas will be automatically discovered via ToSchema derives
        ),
        security_schemes(
            ("session_auth" = ("cookie", "ssm_session"))
        )
    ),
    security(
        ("session_auth" = [])
    ),
    tags(
        (name = "hosts", description = "Host management operations - requires authentication"),
        (name = "users", description = "User management operations - requires authentication"),
        (name = "keys", description = "SSH key management operations - requires authentication"),
        (name = "auth", description = "Authentication operations"),
        (name = "diff", description = "SSH key difference analysis - requires authentication"),
        (name = "authorization", description = "SSH authorization management - requires authentication"),
    ),
    info(
        title = "SSH Key Manager API",
        version = "0.0.1-alpha",
        description = "Secure API for managing SSH keys across multiple hosts.\n\n## Authentication\n\nThis API uses session-based authentication via HTTP cookies. To use authenticated endpoints:\n\n1. **Login**: POST to `/api/auth/login` with username/password credentials\n2. **Use the session**: All subsequent requests will automatically include the session cookie\n3. **Logout**: POST to `/api/auth/logout` to invalidate the session\n\nAll endpoints except `/api/auth/*` and public documentation endpoints require authentication. Unauthenticated requests will return `401 Unauthorized`.",
        contact(
            name = "SSM Support",
            url = "https://github.com/styliteag/ssm"
        ),
        license(
            name = "GPL-3.0",
            url = "https://www.gnu.org/licenses/gpl-3.0.html"
        )
    )
)]
pub struct ApiDoc;

pub fn swagger_ui() -> SwaggerUi {
    SwaggerUi::new("/swagger-ui/{_:.*}")
        .url("/api-docs/openapi.json", ApiDoc::openapi())
}