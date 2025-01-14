use actix_identity::Identity;
use actix_web::{
    body::{BoxBody, MessageBody},
    dev::{forward_ready, Service, ServiceRequest, ServiceResponse, Transform},
    http::header,
    Error, FromRequest, HttpResponse,
};
use futures_util::future::LocalBoxFuture;
use std::future::{ready, Ready};
use std::rc::Rc;
use log::warn;

pub struct AuthMiddleware;

impl<S, B> Transform<S, ServiceRequest> for AuthMiddleware
where
    S: Service<ServiceRequest, Response = ServiceResponse<B>, Error = Error> + 'static,
    S::Future: 'static,
    B: MessageBody + 'static,
{
    type Response = ServiceResponse<BoxBody>;
    type Error = Error;
    type InitError = ();
    type Transform = AuthMiddlewareService<S>;
    type Future = Ready<Result<Self::Transform, Self::InitError>>;

    fn new_transform(&self, service: S) -> Self::Future {
        ready(Ok(AuthMiddlewareService {
            service: Rc::new(service),
        }))
    }
}

pub struct AuthMiddlewareService<S> {
    service: Rc<S>,
}

impl<S, B> Service<ServiceRequest> for AuthMiddlewareService<S>
where
    S: Service<ServiceRequest, Response = ServiceResponse<B>, Error = Error> + 'static,
    S::Future: 'static,
    B: MessageBody + 'static,
{
    type Response = ServiceResponse<BoxBody>;
    type Error = Error;
    type Future = LocalBoxFuture<'static, Result<Self::Response, Self::Error>>;

    forward_ready!(service);

    fn call(&self, req: ServiceRequest) -> Self::Future {
        let path = req.path().to_string();
        let method = req.method().to_string();

        // Skip authentication for login page, static files, and assets
        if req.path().starts_with("/auth/")
            || req.path().starts_with("/static/")
            || req.path().ends_with(".css")
            || req.path().ends_with(".js")
        {
            warn!("[Web] {} {} (public path)", method, path);
            let fut = self.service.call(req);
            return Box::pin(async move {
                let res = fut.await?;
                Ok(res.map_into_boxed_body())
            });
        }

        let (http_req, payload) = req.into_parts();
        let identity = Identity::extract(&http_req);
        let service = self.service.clone();

        Box::pin(async move {
            match identity.await {
                Ok(id) => {
                    warn!("[Web] {} {} (authenticated user: {})", method, path, 
                        id.id().unwrap_or_else(|_| "unknown".to_string()));
                    let req = ServiceRequest::from_parts(http_req, payload);
                    let res = service.call(req).await?;
                    Ok(res.map_into_boxed_body())
                }
                Err(_) => {
                    warn!("[Web] {} {} (unauthorized)", method, path);
                    let response = HttpResponse::Found()
                        .append_header((header::LOCATION, "/auth/login"))
                        .insert_header(("HX-Redirect", "/auth/login"))
                        .body("<a href=\"/auth/login\">Login</a>");
                    Ok(ServiceResponse::new(http_req, response).map_into_boxed_body())
                }
            }
        })
    }
}
