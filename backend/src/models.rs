use diesel::prelude::*;
use serde::{Deserialize, Serialize};
use utoipa::ToSchema;

// Import UpdateHostRequest for the update_host function
use crate::routes::host::UpdateHostRequest;

#[derive(Queryable, Selectable, Associations, Clone, Debug, Serialize, ToSchema)]
#[diesel(table_name = crate::schema::host)]
#[diesel(check_for_backend(diesel::sqlite::Sqlite))]
#[diesel(belongs_to(Host, foreign_key = jump_via))]
pub struct Host {
    pub id: i32,
    /// Host name
    pub name: String,
    /// Login
    pub username: String,
    pub address: String,
    pub port: i32,
    pub key_fingerprint: Option<String>,
    pub jump_via: Option<i32>,
    /// Whether this host is disabled (no SSH connections will be made)
    pub disabled: bool,
    /// Optional comment for this host
    pub comment: Option<String>,
}

impl Host {
    /// Updates the host's name, address, username, port, key_fingerprint, jump_via, disabled, and comment. This is a stub implementation; in a real application, you should perform a database update.
    pub fn update_host(
        conn: &mut crate::DbConnection,
        old_name: String,
        request: UpdateHostRequest,
    ) -> Result<(), actix_web::Error> {
        use crate::schema::host::dsl::*;
        log::warn!(
            "ssm::models::Host: Host update details for '{}':\n  Name -> {}\n  Address -> {}\n  Username -> {}\n  Port -> {}\n  Key Fingerprint -> {:?}\n  Jump Via -> {:?}\n  Disabled -> {}\n  Comment -> {:?}",
            old_name,
            request.name,
            request.address,
            request.username,
            request.port,
            request.key_fingerprint,
            request.jump_via,
            request.disabled,
            request.comment
        );

        diesel::update(host.filter(name.eq(&old_name)))
            .set((
                name.eq(&request.name),
                address.eq(&request.address),
                username.eq(&request.username),
                port.eq(request.port),
                key_fingerprint.eq(&request.key_fingerprint),
                jump_via.eq(request.jump_via),
                disabled.eq(request.disabled),
                comment.eq(&request.comment),
            ))
            .execute(conn)
            .map_err(actix_web::error::ErrorInternalServerError)?;

        Ok(())
    }
}

#[derive(Insertable, Clone, ToSchema)]
#[diesel(table_name = crate::schema::host)]
#[diesel(check_for_backend(diesel::sqlite::Sqlite))]
pub struct NewHost {
    pub name: String,
    pub address: String,
    pub port: i32,
    pub username: String,
    pub key_fingerprint: Option<String>,
    pub jump_via: Option<i32>,
    pub disabled: bool,
    pub comment: Option<String>,
}

#[derive(Queryable, Selectable, Associations, Clone, Debug, Serialize, ToSchema)]
#[diesel(table_name = crate::schema::user_key)]
#[diesel(check_for_backend(diesel::sqlite::Sqlite))]
#[diesel(belongs_to(User))]
pub struct PublicUserKey {
    pub id: i32,
    pub key_type: String,
    pub key_base64: String,
    pub name: Option<String>,
    pub extra_comment: Option<String>,
    pub user_id: i32,
}

#[derive(Insertable, Associations, Clone, ToSchema)]
#[diesel(table_name = crate::schema::user_key)]
#[diesel(check_for_backend(diesel::sqlite::Sqlite))]
#[diesel(belongs_to(User))]
pub struct NewPublicUserKey {
    key_type: String,
    key_base64: String,
    name: Option<String>,
    extra_comment: Option<String>,
    user_id: i32,
}

impl NewPublicUserKey {
    pub fn new(
        algorithm: russh::keys::Algorithm,
        base64: String,
        name: Option<String>,
        extra_comment: Option<String>,
        user: i32,
    ) -> Self {
        Self {
            key_type: algorithm.to_string(),
            key_base64: base64,
            name,
            extra_comment,
            user_id: user,
        }
    }

    // Legacy constructor for backward compatibility
    pub fn new_with_comment(
        algorithm: russh::keys::Algorithm,
        base64: String,
        comment: Option<String>,
        user: i32,
    ) -> Self {
        Self {
            key_type: algorithm.to_string(),
            key_base64: base64,
            name: comment, // Treat comment as name for backward compatibility
            extra_comment: None,
            user_id: user,
        }
    }
}

#[derive(Queryable, Selectable, Clone, Debug, Serialize, ToSchema)]
#[diesel(table_name = crate::schema::user)]
#[diesel(check_for_backend(diesel::sqlite::Sqlite))]
pub struct User {
    pub id: i32,
    pub username: String,
    pub enabled: bool,
    pub comment: Option<String>,
}

#[derive(Insertable, Deserialize, Clone, ToSchema)]
#[diesel(table_name = crate::schema::user)]
pub struct NewUser {
    pub username: String,
    pub comment: Option<String>,
}

impl PublicUserKey {
    pub fn to_openssh(&self) -> String {
        match &self.name {
            Some(name) => format!("{} {} {}", self.key_type, self.key_base64, name),
            None => format!("{} {}", self.key_type, self.key_base64),
        }
    }

    pub fn key_preview(&self) -> String {
        let preview: String = self
            .key_base64
            .chars()
            .rev()
            .take(5)
            .collect::<String>()
            .chars()
            .rev()
            .collect();
        format!("...{preview}")
    }
}

impl TryFrom<&PublicUserKey> for russh::keys::PublicKey {
    type Error = String;
    fn try_from(value: &PublicUserKey) -> Result<Self, Self::Error> {
        Self::from_openssh(&value.to_openssh()).map_err(|e| e.to_string())
    }
}
