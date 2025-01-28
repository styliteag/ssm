use crate::schema::authorization;
use crate::schema::host;
use crate::schema::user;
use crate::schema::user_key;
use crate::ssh::ConnectionDetails;
use crate::ssh::SshClient;
use crate::ssh::SshClientError;
use crate::{
    models::{Host, NewHost, PublicUserKey},
    DbConnection,
};
use diesel::dsl::insert_into;
use diesel::prelude::*;
use diesel::r2d2::ConnectionManager;
use diesel::r2d2::PooledConnection;

use super::query;
use super::query_drop;
use super::AllowedUserOnHost;
use super::AuthorizedKeysList;
use super::UserAndOptions;

impl Host {
    pub fn to_connection(&self) -> Result<ConnectionDetails, SshClientError> {
        Ok(ConnectionDetails::new(
            self.address.clone(),
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
        login: String,
        mut options: Option<String>,
    ) -> Result<(), String> {
        if options.as_ref().is_some_and(String::is_empty) {
            options = None;
        }
        query_drop(
            insert_into(authorization::table)
                .values((
                    authorization::host_id.eq(host_id),
                    authorization::user_id.eq(user_id),
                    authorization::login.eq(login),
                    authorization::options.eq(options),
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
            authorization::table
                .inner_join(user::table)
                .filter(authorization::host_id.eq(self.id))
                .select((
                    authorization::id,
                    user::username,
                    authorization::login,
                    authorization::options,
                ))
                .load::<UserAndOptions>(conn),
        )
    }

    /// Get a host from a name
    pub async fn get_from_name(
        mut conn: PooledConnection<ConnectionManager<DbConnection>>,
        host: String,
    ) -> Result<Option<Self>, String> {
        actix_web::web::block(move || {
            query(
                host::table
                    .filter(host::name.eq(host))
                    .first::<Self>(&mut conn)
                    .optional(),
            )
        })
        .await
        .map_err(|_| "Blocking error.".to_owned())?
    }

    /// Get a host from an id
    pub async fn get_from_id(
        mut conn: PooledConnection<ConnectionManager<DbConnection>>,
        host_id: i32,
    ) -> Result<Option<Self>, String> {
        actix_web::web::block(move || {
            query(
                host::table
                    .filter(host::id.eq(host_id))
                    .first::<Self>(&mut conn)
                    .optional(),
            )
        })
        .await
        .map_err(|_| "Blocking error.".to_owned())?
    }
    /// Get a host from a name
    pub fn get_from_name_sync(
        conn: &mut DbConnection,
        host: String,
    ) -> Result<Option<Self>, String> {
        query(
            host::table
                .filter(host::name.eq(host))
                .first::<Self>(conn)
                .optional(),
        )
    }

    /// Get a host from an id
    pub fn get_from_id_sync(conn: &mut DbConnection, host: i32) -> Result<Option<Self>, String> {
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

    /// Gets all allowed users allowed on this host, sorted by login
    pub fn get_authorized_keys(
        &self,
        conn: &mut DbConnection,
    ) -> Result<AuthorizedKeysList, String> {
        query(
            user::table
                .inner_join(user_key::table)
                .inner_join(authorization::table)
                .select((
                    PublicUserKey::as_select(),
                    authorization::login,
                    user::username,
                    authorization::options,
                ))
                .filter(authorization::host_id.eq(self.id))
                .order(authorization::login.desc())
                .load::<(PublicUserKey, String, String, Option<String>)>(conn),
        )
        .map(|allowed_list| {
            allowed_list
                .into_iter()
                .map(AllowedUserOnHost::from)
                .collect()
        })
    }

    /// Generate authorized key file for a login on a host. Includes ssm key, if applicable
    pub fn get_authorized_keys_file_for(
        &self,
        ssh_client: &SshClient,
        conn: &mut DbConnection,
        login: &str,
    ) -> Result<String, String> {
        let res: Vec<(PublicUserKey, Option<String>)> = query(
            user::table
                .inner_join(user_key::table)
                .inner_join(authorization::table)
                .select((PublicUserKey::as_select(), authorization::options))
                .filter(authorization::host_id.eq(self.id))
                .filter(authorization::login.eq(login))
                .load::<(PublicUserKey, Option<String>)>(conn),
        )?;

        let estimated_size = (res.len() + 2) * 150;

        Ok(res.into_iter().fold(
            String::with_capacity(estimated_size),
            |buf, (key, options)| {
                buf + options.map_or_else(String::new, |o| o + " ").as_str()
                    + key.to_openssh().as_str()
                    + "\n"
            },
        ) + (if self.username.eq(&login) {
            ssh_client.get_own_key_openssh() + "\n"
        } else {
            String::new()
        })
        .as_str())
    }

    pub fn get_dependant_hosts(&self, conn: &mut DbConnection) -> Result<Vec<String>, String> {
        query(
            host::table
                .filter(host::jump_via.eq(self.id))
                .select(host::name)
                .load::<String>(conn),
        )
    }

    pub fn delete(self, conn: &mut DbConnection) -> Result<usize, String> {
        query(diesel::delete(host::table.filter(host::id.eq(self.id))).execute(conn))
    }

    pub fn delete_authorization(conn: &mut DbConnection, authorization: i32) -> Result<(), String> {
        query_drop(
            diesel::delete(authorization::table.filter(authorization::id.eq(authorization)))
                .execute(conn),
        )
    }

    pub fn update_fingerprint(
        &self,
        conn: &mut DbConnection,
        fingerprint: String,
    ) -> Result<(), String> {
        query_drop(
            diesel::update(host::table)
                .filter(host::id.eq(self.id))
                .set(host::key_fingerprint.eq(fingerprint))
                .execute(conn),
        )
    }
}
