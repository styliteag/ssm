use diesel::prelude::*;
use serde::Deserialize;

#[derive(Queryable, Selectable, Clone)]
#[diesel(table_name = crate::schema::hosts)]
#[diesel(check_for_backend(diesel::sqlite::Sqlite))]
pub struct Host {
    pub id: i32,
    pub name: String,
    pub username: String,
    pub hostname: String,
    pub port: i16,
}

#[derive(Insertable, Clone)]
#[diesel(table_name = crate::schema::hosts)]
#[diesel(check_for_backend(diesel::sqlite::Sqlite))]
pub struct NewHost {
    pub name: String,
    pub hostname: String,
    pub username: String,
    pub port: i16,
}

#[derive(Queryable, Selectable, Associations, Clone)]
#[diesel(table_name = crate::schema::user_keys)]
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
#[diesel(table_name = crate::schema::user_keys)]
#[diesel(check_for_backend(diesel::sqlite::Sqlite))]
#[diesel(belongs_to(User))]
pub struct NewPublicUserKey {
    pub key_type: String,
    pub key_base64: String,
    pub comment: Option<String>,
    pub user_id: i32,
}

#[derive(Queryable, Selectable, Associations, Clone)]
#[diesel(table_name = crate::schema::host_keys)]
#[diesel(check_for_backend(diesel::sqlite::Sqlite))]
#[diesel(belongs_to(Host))]
pub struct HostKey {
    pub id: i32,
    pub key_type: String,
    pub key_base64: String,
    pub comment: Option<String>,
    pub host_id: i32,
}

impl std::fmt::Display for HostKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self.comment.clone() {
            Some(c) => write!(
                f,
                "Type: {}; Comment: {}; Base64: {}",
                self.key_type, c, self.key_base64
            ),
            None => write!(f, "Type: {}; Base64: {}", self.key_type, self.key_base64),
        }
    }
}

#[derive(Insertable, Associations, Clone)]
#[diesel(table_name = crate::schema::host_keys)]
#[diesel(check_for_backend(diesel::sqlite::Sqlite))]
#[diesel(belongs_to(Host))]
pub struct NewHostKey {
    pub key_type: String,
    pub key_base64: String,
    pub comment: Option<String>,
    pub host_id: i32,
}

#[derive(Queryable, Selectable, Clone)]
#[diesel(table_name = crate::schema::users)]
#[diesel(check_for_backend(diesel::sqlite::Sqlite))]
pub struct User {
    pub id: i32,
    pub username: String,
    pub enabled: bool,
}

#[derive(Insertable, Deserialize, Clone)]
#[diesel(table_name = crate::schema::users)]
pub struct NewUser {
    pub username: String,
}
