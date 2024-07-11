use log::error;

use crate::{models::PublicKey, DbConnection};
use diesel::associations::HasTable;
use diesel::dsl::insert_into;
use diesel::prelude::*;

impl PublicKey {
    pub fn get_all_keys(conn: &mut DbConnection) -> Vec<PublicKey> {
        use crate::schema::keys::dsl::*;

        let db_res = keys::table().load::<PublicKey>(conn);
        match db_res {
            Err(e) => {
                error!("{}", e.to_string());
                Vec::new()
            }
            Ok(a) => a,
        }
    }

    pub fn get_all_keys_as<T>(conn: &mut DbConnection) -> Vec<T>
    where
        T: From<PublicKey>,
    {
        Self::get_all_keys(conn)
            .iter()
            .map(|key| T::from(key.to_owned()))
            .collect()
    }
}
