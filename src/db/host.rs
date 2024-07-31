use crate::schema::user_in_host;
use crate::schema::user_keys;
use crate::schema::users;
use crate::{
    models::{Host, HostKey, NewHost, NewHostKey, PublicUserKey},
    schema::hosts,
    sshclient::{ShortHost, SshPublicKey},
    DbConnection,
};
use diesel::dsl::insert_into;
use diesel::prelude::*;

use super::query;
use super::query_drop;
use super::UserAndOptions;
use super::UserkeyAndOptions;

impl Host {
    pub fn to_short(&self) -> ShortHost {
        ShortHost {
            name: self.name.clone(),
            addr: format!("{}:{}", self.hostname, self.port),
            user: self.username.clone(),
        }
    }

    pub fn get_addr(&self) -> String {
        format!("{}:{}", self.hostname, self.port)
    }
    /// Adds a new host with corresponding hostkeys to the database
    pub fn add_host(
        conn: &mut DbConnection,
        host: NewHost,
        new_host_keys: &[SshPublicKey],
    ) -> Result<Host, String> {
        use crate::schema::host_keys::dsl::*;

        let mut inserted_host_id = -1;

        let transaction = query(conn.transaction(|connection| {
            insert_into(hosts::table)
                .values(host.clone())
                .execute(connection)?;

            inserted_host_id = hosts::table
                .filter(hosts::name.eq(host.name.clone()))
                .first::<Self>(connection)?
                .id;

            new_host_keys
                .iter()
                .map(|key| NewHostKey {
                    key_type: key.key_type.clone(),
                    key_base64: key.key_base64.clone(),
                    comment: key.comment.clone(),
                    host_id: inserted_host_id,
                })
                .try_for_each(|new_key| {
                    insert_into(host_keys)
                        .values(new_key)
                        .execute(connection)
                        .map(|_| ())
                })
        }));
        transaction.map(|_| Host {
            id: inserted_host_id,
            name: host.name,
            username: host.username,
            hostname: host.hostname,
            port: host.port,
        })
    }

    pub fn authorize_user(
        conn: &mut DbConnection,
        host_id: i32,
        user_id: i32,
        options: Option<String>,
    ) -> Result<(), String> {
        query_drop(
            insert_into(user_in_host::table)
                .values((
                    user_in_host::host_id.eq(host_id),
                    user_in_host::user_id.eq(user_id),
                    user_in_host::options.eq(options),
                ))
                .execute(conn),
        )
    }

    pub fn get_authorzed_user_ids(&self, conn: &mut DbConnection) -> Result<Vec<i32>, String> {
        query(
            users::table
                .inner_join(user_in_host::table.inner_join(hosts::table))
                .select(user_in_host::user_id)
                .load::<i32>(conn),
        )
    }

    /// Get authorized Users and associated options
    pub fn get_authorized_users(
        &self,
        conn: &mut DbConnection,
    ) -> Result<Vec<UserAndOptions>, String> {
        let user_ids = self.get_authorzed_user_ids(conn)?;

        query(
            user_in_host::table
                .inner_join(users::table)
                .select((users::username, user_in_host::options))
                .filter(
                    user_in_host::host_id
                        .eq(self.id)
                        .and(users::id.eq_any(user_ids)),
                )
                .load::<UserAndOptions>(conn),
        )
    }

    pub fn get_host(conn: &mut DbConnection, host: String) -> Result<Option<Self>, String> {
        query(
            hosts::table
                .filter(hosts::name.eq(host))
                .first::<Self>(conn)
                .optional(),
        )
    }
    pub fn get_all_hosts(conn: &mut DbConnection) -> Result<Vec<Self>, String> {
        query(hosts::table.load::<Self>(conn))
    }

    pub fn get_hostkeys(&self, conn: &mut DbConnection) -> Result<Vec<HostKey>, String> {
        use crate::schema::host_keys::dsl::*;

        query(host_keys.filter(host_id.eq(self.id)).load::<HostKey>(conn))

        // hostkeys.map(|hostkeys| hostkeys.iter().map(SshPublicKey::from).collect())
    }

    /// Gets all keys that allowed on this server and the associated options
    pub fn get_authorized_keys(
        &self,
        conn: &mut DbConnection,
    ) -> Result<Vec<UserkeyAndOptions>, String> {
        query(
            users::table
                .inner_join(user_keys::table)
                .inner_join(user_in_host::table)
                .select((PublicUserKey::as_select(), user_in_host::options))
                .filter(user_in_host::host_id.eq(self.id))
                .load::<UserkeyAndOptions>(conn),
        )
    }
}
