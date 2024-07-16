use crate::{
    models::{Host, NewHost, NewPublicKey, PublicKey},
    schema::hosts::dsl::*,
    sshclient::{ShortHost, SshPublicKey},
    DbConnection,
};
use diesel::associations::HasTable;
use diesel::dsl::insert_into;
use diesel::prelude::*;

use super::query;

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
    pub fn add_host(
        conn: &mut DbConnection,
        host: NewHost,
        host_keys: &[SshPublicKey],
    ) -> Result<NewHost, String> {
        use crate::schema::keys::dsl::*;

        let transaction = query(conn.transaction(|connection| {
            insert_into(hosts)
                .values(host.clone())
                .execute(connection)?;

            let inserted_host_id = hosts
                .filter(name.eq(host.name.clone()))
                .first::<Self>(connection)?
                .id;

            host_keys
                .iter()
                .map(|key| NewPublicKey {
                    key_type: key.key_type.clone(),
                    key_base64: key.key_base64.clone(),
                    comment: key.comment.clone(),
                    host_id: Some(inserted_host_id),
                    user_id: None,
                })
                .try_for_each(|new_key| {
                    insert_into(keys)
                        .values(new_key)
                        .execute(connection)
                        .map(|_| ())
                })
        }));
        transaction.map(|_| host)
    }
    pub fn get_host(conn: &mut DbConnection, host: String) -> Result<Option<Self>, String> {
        query(
            hosts::table()
                .filter(name.eq(host))
                .first::<Self>(conn)
                .optional(),
        )
    }
    pub fn get_all_hosts(conn: &mut DbConnection) -> Result<Vec<Self>, String> {
        query(hosts::table().load::<Self>(conn))
    }

    pub fn get_hostkeys(&self, conn: &mut DbConnection) -> Result<Vec<SshPublicKey>, String> {
        use crate::schema::keys::dsl::*;

        let hostkeys: Result<Vec<PublicKey>, String> =
            query(keys.filter(host_id.eq(self.id)).load::<PublicKey>(conn));

        hostkeys.map(|hostkeys| hostkeys.iter().map(SshPublicKey::from).collect())
    }

    pub fn insert_authorized_keys(
        &self,
        conn: &mut DbConnection,
        authorized_keys: &[SshPublicKey],
    ) -> Result<(), String> {
        use crate::schema::keys::dsl::*;

        let transaction = conn.transaction(|connection| {
            authorized_keys
                .iter()
                .map(|key| NewPublicKey {
                    key_type: key.key_type.clone(),
                    key_base64: key.key_base64.clone(),
                    comment: key.comment.clone(),
                    host_id: None,
                    user_id: None,
                })
                .try_for_each(|key| {
                    insert_into(keys::table())
                        .values(key)
                        .execute(connection)
                        .map(|_| ())
                })
        });

        query(transaction)
    }
}
