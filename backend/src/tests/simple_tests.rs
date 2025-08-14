use crate::api_types::*;

#[cfg(test)]
mod basic_tests {
    use super::*;

    #[test]
    fn test_api_response_creation() {
        let response = ApiResponse::success("test data");
        assert!(response.success);
        assert_eq!(response.data, Some("test data"));
        assert!(response.message.is_none());
    }

    #[test] 
    fn test_api_error_creation() {
        let error = ApiError::new("test error".to_string());
        assert!(!error.success);
        assert_eq!(error.message, "test error");
    }

    #[test]
    fn test_pagination_query_defaults() {
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
        assert_eq!(query.offset(), 20);
    }

    #[test]
    fn test_paginated_response() {
        let items = vec!["item1", "item2"];
        let response = PaginatedResponse::new(items.clone(), 25, 2, 10);
        
        assert_eq!(response.items, items);
        assert_eq!(response.total, 25);
        assert_eq!(response.page, 2);
        assert_eq!(response.per_page, 10);
        assert_eq!(response.total_pages, 3);
    }
}

#[cfg(test)]
mod model_tests {
    use crate::models::*;

    #[test]
    fn test_public_user_key_to_openssh() {
        let key = PublicUserKey {
            id: 1,
            key_type: "ssh-rsa".to_string(),
            key_base64: "AAAAB3NzaC1yc2EAAAADAQABAAABgQ".to_string(),
            comment: Some("test@example.com".to_string()),
            user_id: 1,
        };

        let openssh = key.to_openssh();
        assert_eq!(openssh, "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQ test@example.com");
    }

    #[test]
    fn test_public_user_key_to_openssh_no_comment() {
        let key = PublicUserKey {
            id: 1,
            key_type: "ssh-rsa".to_string(),
            key_base64: "AAAAB3NzaC1yc2EAAAADAQABAAABgQ".to_string(),
            comment: None,
            user_id: 1,
        };

        let openssh = key.to_openssh();
        assert_eq!(openssh, "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQ");
    }

    #[test]
    fn test_key_preview() {
        let key = PublicUserKey {
            id: 1,
            key_type: "ssh-rsa".to_string(),
            key_base64: "AAAAB3NzaC1yc2EAAAADAQABAAABgQ".to_string(),
            comment: Some("test@example.com".to_string()),
            user_id: 1,
        };

        let preview = key.key_preview();
        assert_eq!(preview, "...BgQ");
    }

    #[test]
    fn test_new_user_creation() {
        let new_user = NewUser {
            username: "testuser".to_string(),
        };
        assert_eq!(new_user.username, "testuser");
    }

    #[test]
    fn test_new_host_creation() {
        let new_host = NewHost {
            name: "testhost".to_string(),
            address: "192.168.1.100".to_string(),
            port: 22,
            username: "ubuntu".to_string(),
            key_fingerprint: "SHA256:test".to_string(),
            jump_via: None,
        };
        assert_eq!(new_host.name, "testhost");
        assert_eq!(new_host.port, 22);
        assert!(new_host.jump_via.is_none());
    }

    #[test]
    fn test_new_public_user_key_creation() {
        let new_key = NewPublicUserKey::new(
            russh::keys::Algorithm::Rsa { hash: russh::keys::AlgHash::Sha2_256 },
            "AAAAB3NzaC1yc2EAAAADAQABAAABgQ".to_string(),
            Some("test@example.com".to_string()),
            1,
        );
        // Just verify it can be created without panicking
        assert_eq!(format!("{:?}", new_key).contains("NewPublicUserKey"), true);
    }
}

#[cfg(test)]
mod utilities_tests {
    use uuid::Uuid;

    #[test]
    fn test_uuid_generation() {
        let uuid1 = Uuid::new_v4();
        let uuid2 = Uuid::new_v4();
        assert_ne!(uuid1, uuid2);
    }

    #[test]
    fn test_random_string_generation() {
        let s1 = Uuid::new_v4().to_string();
        let s2 = Uuid::new_v4().to_string();
        assert_ne!(s1, s2);
        assert!(!s1.is_empty());
        assert!(!s2.is_empty());
    }
}

#[cfg(test)]
mod configuration_tests {
    use std::time::Duration;

    #[test]
    fn test_default_timeout() {
        const fn default_timeout() -> Duration {
            Duration::from_secs(120)
        }
        
        let timeout = default_timeout();
        assert_eq!(timeout.as_secs(), 120);
    }

    #[test]
    fn test_duration_conversion() {
        let timeout = Duration::from_secs(30);
        assert_eq!(timeout.as_millis(), 30000);
        assert_eq!(timeout.as_secs(), 30);
    }
}