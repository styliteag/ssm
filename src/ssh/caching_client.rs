use std::collections::HashMap;

use actix_web::web;
use diesel::r2d2::{ConnectionManager, PooledConnection};
use time::OffsetDateTime;
use tokio::sync::RwLock;

use crate::{
    models::{Host, PublicUserKey},
    ConnectionPool, DbConnection,
};

use super::{
    sshclient::SshClientError, AuthorizedKeyEntry, Cache, CacheValue, DiffItem, HostDiff, HostName,
    Login, SshClient,
};

#[derive(Debug)]
pub struct CachingSshClient {
    conn: ConnectionPool,
    ssh_client: SshClient,
    cache: RwLock<Cache>,
}

impl CachingSshClient {
    pub fn new(conn: ConnectionPool, ssh_client: SshClient) -> Self {
        Self {
            conn,
            ssh_client,
            cache: RwLock::new(HashMap::new()),
        }
    }

    async fn get_entry(&self, host_name: &String) -> Result<CacheValue, SshClientError> {
        let cache = self.cache.read().await;

        if let Some(cached) = cache.get(host_name) {
            Ok(cached.clone())
        } else {
            drop(cache);
            let host_name2 = host_name.clone();
            let mut conn = self.conn.get().unwrap();

            let res = match web::block(move || Host::get_host_name(&mut conn, host_name2)).await? {
                Err(e) => Err(SshClientError::DatabaseError(e)),
                Ok(Some(host)) => self.ssh_client.clone().get_authorized_keys(host).await,
                Ok(None) => Err(SshClientError::NoSuchHost),
            };

            let mut lock = self.cache.write().await;
            lock.insert(host_name.clone(), (OffsetDateTime::now_utc(), res));
            Ok(lock.get(host_name).expect("We just inserted this").clone())
        }
    }
    pub async fn get_authorized_keys(
        &self,
        host_name: HostName,
    ) -> Result<CacheValue, SshClientError> {
        self.get_entry(&host_name).await
    }

    fn calculate_diff(
        &self,
        mut conn: PooledConnection<ConnectionManager<DbConnection>>,
        host_entries: Vec<(Login, bool, Vec<AuthorizedKeyEntry>)>,
        host: &Host,
    ) -> Result<Vec<(Login, Vec<DiffItem>)>, SshClientError> {
        let db_authorized_entries = host.get_authorized_keys(&mut conn)?;

        let mut conn = self.conn.get().unwrap();
        let all_user_keys = PublicUserKey::get_all_keys_with_username(&mut conn)?;

        let own_key_base64 = self.ssh_client.get_own_key_b64();

        let mut diff_items = Vec::new();
        let mut used_indecies = Vec::new();

        for (login, has_pragma, host_entries) in host_entries {
            let mut this_user_diff = Vec::new();
            if !has_pragma {
                this_user_diff.push(DiffItem::PragmaMissing);
            }

            'entries: for host_entry in host_entries {
                let host_entry = match host_entry {
                    Ok(k) => k,
                    Err((error, line)) => {
                        this_user_diff.push(DiffItem::FaultyKey(error, line));
                        continue 'entries;
                    }
                };
                // Check if this is the key-manager key
                if host_entry.base64.eq(&own_key_base64) {
                    // TODO: also check if options are set correct
                    continue 'entries;
                }

                for (i, db_entry) in db_authorized_entries.iter().enumerate() {
                    if host_entry.base64.eq(&db_entry.key.key_base64) && login.eq(&db_entry.login) {
                        // TODO: check options
                        if used_indecies.contains(&i) {
                            this_user_diff.push(DiffItem::DuplicateKey(host_entry));
                        } else {
                            used_indecies.push(i);
                        }
                        continue 'entries;
                    }
                }

                for (username, key) in &all_user_keys {
                    if host_entry.base64.eq(&key.key_base64) {
                        this_user_diff
                            .push(DiffItem::UnauthorizedKey(host_entry, username.clone()));
                        continue 'entries;
                    }
                }
                this_user_diff.push(DiffItem::UnknownKey(host_entry));
                continue 'entries;
            }

            for (i, unused_entry) in db_authorized_entries.iter().enumerate() {
                if !used_indecies.contains(&i) && unused_entry.login.eq(&login) {
                    this_user_diff.push(DiffItem::KeyMissing(
                        unused_entry.clone().into(),
                        unused_entry.username.clone(),
                    ));
                }
            }
            diff_items.push((login, this_user_diff));
        }
        diff_items.retain(|(_, user_diff)| !user_diff.is_empty());
        Ok(diff_items)
    }

    /// Get the difference between the supposed and actual state of the authorized keys
    pub async fn get_host_diff(&self, host: Host) -> HostDiff {
        let (inserted, cached_authorized_keys) =
            match self.get_authorized_keys(host.name.clone()).await {
                Ok(t) => t,
                Err(e) => {
                    return (OffsetDateTime::now_utc(), Err(e));
                }
            };

        let host_authorized_entries = match cached_authorized_keys {
            Ok(authorized_entries) => authorized_entries,
            Err(e) => {
                return (inserted, Err(e));
            }
        };

        let conn = self.conn.get().unwrap();

        (
            inserted,
            self.calculate_diff(conn, host_authorized_entries, &host),
        )
    }

    pub async fn get_logins(&self, host: Host) -> Result<Vec<Login>, SshClientError> {
        let logins = self.get_entry(&host.name).await?.1;

        logins.map(|logins| logins.into_iter().map(|(login, _, _)| login).collect())
    }
}
