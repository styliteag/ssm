use diesel::prelude::*;
use diesel::{associations::HasTable, dsl::insert_into};

use crate::schema::user_keys;
use crate::schema::users;
use crate::{
    models::{NewUser, PublicUserKey, User},
    sshclient::SshPublicKey,
    DbConnection,
};

use super::query;

impl User {
    pub fn get_all_users(conn: &mut DbConnection) -> Result<Vec<Self>, String> {
        query(users::table.load::<Self>(conn))
    }

    pub fn get_user(conn: &mut DbConnection, user: String) -> Result<Self, String> {
        use crate::schema::users::dsl::*;
        query(users::table().filter(username.eq(user)).first::<Self>(conn))
    }

    pub fn get_keys(&self, conn: &mut DbConnection) -> Result<Vec<SshPublicKey>, String> {
        query(
            user_keys::table
                .filter(user_keys::user_id.eq(self.id))
                .load::<PublicUserKey>(conn),
        )
        .map(|k| {
            k.iter()
                .map(|key| SshPublicKey::from(key.to_owned()))
                .collect()
        })
    }

    pub fn add_user(conn: &mut DbConnection, user: NewUser) -> Result<String, String> {
        query(insert_into(users::table).values(user.clone()).execute(conn)).map(|_| user.username)
    }
}
