use diesel::associations::HasTable;
use diesel::prelude::*;

use crate::{
    models::{PublicKey, User},
    schema::users::dsl::*,
    sshclient::SshPublicKey,
    DbConnection,
};

use super::query;

impl User {
    pub fn get_all_users(conn: &mut DbConnection) -> Result<Vec<Self>, String> {
        query(users::table().load::<Self>(conn))
    }

    pub fn get_user(conn: &mut DbConnection, user: String) -> Result<Self, String> {
        query(users::table().filter(username.eq(user)).first::<Self>(conn))
    }

    pub fn get_keys(&self, conn: &mut DbConnection) -> Result<Vec<SshPublicKey>, String> {
        use crate::schema::keys::dsl::*;

        query(keys.filter(user_id.eq(self.id)).load::<PublicKey>(conn)).map(|k| {
            k.iter()
                .map(|key| SshPublicKey::from(key.to_owned()))
                .collect()
        })
    }
}
