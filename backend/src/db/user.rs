use diesel::dsl::insert_into;
use diesel::{delete, prelude::*};

use crate::schema::user_key;
use crate::schema::{authorization, host, user};
use crate::{
    models::{NewUser, PublicUserKey, User},
    DbConnection,
};

use super::{query, query_drop, UserAndOptions};

// Type alias for authorization query results
type AuthorizationTuple = (i32, String, String, Option<String>, Option<String>);

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

    pub fn get_user_by_id(conn: &mut DbConnection, user_id: i32) -> Result<Self, String> {
        query(
            user::table
                .filter(user::id.eq(user_id))
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

    /// Update a user's enabled status, username, and comment in the Database
    pub fn update_user(
        conn: &mut DbConnection,
        old_username: &str,
        new_username: &str,
        enabled_status: bool,
        _comment: Option<String>,
    ) -> Result<(), String> {
        let _ = _comment; // Mark as used
        use crate::schema::user::dsl::*;
        use diesel::prelude::*;

        // Update username, enabled status, and comment
        let update_result = diesel::update(user)
            .filter(username.eq(old_username))
            .set((
                username.eq(new_username),
                enabled.eq(enabled_status),
                comment.eq(_comment)
            ))
            .execute(conn);

        match update_result {
            Ok(_) => Ok(()),
            Err(e) => Err(e.to_string()),
        }
    }

    /// Find all hosts this user is authorized on
    pub fn get_authorizations(
        &self,
        conn: &mut DbConnection,
    ) -> Result<Vec<UserAndOptions>, String> {
        let tuples: Result<Vec<AuthorizationTuple>, String> = query(
            authorization::table
                .inner_join(user::table)
                .inner_join(host::table)
                .filter(user::username.eq(&self.username))
                .select((
                    authorization::id,
                    host::name,
                    authorization::login,
                    authorization::options,
                    authorization::comment,
                ))
                .load::<AuthorizationTuple>(conn),
        );
        tuples.map(|vec| vec.into_iter().map(UserAndOptions::from).collect())
    }
}
