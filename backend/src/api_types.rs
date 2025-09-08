use serde::{Deserialize, Serialize};
use actix_web::{HttpResponse, ResponseError};
use std::fmt;
use utoipa::ToSchema;

/// Standard API response wrapper for successful operations
#[derive(Serialize, Deserialize, ToSchema)]
pub struct ApiResponse<T> {
    pub success: bool,
    pub data: Option<T>,
    pub message: Option<String>,
}

impl<T: Serialize> ApiResponse<T> {
    pub fn success(data: T) -> Self {
        Self {
            success: true,
            data: Some(data),
            message: None,
        }
    }

    pub fn success_with_message(data: T, message: String) -> Self {
        Self {
            success: true,
            data: Some(data),
            message: Some(message),
        }
    }
}

impl ApiResponse<()> {
    #[allow(dead_code)]
    pub fn success_empty() -> Self {
        Self {
            success: true,
            data: None,
            message: None,
        }
    }

    pub fn success_message(message: String) -> Self {
        Self {
            success: true,
            data: None,
            message: Some(message),
        }
    }

    #[allow(dead_code)]
    pub fn error(message: String) -> Self {
        Self {
            success: false,
            data: None,
            message: Some(message),
        }
    }
}

/// Custom error type for API responses
#[derive(Debug, Serialize, ToSchema)]
pub struct ApiError {
    pub success: bool,
    pub message: String,
}

impl ApiError {
    pub fn new(message: String) -> Self {
        Self {
            success: false,
            message,
        }
    }

    pub fn bad_request(message: String) -> Self {
        Self::new(message)
    }

    pub fn not_found(message: String) -> Self {
        Self::new(message)
    }

    pub fn internal_error(message: String) -> Self {
        Self::new(message)
    }

    #[allow(dead_code)]
    pub fn unauthorized() -> Self {
        Self::new("Unauthorized".to_string())
    }

    #[allow(dead_code)]
    pub fn forbidden() -> Self {
        Self::new("Forbidden".to_string())
    }
}

impl fmt::Display for ApiError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.message)
    }
}

impl ResponseError for ApiError {
    fn error_response(&self) -> HttpResponse {
        let status = match self.message.as_str() {
            "Unauthorized" => actix_web::http::StatusCode::UNAUTHORIZED,
            "Forbidden" => actix_web::http::StatusCode::FORBIDDEN,
            msg if msg.contains("not found") => actix_web::http::StatusCode::NOT_FOUND,
            _ => actix_web::http::StatusCode::BAD_REQUEST,
        };

        HttpResponse::build(status).json(self)
    }
}

/// Helper trait to convert results to API responses
#[allow(dead_code)]
pub trait ToApiResponse<T> {
    fn to_api_response(self) -> Result<HttpResponse, ApiError>;
}

impl<T: Serialize> ToApiResponse<T> for Result<T, String> {
    fn to_api_response(self) -> Result<HttpResponse, ApiError> {
        match self {
            Ok(data) => Ok(HttpResponse::Ok().json(ApiResponse::success(data))),
            Err(msg) => Err(ApiError::new(msg)),
        }
    }
}


/// Login request structure
#[derive(Deserialize, ToSchema)]
#[allow(dead_code)]
pub struct LoginRequest {
    pub username: String,
    pub password: String,
}

/// Authentication status response
#[derive(Serialize, ToSchema)]
#[allow(dead_code)]
pub struct AuthStatusResponse {
    pub logged_in: bool,
    pub username: Option<String>,
}

/// Paginated list response
#[derive(Serialize, ToSchema)]
#[allow(dead_code)]
pub struct PaginatedResponse<T> {
    pub items: Vec<T>,
    pub total: u64,
    pub page: u32,
    pub per_page: u32,
    pub total_pages: u32,
}

impl<T> PaginatedResponse<T> {
    #[allow(dead_code)]
    pub fn new(items: Vec<T>, total: u64, page: u32, per_page: u32) -> Self {
        let total_pages = (total as f64 / per_page as f64).ceil() as u32;
        Self {
            items,
            total,
            page,
            per_page,
            total_pages,
        }
    }
}

/// Query parameters for pagination
#[derive(Deserialize, ToSchema)]
#[allow(dead_code)]
pub struct PaginationQuery {
    pub page: Option<u32>,
    pub per_page: Option<u32>,
}

impl Default for PaginationQuery {
    fn default() -> Self {
        Self {
            page: Some(1),
            per_page: Some(20),
        }
    }
}

impl PaginationQuery {
    #[allow(dead_code)]
    pub fn page(&self) -> u32 {
        self.page.unwrap_or(1).max(1)
    }

    #[allow(dead_code)]
    pub fn per_page(&self) -> u32 {
        self.per_page.unwrap_or(20).min(100).max(1)
    }

    #[allow(dead_code)]
    pub fn offset(&self) -> u32 {
        (self.page() - 1) * self.per_page()
    }
}