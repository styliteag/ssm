use actix_identity::Identity;
use actix_web::{
    body::{EitherBody, BoxBody},
    dev::{ServiceRequest, ServiceResponse},
    middleware::Next,
    Error, FromRequest, HttpResponse,
};
use log::info;

#[allow(dead_code)]
const LOG_TARGET: &str = "ssm:webserver";

#[allow(dead_code)]
pub async fn authentication(
    request: ServiceRequest,
    next: Next<EitherBody<BoxBody>>,
) -> Result<ServiceResponse<EitherBody<BoxBody>>, Error> {
    let path = request.path();
    let method = request.method();

    // Skip authentication for login page, static files, and assets
    if path.starts_with("/authentication/")
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
        let response = HttpResponse::Unauthorized()
            .json(crate::api_types::ApiError::unauthorized())
            .map_into_boxed_body()
            .map_into_right_body();
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
