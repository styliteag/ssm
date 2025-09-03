use utoipa::OpenApi;
use utoipa_swagger_ui::SwaggerUi;

pub struct ApiDoc;

impl OpenApi for ApiDoc {
    fn openapi() -> utoipa::openapi::OpenApi {
        use utoipa::openapi::*;
        OpenApiBuilder::new()
            .info(InfoBuilder::new()
                .title("SSH Key Manager API")
                .version("0.1.0")
                .description(Some("Secure API for managing SSH keys across multiple hosts"))
                .build()
            )
            .build()
    }
}

pub fn swagger_ui() -> SwaggerUi {
    SwaggerUi::new("/swagger-ui/{_:.*}")
        .url("/api-docs/openapi.json", ApiDoc::openapi())
}