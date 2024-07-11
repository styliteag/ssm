use async_ssh2_tokio::ServerCheckMethod;
use diesel::associations::HasTable;
use diesel::dsl::insert_into;
use diesel::prelude::*;
use diesel::result::Error;
use diesel::{QueryDsl, RunQueryDsl, SelectableHelper};
use log::error;

use crate::{models::*, DbConnection};

use crate::schema::hosts::dsl::*;
use crate::schema::keys::dsl::*;
use crate::schema::users::dsl::*;
use crate::sshclient::{ShortHost, SshPublicKey};

fn query<T>(query_result: Result<T, Error>) -> Result<T, String> {
    query_result.map_err(|e| {
        let error = e.to_string();
        error!("Error trying to execute sql query: {}", error);
        error
    })
}

impl Host {
    pub fn to_short(&self) -> ShortHost {
        ShortHost {
            name: self.name.to_owned(),
            addr: format!("{}:{}", self.hostname, self.port),
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

impl PublicKey {
    pub fn get_all_keys(conn: &mut DbConnection) -> Vec<PublicKey> {
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
        PublicKey::get_all_keys(conn)
            .iter()
            .map(|key| T::from(key.to_owned()))
            .collect()
    }
}
