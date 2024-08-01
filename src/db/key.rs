use super::{query, query_drop, UsernameAndKey};
use crate::models::NewPublicUserKey;
use crate::schema::user_keys;
use crate::schema::users;
use crate::{models::PublicUserKey, DbConnection};
use diesel::dsl::insert_into;
use diesel::prelude::*;

impl PublicUserKey {
    pub fn get_all_keys(conn: &mut DbConnection) -> Result<Vec<Self>, String> {
        query(user_keys::table.load::<Self>(conn))
    }

    pub fn get_all_keys_with_username(
        conn: &mut DbConnection,
    ) -> Result<Vec<UsernameAndKey>, String> {
        query(
            user_keys::table
                .inner_join(users::table)
                .select((users::username, PublicUserKey::as_select()))
                .load::<UsernameAndKey>(conn),
        )
    }

    pub fn get_all_keys_as<T>(conn: &mut DbConnection) -> Result<Vec<T>, String>
    where
        T: From<Self>,
    {
        Self::get_all_keys(conn)
            .map(|keys| keys.iter().map(|key| T::from(key.to_owned())).collect())
    }

    /// Add a new user key to the db
    pub fn add_key(conn: &mut DbConnection, key: NewPublicUserKey) -> Result<(), String> {
        query_drop(insert_into(user_keys::table).values(key).execute(conn))
    }
}
