use diesel::prelude::*;
use serde::Deserialize;

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
    pub key_fingerprint: String,
    pub jump_via: Option<i32>,
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
}

impl TryFrom<&PublicUserKey> for ssh_key::public::PublicKey {
    type Error = String;
    fn try_from(value: &PublicUserKey) -> Result<Self, Self::Error> {
        Self::from_openssh(&value.to_openssh()).map_err(|e| e.to_string())
    }
}
