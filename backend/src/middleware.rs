use actix_identity::Identity;
use actix_session::{Session, SessionExt};
use actix_web::{
    body::{EitherBody, BoxBody},
    dev::{ServiceRequest, ServiceResponse, Service, Transform},
    middleware::Next,
    Error, FromRequest, HttpResponse,
};
use futures_util::future::LocalBoxFuture;
use log::{info, debug};
use std::future::{Ready, ready};
use std::rc::Rc;

#[allow(dead_code)]
const LOG_TARGET: &str = "ssm:webserver";

/// Helper function to validate CSRF tokens
pub fn validate_csrf_token(session: &Session, header_token: Option<&str>) -> Result<(), String> {
    // Get stored token from session
    let stored_token = session.get::<String>("csrf_token")
        .unwrap_or(None);
    
    match (stored_token, header_token) {
        (Some(stored), Some(header)) if stored == header => Ok(()),
        (None, _) => Err("No CSRF token in session".to_string()),
        (_, None) => Err("Missing CSRF token header".to_string()),
        (Some(_), Some(_)) => Err("Invalid CSRF token".to_string()),
    }
}

/// CSRF Protection Middleware
pub struct CsrfProtection;

impl<S, B> Transform<S, ServiceRequest> for CsrfProtection
where
    S: Service<ServiceRequest, Response = ServiceResponse<B>, Error = Error> + 'static,
    S::Future: 'static,
    B: 'static,
{
    type Response = ServiceResponse<EitherBody<B>>;
    type Error = Error;
    type InitError = ();
    type Transform = CsrfProtectionMiddleware<S>;
    type Future = Ready<Result<Self::Transform, Self::InitError>>;

    fn new_transform(&self, service: S) -> Self::Future {
        ready(Ok(CsrfProtectionMiddleware {
            service: Rc::new(service),
        }))
    }
}

pub struct CsrfProtectionMiddleware<S> {
    service: Rc<S>,
}

impl<S, B> Service<ServiceRequest> for CsrfProtectionMiddleware<S>
where
    S: Service<ServiceRequest, Response = ServiceResponse<B>, Error = Error> + 'static,
    S::Future: 'static,
    B: 'static,
{
    type Response = ServiceResponse<EitherBody<B>>;
    type Error = Error;
    type Future = LocalBoxFuture<'static, Result<Self::Response, Self::Error>>;

    actix_web::dev::forward_ready!(service);

    fn call(&self, req: ServiceRequest) -> Self::Future {
        let service = self.service.clone();
        
        Box::pin(async move {
            let path = req.path();
            let method = req.method();
            
            // Skip CSRF check for:
            // - Authentication endpoints (needed for login)
            // - Static files and documentation
            // - Health checks and root
            // - OPTIONS requests (CORS preflight)
            if path.starts_with("/api/auth/")
                || path.starts_with("/static/")
                || path.starts_with("/api-docs/")
                || path == "/"
                || path == "/health"
                || method == &actix_web::http::Method::OPTIONS
            {
                debug!("Skipping CSRF check for {} {}", method, path);
                let res = service.call(req).await?;
                return Ok(res.map_into_left_body());
            }
            
            // Get session to check CSRF token
            let session = req.get_session();
            let header_token = req.headers()
                .get("X-CSRF-Token")
                .and_then(|h| h.to_str().ok());
            
            // Validate CSRF token
            match validate_csrf_token(&session, header_token) {
                Ok(()) => {
                    debug!("CSRF token valid for {} {}", method, path);
                    let res = service.call(req).await?;
                    Ok(res.map_into_left_body())
                }
                Err(msg) => {
                    info!("CSRF validation failed for {} {}: {}", method, path, msg);
                    let response = HttpResponse::Forbidden()
                        .json(crate::api_types::ApiError::new(msg))
                        .map_into_boxed_body()
                        .map_into_right_body();
                    Ok(ServiceResponse::new(req.into_parts().0, response))
                }
            }
        })
    }
}

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
