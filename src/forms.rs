use actix_web::{http::StatusCode, HttpResponse, HttpResponseBuilder};
use askama::Template;

use crate::ssh::SshClientError;

#[derive(Debug, Clone)]
struct Modal {
    /// Title displayed at the top
    pub title: String,
    /// Where to direct requests from the modal
    pub request_target: String,
    /// HTML content of the form inside the modal. This is not escaped
    pub template: String,
}

#[derive(Debug, Clone)]
enum FormResponse {
    /// A successful Response with a message
    Success(String),
    /// An error Response with a message
    Error(String),
    /// Show a modal to the user
    Dialog(Modal),
}

#[derive(Debug, Clone)]
pub struct FormResponseBuilder {
    triggers: Vec<String>,
    status: StatusCode,
    response: FormResponse,
    redirect: Option<String>,
    close_modal: bool,
}

#[derive(Template)]
#[template(path = "forms/form_response.html")]
struct FormResponseTemplate {
    res: FormResponse,
}

impl Default for FormResponseBuilder {
    fn default() -> Self {
        Self {
            triggers: vec![],
            status: StatusCode::INTERNAL_SERVER_ERROR,
            response: FormResponse::Error("No response message set.".to_owned()),
            redirect: None,
            close_modal: false,
        }
    }
}

impl FormResponseBuilder {
    pub fn success(message: impl Into<String>) -> Self {
        Self {
            status: StatusCode::OK,
            response: FormResponse::Success(message.into()),
            ..Default::default()
        }
    }

    pub fn created(message: impl Into<String>) -> Self {
        Self {
            status: StatusCode::CREATED,
            response: FormResponse::Success(message.into()),
            ..Default::default()
        }
    }

    pub fn error(message: impl ToString) -> Self {
        Self {
            status: StatusCode::UNPROCESSABLE_ENTITY,
            response: FormResponse::Error(message.to_string()),
            ..Default::default()
        }
    }

    pub fn not_found(message: impl Into<String>) -> Self {
        Self {
            status: StatusCode::NOT_FOUND,
            response: FormResponse::Error(message.into()),
            ..Default::default()
        }
    }

    pub fn dialog(
        title: impl Into<String>,
        request_target: impl Into<String>,
        template: impl ToString,
    ) -> Self {
        Self {
            status: StatusCode::OK,
            response: FormResponse::Dialog(Modal {
                title: title.into(),
                request_target: request_target.into(),
                template: template.to_string(),
            }),
            ..Default::default()
        }
    }

    pub fn close_modal(mut self) -> Self {
        self.close_modal = true;
        self
    }

    pub fn _set_status(mut self, status: StatusCode) -> Self {
        self.status = status;
        self
    }

    pub fn add_trigger(mut self, trigger: impl Into<String>) -> Self {
        self.triggers.push(trigger.into());
        self
    }

    pub fn with_redirect(mut self, location: impl Into<String>) -> Self {
        self.redirect = Some(location.into());
        self
    }

    pub fn into_response(mut self) -> HttpResponse<actix_web::body::BoxBody> {
        let mut builder = HttpResponseBuilder::new(self.status);
        builder.insert_header(("X-FORM", "true"));

        if matches!(self.response, FormResponse::Dialog(_)) {
            builder.insert_header(("X-MODAL", "open"));
        };
        if self.close_modal {
            builder.insert_header(("X-MODAL", "close"));
        }

        if !self.triggers.is_empty() {
            builder.insert_header((String::from("HX-Trigger"), self.triggers.join(",")));
        };

        if let Some(redirect) = self.redirect {
            builder.insert_header((String::from("HX-Redirect"), redirect));

            // HTMX doesn't process headers on 3xx codes
            if self.status.is_redirection() {
                self.status = StatusCode::OK;
            }
        }

        builder.body(FormResponseTemplate { res: self.response }.to_string())
    }
}

impl std::fmt::Display for FormResponseBuilder {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match &self.response {
            FormResponse::Success(message) => write!(f, "Success: {message}"),
            FormResponse::Error(message) => write!(f, "Error: {message}"),
            FormResponse::Dialog(Modal { title, .. }) => write!(f, "Dialog: {title}"),
        }
    }
}

impl actix_web::Responder for FormResponseBuilder {
    type Body = actix_web::body::BoxBody;

    fn respond_to(self, _req: &actix_web::HttpRequest) -> HttpResponse<Self::Body> {
        self.into_response()
    }
}

impl actix_web::ResponseError for FormResponseBuilder {
    fn status_code(&self) -> StatusCode {
        if !(self.status.is_client_error() || self.status.is_server_error()) {
            StatusCode::INTERNAL_SERVER_ERROR
        } else {
            self.status
        }
    }

    fn error_response(&self) -> HttpResponse<actix_web::body::BoxBody> {
        self.clone().into_response()
    }
}

impl From<SshClientError> for FormResponseBuilder {
    fn from(value: SshClientError) -> Self {
        Self::error(value.to_string())
    }
}
