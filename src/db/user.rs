use diesel::associations::HasTable;
use diesel::prelude::*;
use log::error;

use crate::{
    models::{PublicKey, User},
    schema::users::dsl::*,
    sshclient::SshPublicKey,
    DbConnection,
};

use super::query;

impl User {
    pub fn get_all_users(conn: &mut DbConnection) -> Vec<User> {
        let db_res = users::table().load::<User>(conn);
        match db_res {
            Err(e) => {
                error!("{}", e.to_string());
                Vec::new()
            }
            Ok(a) => a,
        }
    }

    pub fn get_user(conn: &mut DbConnection, user: String) -> Option<User> {
        let db_res = users::table().filter(username.eq(user)).first::<User>(conn);
        let res = query(db_res);
        res.ok()
    }

    pub fn get_keys(&self, conn: &mut DbConnection) -> Result<Vec<SshPublicKey>, String> {
        use crate::schema::keys::dsl::*;

        let user_keys: Result<Vec<PublicKey>, diesel::result::Error> =
            keys.filter(user_id.eq(self.id)).load::<PublicKey>(conn);

        match user_keys {
            Ok(k) => Ok(k
                .iter()
                .map(|key| SshPublicKey::from(key.to_owned()))
                .collect()),
            Err(e) => Err(e.to_string()),
        }
    }
}
