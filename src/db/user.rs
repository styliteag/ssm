use diesel::dsl::insert_into;
use diesel::{delete, prelude::*};

use crate::schema::user;
use crate::schema::user_key;
use crate::{
    models::{NewUser, PublicUserKey, User},
    DbConnection,
};

use super::{query, query_drop};

impl User {
    pub fn get_all_users(conn: &mut DbConnection) -> Result<Vec<Self>, String> {
        query(user::table.load::<Self>(conn))
    }

    pub fn get_user(conn: &mut DbConnection, username: String) -> Result<Self, String> {
        query(
            user::table
                .filter(user::username.eq(username))
                .first::<Self>(conn),
        )
    }

    pub fn get_keys(&self, conn: &mut DbConnection) -> Result<Vec<PublicUserKey>, String> {
        query(
            user_key::table
                .filter(user_key::user_id.eq(self.id))
                .load::<PublicUserKey>(conn),
        )
    }

    /// Add a new user to the Database. Returns the username
    pub fn add_user(conn: &mut DbConnection, new_user: NewUser) -> Result<String, String> {
        query(
            insert_into(user::table)
                .values(new_user.clone())
                .execute(conn),
        )
        .map(|_| new_user.username)
    }

    /// Delete a user from the Database
    pub fn delete_user(conn: &mut DbConnection, username: &str) -> Result<(), String> {
        query_drop(delete(user::table.filter(user::username.eq(username))).execute(conn))
    }
}
