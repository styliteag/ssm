use super::query;
use crate::{models::PublicKey, DbConnection};
use diesel::associations::HasTable;
use diesel::prelude::*;

impl PublicKey {
    pub fn get_all_keys(conn: &mut DbConnection) -> Result<Vec<Self>, String> {
        use crate::schema::keys::dsl::*;

        query(keys::table().load::<Self>(conn))
    }

    pub fn get_all_keys_as<T>(conn: &mut DbConnection) -> Result<Vec<T>, String>
    where
        T: From<Self>,
    {
        Self::get_all_keys(conn)
            .map(|keys| keys.iter().map(|key| T::from(key.to_owned())).collect())
    }
}
