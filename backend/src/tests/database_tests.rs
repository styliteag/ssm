use diesel::prelude::*;
use diesel::result::Error as DieselError;

use crate::tests::test_utils::*;
use crate::models::*;
use crate::db::*;

#[tokio::test]
async fn test_database_connection() {
    let test_config = TestConfig::new().await;
    let mut conn = test_config.db_pool.get().unwrap();
    
    // Test basic connection functionality
    use crate::schema::user::dsl::*;
    let result: QueryResult<i64> = user.count().get_result(&mut conn);
    assert!(result.is_ok());
}

#[tokio::test]
async fn test_foreign_key_constraints() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let mut conn = test_config.db_pool.get().unwrap();
    
    // Try to create a key for non-existent user
    use crate::schema::user_key::dsl::*;
    let invalid_key = NewPublicUserKey::new(
        russh::keys::Algorithm::Rsa { hash: russh::keys::AlgHash::Sha2_256 },
        "AAAAB3NzaC1yc2EAAAADAQABAAABgQC7vbqajDw5XJjfsQM1dLDEeuxWiZQ".to_string(),
        Some("test@example.com".to_string()),
        99999, // Non-existent user ID
    );
    
    let result = diesel::insert_into(user_key)
        .values(&invalid_key)
        .execute(&mut conn);
    
    // Should fail due to foreign key constraint
    assert!(result.is_err());
    match result.unwrap_err() {
        DieselError::DatabaseError(_, _) => {},
        _ => panic!("Expected database error for foreign key constraint"),
    }
}

#[tokio::test]
async fn test_user_crud_operations() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let mut conn = test_config.db_pool.get().unwrap();
    
    // Create user
    let new_user = NewUser {
        username: "test_crud_user".to_string(),
    };
    let user_id = User::add_user(&mut conn, &new_user).unwrap();
    assert!(user_id > 0);
    
    // Read user
    let user = User::get_from_id(&mut conn, user_id).await.unwrap().unwrap();
    assert_eq!(user.username, "test_crud_user");
    assert!(user.enabled);
    
    // Update user (disable)
    User::disable_user(&mut conn, user_id).unwrap();
    let updated_user = User::get_from_id(&mut conn, user_id).await.unwrap().unwrap();
    assert!(!updated_user.enabled);
    
    // Enable user
    User::enable_user(&mut conn, user_id).unwrap();
    let enabled_user = User::get_from_id(&mut conn, user_id).await.unwrap().unwrap();
    assert!(enabled_user.enabled);
    
    // Delete user
    let deleted_count = User::delete(&mut conn, user_id).unwrap();
    assert_eq!(deleted_count, 1);
    
    // Verify deletion
    let deleted_user = User::get_from_id(&mut conn, user_id).await.unwrap();
    assert!(deleted_user.is_none());
}

#[tokio::test]
async fn test_host_crud_operations() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let mut conn = test_config.db_pool.get().unwrap();
    
    // Create host
    let new_host = NewHost {
        name: "test_crud_host".to_string(),
        address: "192.168.1.100".to_string(),
        port: 22,
        username: "ubuntu".to_string(),
        key_fingerprint: "SHA256:test_fingerprint".to_string(),
        jump_via: None,
    };
    let host_id = Host::add_host(&mut conn, &new_host).unwrap();
    assert!(host_id > 0);
    
    // Read host
    let host = Host::get_from_id(conn, host_id).await.unwrap().unwrap();
    assert_eq!(host.name, "test_crud_host");
    assert_eq!(host.address, "192.168.1.100");
    assert_eq!(host.port, 22);
    
    // Update host
    let mut conn = test_config.db_pool.get().unwrap();
    Host::update_host(
        &mut conn,
        "test_crud_host".to_string(),
        "updated_host".to_string(),
        "192.168.1.200".to_string(),
        "admin".to_string(),
        2222,
        Some("SHA256:updated_fingerprint".to_string()),
        None,
    ).unwrap();
    
    let updated_host = Host::get_from_name(conn, "updated_host".to_string()).await.unwrap().unwrap();
    assert_eq!(updated_host.address, "192.168.1.200");
    assert_eq!(updated_host.port, 2222);
    assert_eq!(updated_host.username, "admin");
    
    // Delete host
    let mut conn = test_config.db_pool.get().unwrap();
    let deleted_count = updated_host.delete(&mut conn).unwrap();
    assert_eq!(deleted_count, 1);
    
    // Verify deletion
    let deleted_host = Host::get_from_id(conn, host_id).await.unwrap();
    assert!(deleted_host.is_none());
}

#[tokio::test]
async fn test_key_crud_operations() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let mut conn = test_config.db_pool.get().unwrap();
    
    // Create user first
    let user_id = insert_test_user(&test_config.db_pool, "test_key_user").await.unwrap();
    
    // Create key
    let new_key = NewPublicUserKey::new(
        russh::keys::Algorithm::Rsa { hash: russh::keys::AlgHash::Sha2_256 },
        "AAAAB3NzaC1yc2EAAAADAQABAAABgQC7vbqajDw5XJjfsQM1dLDEeuxWiZQ".to_string(),
        Some("test_crud@example.com".to_string()),
        user_id,
    );
    let key_id = PublicUserKey::add_public_key(&mut conn, &new_key).unwrap();
    assert!(key_id > 0);
    
    // Read key
    let key = PublicUserKey::get_from_id(&mut conn, key_id).await.unwrap().unwrap();
    assert_eq!(key.key_type, "ssh-rsa");
    assert_eq!(key.comment, Some("test_crud@example.com".to_string()));
    assert_eq!(key.user_id, user_id);
    
    // Update key comment
    PublicUserKey::update_comment(&mut conn, key_id, Some("updated_comment@example.com".to_string())).unwrap();
    let updated_key = PublicUserKey::get_from_id(&mut conn, key_id).await.unwrap().unwrap();
    assert_eq!(updated_key.comment, Some("updated_comment@example.com".to_string()));
    
    // Delete key
    let deleted_count = PublicUserKey::delete(&mut conn, key_id).unwrap();
    assert_eq!(deleted_count, 1);
    
    // Verify deletion
    let deleted_key = PublicUserKey::get_from_id(&mut conn, key_id).await.unwrap();
    assert!(deleted_key.is_none());
}

#[tokio::test]
async fn test_authorization_operations() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let mut conn = test_config.db_pool.get().unwrap();
    
    // Create user and host
    let user_id = insert_test_user(&test_config.db_pool, "test_auth_user").await.unwrap();
    let host_id = insert_test_host(&test_config.db_pool, "test_auth_host").await.unwrap();
    
    // Create authorization
    Host::authorize_user(&mut conn, host_id, user_id, "ubuntu".to_string(), Some("no-port-forwarding".to_string())).unwrap();
    
    // Get authorizations for host
    let host = Host::get_from_id(conn, host_id).await.unwrap().unwrap();
    let mut conn = test_config.db_pool.get().unwrap();
    let authorizations = host.get_authorized_users(&mut conn).unwrap();
    assert_eq!(authorizations.len(), 1);
    assert_eq!(authorizations[0].login, "ubuntu");
    assert_eq!(authorizations[0].options, Some("no-port-forwarding".to_string()));
    
    // Get authorizations for user
    let user = User::get_from_id(&mut conn, user_id).await.unwrap().unwrap();
    let user_authorizations = user.get_authorizations(&mut conn).unwrap();
    assert_eq!(user_authorizations.len(), 1);
    assert_eq!(user_authorizations[0].login, "ubuntu");
    
    // Delete authorization
    use crate::schema::authorization::dsl::*;
    let auth_id: i32 = authorization
        .filter(host_id.eq(host_id))
        .filter(user_id.eq(user_id))
        .select(id)
        .first(&mut conn)
        .unwrap();
    
    Host::delete_authorization(&mut conn, auth_id).unwrap();
    
    // Verify deletion
    let remaining_auths = host.get_authorized_users(&mut conn).unwrap();
    assert_eq!(remaining_auths.len(), 0);
}

#[tokio::test]
async fn test_cascade_delete_user() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let mut conn = test_config.db_pool.get().unwrap();
    
    // Create user with keys and authorizations
    let user_id = insert_test_user(&test_config.db_pool, "cascade_user").await.unwrap();
    let host_id = insert_test_host(&test_config.db_pool, "cascade_host").await.unwrap();
    let key_id = insert_test_key(&test_config.db_pool, user_id).await.unwrap();
    
    Host::authorize_user(&mut conn, host_id, user_id, "ubuntu".to_string(), None).unwrap();
    
    // Verify everything exists
    let user = User::get_from_id(&mut conn, user_id).await.unwrap();
    let key = PublicUserKey::get_from_id(&mut conn, key_id).await.unwrap();
    assert!(user.is_some());
    assert!(key.is_some());
    
    use crate::schema::authorization::dsl::*;
    let auth_count: i64 = authorization
        .filter(user_id.eq(user_id))
        .count()
        .get_result(&mut conn)
        .unwrap();
    assert_eq!(auth_count, 1);
    
    // Delete user
    User::delete(&mut conn, user_id).unwrap();
    
    // Verify cascade delete
    let deleted_user = User::get_from_id(&mut conn, user_id).await.unwrap();
    let deleted_key = PublicUserKey::get_from_id(&mut conn, key_id).await.unwrap();
    assert!(deleted_user.is_none());
    assert!(deleted_key.is_none());
    
    let remaining_auths: i64 = authorization
        .filter(user_id.eq(user_id))
        .count()
        .get_result(&mut conn)
        .unwrap();
    assert_eq!(remaining_auths, 0);
}

#[tokio::test]
async fn test_cascade_delete_host() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let mut conn = test_config.db_pool.get().unwrap();
    
    // Create host with authorizations
    let user_id = insert_test_user(&test_config.db_pool, "cascade_user").await.unwrap();
    let host_id = insert_test_host(&test_config.db_pool, "cascade_host").await.unwrap();
    
    Host::authorize_user(&mut conn, host_id, user_id, "ubuntu".to_string(), None).unwrap();
    
    // Verify authorization exists
    use crate::schema::authorization::dsl::*;
    let auth_count: i64 = authorization
        .filter(host_id.eq(host_id))
        .count()
        .get_result(&mut conn)
        .unwrap();
    assert_eq!(auth_count, 1);
    
    // Delete host
    let host = Host::get_from_id(conn, host_id).await.unwrap().unwrap();
    let mut conn = test_config.db_pool.get().unwrap();
    host.delete(&mut conn).unwrap();
    
    // Verify cascade delete
    let remaining_auths: i64 = authorization
        .filter(host_id.eq(host_id))
        .count()
        .get_result(&mut conn)
        .unwrap();
    assert_eq!(remaining_auths, 0);
}

#[tokio::test]
async fn test_jumphost_relationships() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let mut conn = test_config.db_pool.get().unwrap();
    
    // Create jumphost
    let jumphost_id = insert_test_host(&test_config.db_pool, "jumphost").await.unwrap();
    
    // Create host with jumphost
    let new_host = NewHost {
        name: "target_host".to_string(),
        address: "10.0.0.100".to_string(),
        port: 22,
        username: "ubuntu".to_string(),
        key_fingerprint: "SHA256:test_fingerprint".to_string(),
        jump_via: Some(jumphost_id),
    };
    let target_host_id = Host::add_host(&mut conn, &new_host).unwrap();
    
    // Verify relationship
    let target_host = Host::get_from_id(conn, target_host_id).await.unwrap().unwrap();
    assert_eq!(target_host.jump_via, Some(jumphost_id));
    
    // Get dependent hosts
    let jumphost = Host::get_from_id(conn, jumphost_id).await.unwrap().unwrap();
    let mut conn = test_config.db_pool.get().unwrap();
    let dependent_hosts = jumphost.get_dependant_hosts(&mut conn).unwrap();
    assert_eq!(dependent_hosts.len(), 1);
    assert_eq!(dependent_hosts[0], "target_host");
}

#[tokio::test]
async fn test_unique_constraints() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let mut conn = test_config.db_pool.get().unwrap();
    
    // Create user
    let new_user = NewUser {
        username: "unique_user".to_string(),
    };
    User::add_user(&mut conn, &new_user).unwrap();
    
    // Try to create another user with same username
    let duplicate_user = NewUser {
        username: "unique_user".to_string(),
    };
    let result = User::add_user(&mut conn, &duplicate_user);
    assert!(result.is_err());
    
    // Create host
    let new_host = NewHost {
        name: "unique_host".to_string(),
        address: "192.168.1.100".to_string(),
        port: 22,
        username: "ubuntu".to_string(),
        key_fingerprint: "SHA256:test_fingerprint".to_string(),
        jump_via: None,
    };
    Host::add_host(&mut conn, &new_host).unwrap();
    
    // Try to create another host with same name
    let duplicate_host = NewHost {
        name: "unique_host".to_string(),
        address: "192.168.1.200".to_string(),
        port: 22,
        username: "ubuntu".to_string(),
        key_fingerprint: "SHA256:other_fingerprint".to_string(),
        jump_via: None,
    };
    let result = Host::add_host(&mut conn, &duplicate_host);
    assert!(result.is_err());
}

#[tokio::test]
async fn test_database_transaction_rollback() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let mut conn = test_config.db_pool.get().unwrap();
    
    // Start a transaction
    let result = conn.transaction::<_, DieselError, _>(|conn| {
        // Create a user
        let new_user = NewUser {
            username: "transaction_user".to_string(),
        };
        let user_id = User::add_user(conn, &new_user)?;
        
        // Verify user exists within transaction
        let user = User::get_from_id(conn, user_id).await?;
        assert!(user.is_some());
        
        // Force a rollback by returning an error
        Err(DieselError::RollbackTransaction)
    });
    
    assert!(result.is_err());
    
    // Verify user was not created due to rollback
    use crate::schema::user::dsl::*;
    let user_count: i64 = user
        .filter(username.eq("transaction_user"))
        .count()
        .get_result(&mut conn)
        .unwrap();
    assert_eq!(user_count, 0);
}

#[tokio::test]
async fn test_concurrent_operations() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    // Test concurrent user creation
    let handles: Vec<_> = (0..10)
        .map(|i| {
            let pool = test_config.db_pool.clone();
            tokio::spawn(async move {
                let mut conn = pool.get().unwrap();
                let new_user = NewUser {
                    username: format!("concurrent_user_{}", i),
                };
                User::add_user(&mut conn, &new_user)
            })
        })
        .collect();
    
    // Wait for all operations to complete
    let mut successful_creates = 0;
    for handle in handles {
        if handle.await.unwrap().is_ok() {
            successful_creates += 1;
        }
    }
    
    // All should succeed since usernames are unique
    assert_eq!(successful_creates, 10);
    
    // Verify all users were created
    let mut conn = test_config.db_pool.get().unwrap();
    use crate::schema::user::dsl::*;
    let total_users: i64 = user
        .filter(username.like("concurrent_user_%"))
        .count()
        .get_result(&mut conn)
        .unwrap();
    assert_eq!(total_users, 10);
}

#[tokio::test]
async fn test_data_integrity() {
    let test_config = TestConfig::new().await;
    cleanup_test_data(&test_config.db_pool).await;
    
    let mut conn = test_config.db_pool.get().unwrap();
    
    // Create test data
    let user_id = insert_test_user(&test_config.db_pool, "integrity_user").await.unwrap();
    let host_id = insert_test_host(&test_config.db_pool, "integrity_host").await.unwrap();
    let key_id = insert_test_key(&test_config.db_pool, user_id).await.unwrap();
    
    Host::authorize_user(&mut conn, host_id, user_id, "ubuntu".to_string(), None).unwrap();
    
    // Verify all relationships are correct
    let user = User::get_from_id(&mut conn, user_id).await.unwrap().unwrap();
    let host = Host::get_from_id(conn, host_id).await.unwrap().unwrap();
    let mut conn = test_config.db_pool.get().unwrap();
    let key = PublicUserKey::get_from_id(&mut conn, key_id).await.unwrap().unwrap();
    
    assert_eq!(key.user_id, user_id);
    
    let user_keys = user.get_keys(&mut conn).unwrap();
    assert_eq!(user_keys.len(), 1);
    assert_eq!(user_keys[0].id, key_id);
    
    let host_authorizations = host.get_authorized_users(&mut conn).unwrap();
    assert_eq!(host_authorizations.len(), 1);
    assert_eq!(host_authorizations[0].user_id, user_id);
    
    let user_authorizations = user.get_authorizations(&mut conn).unwrap();
    assert_eq!(user_authorizations.len(), 1);
    assert_eq!(user_authorizations[0].host_id, host_id);
}

#[cfg(test)]
mod performance_tests {
    use super::*;
    use std::time::Instant;

    #[tokio::test]
    async fn test_bulk_operations_performance() {
        let test_config = TestConfig::new().await;
        cleanup_test_data(&test_config.db_pool).await;
        
        let start = Instant::now();
        
        // Create many users
        for i in 0..100 {
            let username = format!("perf_user_{}", i);
            insert_test_user(&test_config.db_pool, &username).await.unwrap();
        }
        
        let creation_time = start.elapsed();
        println!("Created 100 users in {:?}", creation_time);
        
        // Query all users
        let start = Instant::now();
        let mut conn = test_config.db_pool.get().unwrap();
        let all_users = User::get_all_users(&mut conn).unwrap();
        let query_time = start.elapsed();
        
        println!("Queried {} users in {:?}", all_users.len(), query_time);
        assert_eq!(all_users.len(), 100);
        
        // Performance should be reasonable (adjust thresholds as needed)
        assert!(creation_time.as_millis() < 5000); // Less than 5 seconds
        assert!(query_time.as_millis() < 1000);    // Less than 1 second
    }
}