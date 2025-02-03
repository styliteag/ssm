use diesel::prelude::*;
use serde::Deserialize;
use crate::DbConnection;

#[derive(Queryable, Selectable, Associations, Clone, Debug)]
#[diesel(table_name = crate::schema::host)]
#[diesel(check_for_backend(diesel::sqlite::Sqlite))]
#[diesel(belongs_to(Host, foreign_key = jump_via))]
pub struct Host {
    pub id: i32,
    pub name: String,
    pub username: String,
    pub address: String,
    pub port: i32,
    pub key_fingerprint: Option<String>,
    pub jump_via: Option<i32>,
}

impl Host {
    /// Updates the host's name, address, username, port, key_fingerprint, and jump_via. This is a stub implementation; in a real application, you should perform a database update.
    pub fn update_host(
        conn: &mut crate::DbConnection,
        old_name: String,
        new_name: String,
        new_address: String,
        new_username: String,
        new_port: i32,
        new_key_fingerprint: Option<String>,
        new_jump_via: Option<i32>
    ) -> Result<(), actix_web::Error> {
        use crate::schema::host::dsl::*;
        log::warn!(
            "ssm::models::Host: Host update details for '{}':\n  Name -> {}\n  Address -> {}\n  Username -> {}\n  Port -> {}\n  Key Fingerprint -> {:?}\n  Jump Via -> {:?}",
            old_name,
            new_name,
            new_address,
            new_username,
            new_port,
            new_key_fingerprint,
            new_jump_via
        );

        diesel::update(host.filter(name.eq(&old_name)))
            .set((
                name.eq(new_name),
                address.eq(new_address),
                username.eq(new_username),
                port.eq(new_port),
                key_fingerprint.eq(new_key_fingerprint),
                jump_via.eq(new_jump_via),
            ))
            .execute(conn)
            .map_err(actix_web::error::ErrorInternalServerError)?;

        Ok(())
    }
}

#[derive(Insertable, Clone)]
#[diesel(table_name = crate::schema::host)]
#[diesel(check_for_backend(diesel::sqlite::Sqlite))]
pub struct NewHost {
    pub name: String,
    pub address: String,
    pub port: i32,
    pub username: String,
    pub key_fingerprint: String,
    pub jump_via: Option<i32>,
}

#[derive(Queryable, Selectable, Associations, Clone, Debug)]
#[diesel(table_name = crate::schema::user_key)]
#[diesel(check_for_backend(diesel::sqlite::Sqlite))]
#[diesel(belongs_to(User))]
pub struct PublicUserKey {
    pub id: i32,
    pub key_type: String,
    pub key_base64: String,
    pub comment: Option<String>,
    pub user_id: i32,
}

#[derive(Insertable, Associations, Clone)]
#[diesel(table_name = crate::schema::user_key)]
#[diesel(check_for_backend(diesel::sqlite::Sqlite))]
#[diesel(belongs_to(User))]
pub struct NewPublicUserKey {
    key_type: String,
    key_base64: String,
    comment: Option<String>,
    user_id: i32,
}

impl NewPublicUserKey {
    pub fn new(
        algorithm: ssh_key::Algorithm,
        base64: String,
        comment: Option<String>,
        user: i32,
    ) -> Self {
        Self {
            key_type: algorithm.to_string(),
            key_base64: base64,
            comment,
            user_id: user,
        }
    }
}

#[derive(Queryable, Selectable, Clone)]
#[diesel(table_name = crate::schema::user)]
#[diesel(check_for_backend(diesel::sqlite::Sqlite))]
pub struct User {
    pub id: i32,
    pub username: String,
    pub enabled: bool,
}

#[derive(Insertable, Deserialize, Clone)]
#[diesel(table_name = crate::schema::user)]
pub struct NewUser {
    pub username: String,
}

impl PublicUserKey {
    pub fn to_openssh(&self) -> String {
        match &self.comment {
            Some(comment) => format!("{} {} {}", self.key_type, self.key_base64, comment),
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

impl TryFrom<&PublicUserKey> for ssh_key::public::PublicKey {
    type Error = String;
    fn try_from(value: &PublicUserKey) -> Result<Self, Self::Error> {
        Self::from_openssh(&value.to_openssh()).map_err(|e| e.to_string())
    }
}
