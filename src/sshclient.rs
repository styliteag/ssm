use core::fmt;

use async_ssh2_tokio::{AuthMethod, Client, ServerCheckMethod};
use log::{error, info, warn};
use serde::Deserialize;

use crate::{
    models::{Host, PublicUserKey},
    ConnectionPool,
};

#[derive(Debug, Clone)]
pub enum KeyOwner {
    Host(i32),
    User(i32),
    None,
}

#[derive(Debug, Clone)]
pub struct SshPublicKey {
    pub key_type: String,
    pub key_base64: String,
    pub comment: Option<String>,
    /// Owner of the key. Either a Server or a user
    pub owner: KeyOwner,
}

#[derive(Debug)]
pub enum KeyParseError {
    Malformed,
}

impl std::fmt::Display for KeyParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Failed to parse publickey")
    }
}

impl std::fmt::Display for SshPublicKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self.comment.clone() {
            Some(c) => write!(
                f,
                "Type: {}; Comment: {}; Base64: {}",
                self.key_type, c, self.key_base64
            ),
            None => write!(f, "Type: {}; Base64: {}", self.key_type, self.key_base64),
        }
    }
}

impl TryFrom<String> for SshPublicKey {
    type Error = KeyParseError;
    fn try_from(value: String) -> Result<Self, KeyParseError> {
        SshPublicKey::try_from(value.as_str())
    }
}

impl From<PublicUserKey> for SshPublicKey {
    fn from(value: PublicUserKey) -> Self {
        SshPublicKey {
            key_type: value.key_type,
            key_base64: value.key_base64,
            comment: value.comment,
            owner: KeyOwner::User(value.user_id),
        }
    }
}

impl From<&PublicUserKey> for SshPublicKey {
    fn from(value: &PublicUserKey) -> Self {
        SshPublicKey::from(value.to_owned())
    }
}

impl SshPublicKey {
    pub fn from_lines(lines: &str) -> Vec<Self> {
        lines
            .lines()
            .filter(|line| !line.starts_with('#'))
            .filter_map(|line| match Self::try_from(line) {
                Ok(key) => Some(key),
                Err(e) => {
                    error!("{}", e);
                    None
                }
            })
            .collect()
    }
}

impl TryFrom<&str> for SshPublicKey {
    type Error = KeyParseError;
    fn try_from(key_string: &str) -> Result<Self, KeyParseError> {
        // TODO: write a better parser (nom)
        let mut parts = key_string.splitn(3, ' ');

        let key_type_str = parts.next().ok_or(KeyParseError::Malformed)?;

        Ok(SshPublicKey {
            key_type: key_type_str.to_owned(),
            key_base64: parts.next().ok_or(KeyParseError::Malformed)?.to_owned(),
            comment: parts.next().map(String::from),
            owner: KeyOwner::None,
        })
    }
}

#[derive(Deserialize, Clone, Debug)]
pub struct ShortHost {
    pub name: String,
    pub addr: String,
    pub user: String,
}

#[derive(Clone)]
pub struct SshClient {
    auth: AuthMethod,
    conn: ConnectionPool,
}

#[derive(Debug)]
pub enum SshClientError {
    DatabaseError(String),
    SshError(String),
    ExecutionError(String),
    NoSuchHost,
}

impl fmt::Display for SshClientError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::DatabaseError(t) | Self::SshError(t) | Self::ExecutionError(t) => {
                write!(f, "{t}")
            }
            Self::NoSuchHost => write!(f, "The host doesn't exist in the database."),
        }
    }
}

fn to_connection_err(error: async_ssh2_tokio::Error) -> SshClientError {
    SshClientError::SshError(error.to_string())
}

impl SshClient {
    pub fn new(conn: ConnectionPool, auth: AuthMethod) -> Self {
        Self { auth, conn }
    }

    pub async fn run_command(client: &Client, command: &str) -> Result<String, SshClientError> {
        match client.execute(command).await {
            Err(e) => Err(SshClientError::ExecutionError(e.to_string())),
            Ok(result) => {
                if result.exit_status != 0 {
                    return Err(SshClientError::ExecutionError(format!(
                        "Command exited with code {}",
                        result.exit_status
                    )));
                }

                Ok(result.stdout)
            }
        }
    }

    pub async fn connect(
        &self,
        addr: String,
        username: &str,
        host_key: ServerCheckMethod,
    ) -> Result<Client, async_ssh2_tokio::Error> {
        info!(
            "Trying to connect to '{}' with host_key '{:?}'",
            addr, host_key
        );
        Client::connect(addr, username, self.auth.clone(), host_key).await
    }

    pub async fn try_connect(&self, host: &Host) -> Result<Client, SshClientError> {
        let Ok(host_keys) = host.get_hostkeys(&mut self.conn.get().unwrap()) else {
            return Err(SshClientError::DatabaseError(String::from(
                "Failed to query host key from database.",
            )));
        };
        for key in host_keys {
            match self
                .connect(
                    host.get_addr(),
                    host.username.as_str(),
                    ServerCheckMethod::PublicKey(key.key_base64),
                )
                .await
            {
                Ok(conn) => return Ok(conn),
                Err(e) => {
                    warn!("Couldn't connect to host {}", e.to_string());
                }
            };
        }
        Err(SshClientError::SshError(String::from(
            "Didn't find a matching host key",
        )))
    }

    pub async fn try_disconnect(client: Client) {
        client.disconnect().await.map_err(|e| {
            error!("Error trying to disconnect client: {}", e.to_string());
        });
    }

    pub async fn get_hostkeys(&self, client: &Client) -> Result<Vec<SshPublicKey>, SshClientError> {
        let keys = Self::run_command(client, "cat /etc/ssh/ssh_host_*_key.pub").await?;

        Ok(SshPublicKey::from_lines(&keys))
    }
    pub async fn get_authorized_keys(
        &self,
        client: &Client,
        host: &Host,
    ) -> Result<Vec<SshPublicKey>, SshClientError> {
        // TODO: improve this
        let command_str = "cat ~/.ssh/authorized_keys";
        let command = client
            .execute(command_str)
            .await
            .map_err(to_connection_err)?;
        info!(
            "Host {}: Executed command {} with error code {}",
            host.name, command_str, command.exit_status
        );

        if command.exit_status != 0 {
            return Err(SshClientError::SshError(String::from(
                "Command exited with non-zero exit code",
            )));
        }

        let authorized_keys: Vec<SshPublicKey> = command
            .stdout
            .lines()
            .filter_map(|auth_line| {
                if auth_line.starts_with('#') {
                    return None;
                }

                SshPublicKey::try_from(auth_line).ok()
            })
            .collect();
        Ok(authorized_keys)
    }

    /// Check if the host state matches the supposed database state.
    pub async fn get_host_diff(&self, host: &Host) -> Result<HostDiff, SshClientError> {
        let Ok(client) = self.try_connect(host).await else {
            return Err(SshClientError::SshError(String::from(
                "Couldn't connect to host",
            )));
        };

        let Ok(actual_authorized_keys) = self.get_authorized_keys(&client, host).await else {
            return Err(SshClientError::DatabaseError(String::from(
                "Couldn't get keys for this host from the database",
            )));
        };

        Self::try_disconnect(client);

        let mut connection = self.conn.get().unwrap();

        let db_all_keys = PublicUserKey::get_all_keys_with_username(&mut connection)
            .map_err(SshClientError::DatabaseError)?;

        let db_authorized_keys: Vec<(String, Option<String>)> = host
            .get_authorized_keys(&mut connection)
            .map_err(SshClientError::DatabaseError)?
            .iter()
            .map(|(key, options)| (key.key_base64.clone(), options.to_owned()))
            .collect();

        let mut diff_items = Vec::new();

        for key in actual_authorized_keys {
            // TODO: also check if options are set correct

            let key_matches = db_authorized_keys
                .iter()
                .any(|(db_key, opts)| key.key_base64.eq(db_key));

            if !key_matches {
                let known_key = db_all_keys
                    .iter()
                    .find(|(_, user_key)| key.key_base64.eq(&user_key.key_base64));
                match known_key {
                    Some((username, user_key)) => {
                        diff_items.push(DiffItem::UnauthorizedKey(
                            user_key.clone(),
                            username.clone(),
                        ));
                    }
                    None => {
                        diff_items.push(DiffItem::UnknownKey(key));
                    }
                }
            }
        }

        Ok(HostDiff {
            host: host.to_owned(),
            diff: diff_items,
        })
    }
}

#[derive(Clone)]
pub struct HostDiff {
    pub host: Host,
    pub diff: Vec<DiffItem>,
}

#[derive(Clone)]
pub enum DiffItem {
    /// A key that is authorized is missing with the Username
    KeyMissing(PublicUserKey, String),
    /// A key that is not authorized is present.
    UnknownKey(SshPublicKey),
    /// An unauthorized key belonging to a known user is present.
    UnauthorizedKey(PublicUserKey, String),
}
