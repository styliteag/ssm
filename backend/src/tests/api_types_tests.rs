use serde_json::json;
use actix_web::{HttpResponse, ResponseError, http::StatusCode};

use crate::api_types::*;

#[cfg(test)]
mod api_response_tests {
    use super::*;

    #[test]
    fn test_api_response_success() {
        let data = "test data";
        let response = ApiResponse::success(data);
        
        assert!(response.success);
        assert_eq!(response.data, Some(data));
        assert!(response.message.is_none());
    }

    #[test]
    fn test_api_response_success_with_message() {
        let data = "test data";
        let message = "Operation completed";
        let response = ApiResponse::success_with_message(data, message.to_string());
        
        assert!(response.success);
        assert_eq!(response.data, Some(data));
        assert_eq!(response.message, Some(message.to_string()));
    }

    #[test]
    fn test_api_response_success_empty() {
        let response = ApiResponse::success_empty();
        
        assert!(response.success);
        assert!(response.data.is_none());
        assert!(response.message.is_none());
    }

    #[test]
    fn test_api_response_success_message() {
        let message = "Success message";
        let response = ApiResponse::success_message(message.to_string());
        
        assert!(response.success);
        assert!(response.data.is_none());
        assert_eq!(response.message, Some(message.to_string()));
    }

    #[test]
    fn test_api_response_error() {
        let message = "Error message";
        let response = ApiResponse::error(message.to_string());
        
        assert!(!response.success);
        assert!(response.data.is_none());
        assert_eq!(response.message, Some(message.to_string()));
    }

    #[test]
    fn test_api_response_serialization() {
        let response = ApiResponse::success("test data");
        let json_value = serde_json::to_value(&response).unwrap();
        
        assert_eq!(json_value["success"], true);
        assert_eq!(json_value["data"], "test data");
        assert!(json_value["message"].is_null());
    }

    #[test]
    fn test_api_response_deserialization() {
        let json_str = r#"{"success": true, "data": "test data", "message": null}"#;
        let response: ApiResponse<String> = serde_json::from_str(json_str).unwrap();
        
        assert!(response.success);
        assert_eq!(response.data, Some("test data".to_string()));
        assert!(response.message.is_none());
    }
}

#[cfg(test)]
mod api_error_tests {
    use super::*;

    #[test]
    fn test_api_error_new() {
        let message = "Test error";
        let error = ApiError::new(message.to_string());
        
        assert!(!error.success);
        assert_eq!(error.message, message);
    }

    #[test]
    fn test_api_error_bad_request() {
        let message = "Bad request error";
        let error = ApiError::bad_request(message.to_string());
        
        assert!(!error.success);
        assert_eq!(error.message, message);
    }

    #[test]
    fn test_api_error_not_found() {
        let message = "Not found error";
        let error = ApiError::not_found(message.to_string());
        
        assert!(!error.success);
        assert_eq!(error.message, message);
    }

    #[test]
    fn test_api_error_internal_error() {
        let message = "Internal server error";
        let error = ApiError::internal_error(message.to_string());
        
        assert!(!error.success);
        assert_eq!(error.message, message);
    }

    #[test]
    fn test_api_error_unauthorized() {
        let error = ApiError::unauthorized();
        
        assert!(!error.success);
        assert_eq!(error.message, "Unauthorized");
    }

    #[test]
    fn test_api_error_forbidden() {
        let error = ApiError::forbidden();
        
        assert!(!error.success);
        assert_eq!(error.message, "Forbidden");
    }

    #[test]
    fn test_api_error_display() {
        let message = "Test error message";
        let error = ApiError::new(message.to_string());
        
        assert_eq!(format!("{}", error), message);
    }

    #[test]
    fn test_api_error_response_unauthorized() {
        let error = ApiError::unauthorized();
        let response = error.error_response();
        
        assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    }

    #[test]
    fn test_api_error_response_forbidden() {
        let error = ApiError::forbidden();
        let response = error.error_response();
        
        assert_eq!(response.status(), StatusCode::FORBIDDEN);
    }

    #[test]
    fn test_api_error_response_not_found() {
        let error = ApiError::not_found("Resource not found".to_string());
        let response = error.error_response();
        
        assert_eq!(response.status(), StatusCode::NOT_FOUND);
    }

    #[test]
    fn test_api_error_response_bad_request() {
        let error = ApiError::bad_request("Invalid input".to_string());
        let response = error.error_response();
        
        assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    }

    #[test]
    fn test_api_error_serialization() {
        let error = ApiError::new("Test error".to_string());
        let json_value = serde_json::to_value(&error).unwrap();
        
        assert_eq!(json_value["success"], false);
        assert_eq!(json_value["message"], "Test error");
    }
}

#[cfg(test)]
mod pagination_tests {
    use super::*;

    #[test]
    fn test_pagination_query_default() {
        let query = PaginationQuery::default();
        
        assert_eq!(query.page(), 1);
        assert_eq!(query.per_page(), 20);
        assert_eq!(query.offset(), 0);
    }

    #[test]
    fn test_pagination_query_custom() {
        let query = PaginationQuery {
            page: Some(3),
            per_page: Some(10),
        };
        
        assert_eq!(query.page(), 3);
        assert_eq!(query.per_page(), 10);
        assert_eq!(query.offset(), 20); // (3-1) * 10
    }

    #[test]
    fn test_pagination_query_bounds() {
        let query = PaginationQuery {
            page: Some(0), // Should be clamped to 1
            per_page: Some(150), // Should be clamped to 100
        };
        
        assert_eq!(query.page(), 1);
        assert_eq!(query.per_page(), 100);
    }

    #[test]
    fn test_pagination_query_negative_per_page() {
        let query = PaginationQuery {
            page: Some(1),
            per_page: Some(0), // Should be clamped to 1
        };
        
        assert_eq!(query.per_page(), 1);
    }

    #[test]
    fn test_paginated_response() {
        let items = vec!["item1", "item2", "item3"];
        let response = PaginatedResponse::new(items.clone(), 25, 2, 10);
        
        assert_eq!(response.items, items);
        assert_eq!(response.total, 25);
        assert_eq!(response.page, 2);
        assert_eq!(response.per_page, 10);
        assert_eq!(response.total_pages, 3); // ceil(25/10)
    }

    #[test]
    fn test_paginated_response_exact_pages() {
        let items = vec!["item1", "item2"];
        let response = PaginatedResponse::new(items, 20, 1, 10);
        
        assert_eq!(response.total_pages, 2); // exactly 20/10
    }

    #[test]
    fn test_paginated_response_single_page() {
        let items = vec!["item1"];
        let response = PaginatedResponse::new(items, 1, 1, 10);
        
        assert_eq!(response.total_pages, 1);
    }

    #[test]
    fn test_paginated_response_serialization() {
        let items = vec!["test"];
        let response = PaginatedResponse::new(items, 1, 1, 10);
        let json_value = serde_json::to_value(&response).unwrap();
        
        assert_eq!(json_value["items"], json!(["test"]));
        assert_eq!(json_value["total"], 1);
        assert_eq!(json_value["page"], 1);
        assert_eq!(json_value["per_page"], 10);
        assert_eq!(json_value["total_pages"], 1);
    }
}

#[cfg(test)]
mod auth_types_tests {
    use super::*;

    #[test]
    fn test_login_request_deserialization() {
        let json_str = r#"{"username": "testuser", "password": "testpass"}"#;
        let request: LoginRequest = serde_json::from_str(json_str).unwrap();
        
        assert_eq!(request.username, "testuser");
        assert_eq!(request.password, "testpass");
    }

    #[test]
    fn test_token_response_serialization() {
        let response = TokenResponse {
            token: "jwt_token_here".to_string(),
            expires_in: 3600,
        };
        let json_value = serde_json::to_value(&response).unwrap();
        
        assert_eq!(json_value["token"], "jwt_token_here");
        assert_eq!(json_value["expires_in"], 3600);
    }

    #[test]
    fn test_auth_status_response() {
        let response = AuthStatusResponse {
            logged_in: true,
            username: Some("testuser".to_string()),
        };
        let json_value = serde_json::to_value(&response).unwrap();
        
        assert_eq!(json_value["logged_in"], true);
        assert_eq!(json_value["username"], "testuser");
    }

    #[test]
    fn test_auth_status_response_not_logged_in() {
        let response = AuthStatusResponse {
            logged_in: false,
            username: None,
        };
        let json_value = serde_json::to_value(&response).unwrap();
        
        assert_eq!(json_value["logged_in"], false);
        assert!(json_value["username"].is_null());
    }
}

#[cfg(test)]
mod to_api_response_tests {
    use super::*;

    #[test]
    fn test_to_api_response_success() {
        let result: Result<String, String> = Ok("success data".to_string());
        let response = result.to_api_response().unwrap();
        
        assert_eq!(response.status(), StatusCode::OK);
    }

    #[test]
    fn test_to_api_response_error() {
        let result: Result<String, String> = Err("error message".to_string());
        let error = result.to_api_response().unwrap_err();
        
        assert_eq!(error.message, "error message");
    }
}

#[cfg(test)]
mod edge_cases_tests {
    use super::*;

    #[test]
    fn test_empty_strings() {
        let response = ApiResponse::success("".to_string());
        assert_eq!(response.data, Some("".to_string()));
        
        let error = ApiError::new("".to_string());
        assert_eq!(error.message, "");
    }

    #[test]
    fn test_unicode_strings() {
        let unicode_data = "测试数据 🚀";
        let response = ApiResponse::success(unicode_data);
        assert_eq!(response.data, Some(unicode_data));
        
        let error = ApiError::new(unicode_data.to_string());
        assert_eq!(error.message, unicode_data);
    }

    #[test]
    fn test_very_long_strings() {
        let long_string = "a".repeat(10000);
        let response = ApiResponse::success(long_string.clone());
        assert_eq!(response.data, Some(long_string.clone()));
        
        let error = ApiError::new(long_string.clone());
        assert_eq!(error.message, long_string);
    }

    #[test]
    fn test_special_characters() {
        let special_data = r#"{"key": "value", "special": "\n\t\r\\"}"#;
        let response = ApiResponse::success(special_data);
        let json_value = serde_json::to_value(&response).unwrap();
        
        // Should serialize and deserialize correctly
        let roundtrip: ApiResponse<String> = serde_json::from_value(json_value).unwrap();
        assert_eq!(roundtrip.data, Some(special_data.to_string()));
    }

    #[test]
    fn test_pagination_edge_cases() {
        // Test with very large numbers
        let query = PaginationQuery {
            page: Some(u32::MAX),
            per_page: Some(u32::MAX),
        };
        
        assert_eq!(query.page(), u32::MAX);
        assert_eq!(query.per_page(), 100); // Should be clamped to max
        
        // Test offset calculation doesn't overflow
        let safe_query = PaginationQuery {
            page: Some(1000),
            per_page: Some(100),
        };
        assert_eq!(safe_query.offset(), 99900);
    }

    #[test]
    fn test_malformed_json_handling() {
        // This should fail gracefully
        let malformed_json = r#"{"success": true, "data": "unclosed string}"#;
        let result: Result<ApiResponse<String>, _> = serde_json::from_str(malformed_json);
        assert!(result.is_err());
    }

    #[test]
    fn test_missing_fields() {
        // Test with missing optional fields
        let minimal_json = r#"{"success": true}"#;
        let response: ApiResponse<String> = serde_json::from_str(minimal_json).unwrap();
        
        assert!(response.success);
        assert!(response.data.is_none());
        assert!(response.message.is_none());
    }
}

#[cfg(test)]
mod type_safety_tests {
    use super::*;

    #[test]
    fn test_different_data_types() {
        // Test with various data types
        let string_response = ApiResponse::success("string".to_string());
        let number_response = ApiResponse::success(42i32);
        let bool_response = ApiResponse::success(true);
        let vec_response = ApiResponse::success(vec![1, 2, 3]);
        
        assert_eq!(string_response.data, Some("string".to_string()));
        assert_eq!(number_response.data, Some(42));
        assert_eq!(bool_response.data, Some(true));
        assert_eq!(vec_response.data, Some(vec![1, 2, 3]));
    }

    #[test]
    fn test_nested_structures() {
        #[derive(serde::Serialize, serde::Deserialize, PartialEq, Debug)]
        struct NestedData {
            field1: String,
            field2: i32,
            field3: Vec<String>,
        }
        
        let nested = NestedData {
            field1: "test".to_string(),
            field2: 123,
            field3: vec!["a".to_string(), "b".to_string()],
        };
        
        let response = ApiResponse::success(nested.clone());
        assert_eq!(response.data, Some(nested));
    }

    #[test]
    fn test_option_types() {
        let some_response = ApiResponse::success(Some("value".to_string()));
        let none_response: ApiResponse<Option<String>> = ApiResponse::success(None);
        
        assert_eq!(some_response.data, Some(Some("value".to_string())));
        assert_eq!(none_response.data, Some(None));
    }
}