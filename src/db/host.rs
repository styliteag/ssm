use crate::{
    models::{Host, NewHost, NewPublicKey, PublicKey},
    schema::hosts::dsl::*,
    sshclient::{ShortHost, SshPublicKey},
    DbConnection,
};
use diesel::associations::HasTable;
use diesel::dsl::insert_into;
use diesel::prelude::*;
use log::error;

use super::query;

impl Host {
    pub fn to_short(&self) -> ShortHost {
        ShortHost {
            name: self.name.to_owned(),
            addr: format!("{}:{}", self.hostname, self.port),
            user: self.username.to_owned(),
        }
    }

    pub fn get_addr(&self) -> String {
        format!("{}:{}", self.hostname, self.port)
    }
    pub fn add_host(
        conn: &mut DbConnection,
        host: NewHost,
        public_keys: Vec<SshPublicKey>,
    ) -> Result<NewHost, String> {
        use crate::schema::keys::dsl::*;

        let transaction = conn.transaction(|connection| {
            insert_into(hosts)
                .values(host.clone())
                .execute(connection)?;

            let inserted_host_id = hosts
                .filter(name.eq(host.name.clone()))
                .first::<Host>(connection)?
                .id;

            public_keys
                .iter()
                .map(|key| NewPublicKey {
                    key_type: key.key_type.clone(),
                    key_base64: key.key_base64.clone(),
                    comment: key.comment.clone(),
                    host_id: Some(inserted_host_id),
                })
                .try_for_each(|new_key| {
                    insert_into(keys)
                        .values(new_key)
                        .execute(connection)
                        .map(|_| ())
                })
        });
        match transaction {
            Ok(_) => Ok(host),
            Err(e) => Err(e.to_string()),
        }
    }
    pub fn get_host(conn: &mut DbConnection, host: String) -> Option<Host> {
        let db_res = hosts::table().filter(name.eq(host)).first::<Host>(conn);
        let res = query(db_res);
        res.ok()
    }
    pub fn get_all_hosts(conn: &mut DbConnection) -> Vec<Host> {
        let db_res = hosts::table().load::<Host>(conn);
        match db_res {
            Err(e) => {
                error!("{}", e.to_string());
                Vec::new()
            }
            Ok(a) => a,
        }
    }

    pub fn get_hostkeys(&self, conn: &mut DbConnection) -> Result<Vec<SshPublicKey>, String> {
        use crate::schema::keys::dsl::*;

        let hostkeys: Result<Vec<PublicKey>, diesel::result::Error> =
            keys.filter(host_id.eq(self.id)).load::<PublicKey>(conn);
        match hostkeys {
            Ok(k) => Ok(k
                .iter()
                .map(|key| SshPublicKey::from(key.to_owned()))
                .collect()),
            Err(e) => Err(e.to_string()),
        }
    }

    pub fn insert_authorized_keys(
        &self,
        conn: &mut DbConnection,
        authorized_keys: Vec<SshPublicKey>,
    ) -> Result<(), String> {
        use crate::schema::keys::dsl::*;

        let transaction = conn.transaction(|connection| {
            authorized_keys
                .iter()
                .map(|key| NewPublicKey {
                    key_type: key.key_type.to_owned(),
                    key_base64: key.key_base64.to_owned(),
                    comment: key.comment.to_owned(),
                    host_id: Some(self.id),
                })
                .try_for_each(|key| {
                    insert_into(keys::table())
                        .values(key)
                        .execute(connection)
                        .map(|_| ())
                })
        });

        match transaction {
            Ok(_) => Ok(()),
            Err(e) => Err(e.to_string()),
        }
    }
}
