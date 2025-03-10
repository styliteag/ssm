use actix_identity::Identity;
use actix_web::{
    body::BoxBody,
    dev::{ServiceRequest, ServiceResponse},
    http::header,
    middleware::Next,
    Error, FromRequest, HttpResponse,
};
use log::info;

const LOG_TARGET: &str = "ssm:webserver";

pub async fn authentication(
    request: ServiceRequest,
    next: Next<BoxBody>,
) -> Result<ServiceResponse<BoxBody>, Error> {
    let path = request.path();
    let method = request.method();

    // Skip authentication for login page, static files, and assets
    if path.starts_with("/auth/")
        || path.starts_with("/static/")
        || path.ends_with(".css")
        || path.ends_with(".js")
    {
        info!(target: LOG_TARGET, "{} {} (public path)", method, path);
        return next.call(request).await;
    }

    let identity = Identity::extract(request.parts().0);

    let Ok(id) = identity.await else {
        info!(target: LOG_TARGET, "{} {} (unauthorized)", method, path);
        let response = HttpResponse::Found()
            .append_header((header::LOCATION, "/auth/login"))
            .insert_header(("HX-Redirect", "/auth/login"))
            .body("<a href=\"/auth/login\">Login</a>");
        return Ok(ServiceResponse::new(request.into_parts().0, response));
    };

    info!(
        target: LOG_TARGET,
        "{} {} (authenticated user: {})",
        method,
        path,
        id.id().unwrap_or_else(|_| "unknown".to_owned())
    );
    next.call(request).await
}
