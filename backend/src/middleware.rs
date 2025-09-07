use actix_identity::Identity;
use actix_session::{Session, SessionExt};
use actix_web::{
    body::EitherBody,
    dev::{ServiceRequest, ServiceResponse, Service, Transform},
    Error, HttpResponse, FromRequest,
};
use futures_util::future::LocalBoxFuture;
use log::{info, debug, warn};
use std::future::{Ready, ready};
use std::rc::Rc;

use crate::logging::SecurityLogger;



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
            // - Authentication endpoints (needed for login/logout)
            // - Static files and documentation
            // - Health checks and root
            // - OPTIONS requests (CORS preflight)
            // Note: Since AuthEnforcement runs first, these paths won't reach here
            // unless they are in the public list, but we keep the checks for consistency
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
                    SecurityLogger::log_security_event(
                        "csrf_violation",
                        &format!("CSRF validation failed for {} {}: {}", method, path, msg),
                        "high"
                    );

                    // Log suspicious activity for CSRF violations
                    let peer_addr = req.connection_info().peer_addr().unwrap_or("unknown").to_string();
                    SecurityLogger::log_suspicious_activity(
                        "csrf_attack_attempt",
                        &peer_addr,
                        &format!("CSRF token validation failed for {} {} from IP {}", method, path, peer_addr)
                    );

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

/// Authentication Enforcement Middleware
/// Forces authentication on all routes except explicitly excluded ones
pub struct AuthEnforcement;

impl<S, B> Transform<S, ServiceRequest> for AuthEnforcement
where
    S: Service<ServiceRequest, Response = ServiceResponse<B>, Error = Error> + 'static,
    S::Future: 'static,
    B: 'static,
{
    type Response = ServiceResponse<EitherBody<B>>;
    type Error = Error;
    type InitError = ();
    type Transform = AuthEnforcementMiddleware<S>;
    type Future = Ready<Result<Self::Transform, Self::InitError>>;

    fn new_transform(&self, service: S) -> Self::Future {
        ready(Ok(AuthEnforcementMiddleware {
            service: Rc::new(service),
        }))
    }
}

pub struct AuthEnforcementMiddleware<S> {
    service: Rc<S>,
}

impl<S, B> Service<ServiceRequest> for AuthEnforcementMiddleware<S>
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
            let path = req.path().to_string();
            let method = req.method().clone();

            // Define public routes that don't require authentication
            let public_paths = [
                "/",                                    // API info
                "/health",                             // Health check
                "/api-docs/openapi.json",              // OpenAPI spec
                "/api/auth/login",                     // Login (must be public)
                "/api/auth/logout",                    // Logout (must be public)
                "/api/auth/status",                    // Auth status (must be public)
            ];

            // Check if path starts with any public path
            let is_public = public_paths.iter().any(|public_path| {
                if *public_path == "/" {
                    path == "/"
                } else {
                    path.starts_with(public_path)
                }
            });

            // Skip authentication for public paths or OPTIONS requests (CORS preflight)
            if is_public || method == &actix_web::http::Method::OPTIONS {
                debug!("Skipping auth enforcement for public path: {} {}", method, path);
                let res = service.call(req).await?;
                return Ok(res.map_into_left_body());
            }

            // For all other paths, require authentication
            debug!("Enforcing authentication for {} {}", method, path);

            // Check if user is authenticated before consuming the request
            let (http_req, payload) = req.into_parts();
            let has_valid_auth = if let Ok(identity) = Identity::extract(&http_req).await {
                identity.id().is_ok()
            } else {
                false
            };

            if has_valid_auth {
                debug!("User authenticated, proceeding with request");
                let req = ServiceRequest::from_parts(http_req, payload);
                let res = service.call(req).await?;
                Ok(res.map_into_left_body())
            } else {
                warn!("No valid authentication for {} {}", method, path);
                let response = HttpResponse::Unauthorized()
                    .json(crate::api_types::ApiError::unauthorized())
                    .map_into_boxed_body()
                    .map_into_right_body();
                Ok(ServiceResponse::new(http_req, response))
            }
        })
    }
}


