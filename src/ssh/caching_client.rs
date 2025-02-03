use std::collections::HashMap;

use diesel::r2d2::{ConnectionManager, PooledConnection};
use time::OffsetDateTime;
use tokio::sync::RwLock;

use crate::{
    models::{Host, PublicUserKey},
    ConnectionPool, DbConnection,
};

use super::{
    sshclient::SshClientError, AuthorizedKeyEntry, Cache, CacheValue, DiffItem, HostDiff, HostName,
    Login, SshClient, SshKeyfiles,
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

    /// Removes a cache entry entirely. This should only be used when the underlying host no longer exists.
    pub async fn remove(&self, host_name: &str) {
        let mut lock = self.cache.write().await;
        let _ = lock.remove(host_name);
    }

    async fn get_current_host_data(&self, host_name: &str) -> Result<SshKeyfiles, SshClientError> {
        let conn = self.conn.get().unwrap();

        match Host::get_from_name(conn, host_name.to_owned()).await? {
            Some(host) => self.ssh_client.clone().get_authorized_keys(host).await,
            None => Err(SshClientError::NoSuchHost),
        }
    }

    async fn get_entry(
        &self,
        host_name: &String,
        force_update: bool,
    ) -> Result<CacheValue, SshClientError> {
        if !force_update {
            let cache = self.cache.read().await;
            if let Some(cached) = cache.get(host_name) {
                return Ok(cached.clone());
            }
        }

        let data = self.get_current_host_data(host_name).await;
        let time = OffsetDateTime::now_utc();

        let mut lock = self.cache.write().await;
        lock.insert(host_name.clone(), (time, data));
        Ok(lock.get(host_name).expect("We just inserted this").clone())
    }

    fn calculate_diff(
        &self,
        mut conn: PooledConnection<ConnectionManager<DbConnection>>,
        host_entries: SshKeyfiles,
        host: &Host,
    ) -> Result<Vec<(Login, Vec<DiffItem>)>, SshClientError> {
        let db_authorized_entries = host.get_authorized_keys(&mut conn)?;

        let mut conn = self.conn.get().unwrap();
        let all_user_keys = PublicUserKey::get_all_keys_with_username(&mut conn)?;

        let own_key_base64 = self.ssh_client.get_own_key_b64();

        let mut diff_items = Vec::new();
        let mut used_indecies = Vec::new();

        for entry in host_entries {
            let mut this_user_diff = Vec::new();
            if !entry.has_pragma {
                this_user_diff.push(DiffItem::PragmaMissing);
            }

            'entries: for host_entry in entry.keyfile {
                let host_entry = match host_entry {
                    AuthorizedKeyEntry::Authorization(k) => k,
                    AuthorizedKeyEntry::Error(error, line) => {
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
                    if host_entry.base64.eq(&db_entry.key.key_base64)
                        && entry.login.eq(&db_entry.login)
                    {
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
                if !used_indecies.contains(&i) && unused_entry.login.eq(&entry.login) {
                    this_user_diff.push(DiffItem::KeyMissing(
                        unused_entry.clone().into(),
                        unused_entry.username.clone(),
                    ));
                }
            }
            diff_items.push((entry.login, this_user_diff));
        }
        diff_items.retain(|(_, user_diff)| !user_diff.is_empty());
        Ok(diff_items)
    }

    /// Get the difference between the supposed and actual state of the authorized keys
    pub async fn get_host_diff(&self, host: Host, force_update: bool) -> HostDiff {
        let (inserted, cached_authorized_keys) =
            match self.get_entry(&host.name, force_update).await {
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

    /// Gets the current state of all known hosts, forcing an update
    pub async fn get_current_state(&self) -> Result<Vec<(HostName, HostDiff)>, String> {
        let hosts = Host::get_all_hosts(&mut self.conn.get().unwrap())?;

        let mut state = Vec::with_capacity(hosts.len());

        for host in hosts.into_iter() {
            let hostname = host.name.to_owned();
            let res = self.get_host_diff(host, true).await;
            state.push((hostname, res));
        }

        Ok(state)
    }

    pub async fn get_logins(
        &self,
        host: Host,
        force_update: bool,
    ) -> Result<Vec<Login>, SshClientError> {
        let logins = self.get_entry(&host.name, force_update).await?.1;

        logins.map(|logins| logins.into_iter().map(|response| response.login).collect())
    }
}
