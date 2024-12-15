use actix_web::{http::StatusCode, HttpResponse, HttpResponseBuilder};
use askama::Template;

use crate::sshclient::SshClientError;

#[derive(Debug)]
pub struct Modal {
    /// Title displayed at the top
    pub title: String,
    /// Where to direct requests from the modal
    pub request_target: String,
    /// HTML content of the form inside the modal. This is not escaped
    pub template: String,
}

#[derive(Debug)]
enum FormResponse {
    /// A successful Response with a message
    Success(String),
    /// An error Response with a message
    Error(String),
    /// Show a modal to the user
    Dialog(Modal),
}

#[derive(Debug)]
pub struct FormResponseBuilder {
    triggers: Vec<String>,
    status: StatusCode,
    response: FormResponse,
}

#[derive(Template)]
#[template(path = "forms/form_response.html")]
struct FormResponseTemplate {
    res: FormResponse,
}

impl FormResponseBuilder {
    pub fn success(message: String) -> Self {
        Self {
            triggers: Vec::new(),
            status: StatusCode::OK,
            response: FormResponse::Success(message),
        }
    }

    pub fn created(message: String) -> Self {
        Self {
            triggers: Vec::new(),
            status: StatusCode::CREATED,
            response: FormResponse::Success(message),
        }
    }

    pub fn error(message: String) -> Self {
        Self {
            triggers: Vec::new(),
            status: StatusCode::UNPROCESSABLE_ENTITY,
            response: FormResponse::Error(message),
        }
    }

    pub fn not_found(message: String) -> Self {
        Self {
            triggers: Vec::new(),
            status: StatusCode::NOT_FOUND,
            response: FormResponse::Error(message),
        }
    }

    pub fn dialog(modal: Modal) -> Self {
        Self {
            triggers: Vec::new(),
            status: StatusCode::OK,
            response: FormResponse::Dialog(modal),
        }
    }

    pub fn _set_status(mut self, status: StatusCode) -> Self {
        self.status = status;
        self
    }

    pub fn add_trigger(mut self, trigger: String) -> Self {
        self.triggers.push(trigger);
        self
    }

    pub fn with_redirect(mut self, location: &str) -> Self {
        self.status = StatusCode::FOUND;
        self.triggers.push(format!("redirect {}", location));
        self
    }

    pub fn into_response(self) -> HttpResponse<actix_web::body::BoxBody> {
        let mut builder = HttpResponseBuilder::new(self.status);
        builder.insert_header(("X-FORM", "true"));

        if matches!(self.response, FormResponse::Dialog(_)) {
            builder.insert_header(("X-MODAL", "open"));
        };
        if !self.triggers.is_empty() {
            builder.insert_header((String::from("HX-Trigger"), self.triggers.join(",")));
        };

        builder.body(FormResponseTemplate { res: self.response }.to_string())
    }
}

impl actix_web::Responder for FormResponseBuilder {
    type Body = actix_web::body::BoxBody;

    fn respond_to(self, _req: &actix_web::HttpRequest) -> HttpResponse<Self::Body> {
        self.into_response()
    }
}

impl From<SshClientError> for FormResponseBuilder {
    fn from(value: SshClientError) -> Self {
        FormResponseBuilder::error(value.to_string())
    }
}
