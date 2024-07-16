use diesel::prelude::*;

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
#[diesel(table_name = crate::schema::keys)]
#[diesel(check_for_backend(diesel::sqlite::Sqlite))]
#[diesel(belongs_to(Host), belongs_to(User))]
pub struct PublicKey {
    pub id: i32,
    pub key_type: String,
    pub key_base64: String,
    pub comment: Option<String>,
    pub host_id: Option<i32>,
    pub user_id: Option<i32>,
}

#[derive(Insertable, Associations, Clone)]
#[diesel(table_name = crate::schema::keys)]
#[diesel(check_for_backend(diesel::sqlite::Sqlite))]
#[diesel(belongs_to(Host))]
pub struct NewPublicKey {
    pub key_type: String,
    pub key_base64: String,
    pub comment: Option<String>,
    pub host_id: Option<i32>,
    pub user_id: Option<i32>,
}

#[derive(Queryable, Selectable, Clone)]
#[diesel(table_name = crate::schema::users)]
#[diesel(check_for_backend(diesel::sqlite::Sqlite))]
pub struct User {
    pub id: i32,
    pub username: String,
    pub enabled: bool,
}
