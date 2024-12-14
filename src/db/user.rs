use diesel::dsl::insert_into;
use diesel::{delete, prelude::*};

use crate::schema::user_key;
use crate::schema::{host, user, user_in_host};
use crate::{
    models::{NewUser, PublicUserKey, User},
    DbConnection,
};

use super::{query, query_drop, UserAndOptions};

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

    /// Update a user's enabled status and username in the Database
    pub fn update_user(conn: &mut DbConnection, old_username: &str, new_username: &str, _enabled: bool) -> Result<(), String> {
        use diesel::prelude::*;
        use crate::schema::user::dsl::*;
        
        // Update username and enabled status
        diesel::update(user)
            .filter(username.eq(old_username))
            .set((
                username.eq(new_username),
                enabled.eq(enabled),
            ))
            .execute(conn)
            .map_err(|e| e.to_string())?;
        
        Ok(())
    }

    /// Find all hosts this user is authorized on
    pub fn get_authorizations(
        &self,
        conn: &mut DbConnection,
    ) -> Result<Vec<UserAndOptions>, String> {
        query(
            user_in_host::table
                .inner_join(user::table)
                .inner_join(host::table)
                .filter(user::username.eq(&self.username))
                .select((
                    user_in_host::id,
                    host::name,
                    user_in_host::user,
                    user_in_host::options,
                ))
                .load::<UserAndOptions>(conn),
        )
    }
}
