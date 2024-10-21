use crate::schema::host;
use crate::schema::user;
use crate::schema::user_in_host;
use crate::schema::user_key;
use crate::sshclient::ConnectionDetails;
use crate::sshclient::SshClientError;
use crate::{
    models::{Host, NewHost, PublicUserKey},
    DbConnection,
};
use diesel::dsl::insert_into;
use diesel::prelude::*;

use super::query;
use super::query_drop;
use super::AllowedUserOnHost;
use super::UserAndOptions;

impl Host {
    pub fn to_connection(&self) -> Result<ConnectionDetails, SshClientError> {
        Ok(ConnectionDetails::new(
            self.hostname.clone(),
            self.port
                .try_into()
                .map_err(|_| SshClientError::PortCastFailed)?,
        ))
    }

    /// Adds a new host to the database
    pub fn add_host(conn: &mut DbConnection, host: &NewHost) -> Result<i32, String> {
        query(insert_into(host::table).values(host.clone()).execute(conn)).map(|id| (id as i32))
    }

    pub fn authorize_user(
        conn: &mut DbConnection,
        host_id: i32,
        user_id: i32,
        user_on_host: String,
        options: Option<String>,
    ) -> Result<(), String> {
        query_drop(
            insert_into(user_in_host::table)
                .values((
                    user_in_host::host_id.eq(host_id),
                    user_in_host::user_id.eq(user_id),
                    user_in_host::user.eq(user_on_host),
                    user_in_host::options.eq(options),
                ))
                .execute(conn),
        )
    }

    /// Get authorized Users and associated options
    pub fn get_authorized_users(
        &self,
        conn: &mut DbConnection,
    ) -> Result<Vec<UserAndOptions>, String> {
        // let user_ids = self.get_authorized_user_ids(conn)?;

        query(
            user_in_host::table
                .inner_join(user::table)
                .select((user::username, user_in_host::user, user_in_host::options))
                .filter(user_in_host::host_id.eq(self.id))
                .load::<UserAndOptions>(conn),
        )
    }

    /// Get a host from a name
    pub fn get_host_name(conn: &mut DbConnection, host: String) -> Result<Option<Self>, String> {
        query(
            host::table
                .filter(host::name.eq(host))
                .first::<Self>(conn)
                .optional(),
        )
    }

    /// Get a host from an id
    pub fn get_host_id(conn: &mut DbConnection, host: i32) -> Result<Option<Self>, String> {
        query(
            host::table
                .filter(host::id.eq(host))
                .first::<Self>(conn)
                .optional(),
        )
    }
    pub fn get_all_hosts(conn: &mut DbConnection) -> Result<Vec<Self>, String> {
        query(host::table.load::<Self>(conn))
    }

    /// Gets all allowed users allowed on this host
    pub fn get_authorized_keys(
        &self,
        conn: &mut DbConnection,
    ) -> Result<Vec<AllowedUserOnHost>, String> {
        query(
            user::table
                .inner_join(user_key::table)
                .inner_join(user_in_host::table)
                .select((
                    PublicUserKey::as_select(),
                    user_in_host::user,
                    user::username,
                    user_in_host::options,
                ))
                .filter(user_in_host::host_id.eq(self.id))
                .load::<(PublicUserKey, String, String, Option<String>)>(conn),
        )
        .map(|allowed_list| {
            allowed_list
                .into_iter()
                .map(AllowedUserOnHost::from)
                .collect()
        })
    }
}
