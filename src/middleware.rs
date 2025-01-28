use actix_identity::Identity;
use actix_web::{
    body::{BoxBody, MessageBody},
    dev::{forward_ready, Service, ServiceRequest, ServiceResponse, Transform},
    http::header,
    Error, FromRequest, HttpResponse,
};
use futures_util::future::LocalBoxFuture;
use log::warn;
use std::future::{ready, Ready};
use std::rc::Rc;

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

    fn call(&self, request: ServiceRequest) -> Self::Future {
        let path = request.path().to_owned();
        let method = request.method().to_owned();

        // Skip authentication for login page, static files, and assets
        if request.path().starts_with("/auth/")
            || request.path().starts_with("/static/")
            || request.path().ends_with(".css")
            || request.path().ends_with(".js")
        {
            warn!("[Web] {} {} (public path)", method, path);
            let fut = self.service.call(request);
            return Box::pin(async move {
                let res = fut.await?;
                Ok(res.map_into_boxed_body())
            });
        }

        let (http_req, payload) = request.into_parts();
        let identity = Identity::extract(&http_req);
        let service = self.service.clone();

        Box::pin(async move {
            let Ok(id) = identity.await else {
                warn!("[Web] {} {} (unauthorized)", method, path);
                let response = HttpResponse::Found()
                    .append_header((header::LOCATION, "/auth/login"))
                    .insert_header(("HX-Redirect", "/auth/login"))
                    .body("<a href=\"/auth/login\">Login</a>");
                return Ok(ServiceResponse::new(http_req, response).map_into_boxed_body());
            };

            warn!(
                "[Web] {} {} (authenticated user: {})",
                method,
                path,
                id.id().unwrap_or_else(|_| "unknown".to_owned())
            );
            let req = ServiceRequest::from_parts(http_req, payload);
            let res = service.call(req).await?;
            Ok(res.map_into_boxed_body())
        })
    }
}
