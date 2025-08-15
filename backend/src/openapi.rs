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
        description = "Secure API for managing SSH keys across multiple hosts. All endpoints except authentication require session-based authentication via login.",
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