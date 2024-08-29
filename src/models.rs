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
    pub hostname: String,
    pub port: i32,
    pub key_fingerprint: String,
    pub jump_via: Option<i32>,
}

#[derive(Insertable, Clone)]
#[diesel(table_name = crate::schema::host)]
#[diesel(check_for_backend(diesel::sqlite::Sqlite))]
pub struct NewHost {
    pub name: String,
    pub hostname: String,
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
    pub key_type: String,
    pub key_base64: String,
    pub comment: Option<String>,
    pub user_id: i32,
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
