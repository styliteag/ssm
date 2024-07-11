use core::fmt;

use async_ssh2_tokio::{AuthMethod, Client, ServerCheckMethod};
use log::{error, info, warn};
use serde::Deserialize;

use crate::{
    models::{Host, PublicKey},
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
        match self.comment.to_owned() {
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

impl From<PublicKey> for SshPublicKey {
    fn from(value: PublicKey) -> Self {
        SshPublicKey {
            key_type: value.key_type,
            key_base64: value.key_base64,
            comment: value.comment,
            owner: match value.user_id {
                Some(user) => KeyOwner::User(user),
                None => match value.host_id {
                    Some(host_id) => KeyOwner::Host(host_id),
                    None => KeyOwner::None,
                },
            },
        }
    }
}

impl SshPublicKey {
    pub fn from_lines(lines: String) -> Vec<SshPublicKey> {
        lines
            .lines()
            .filter(|line| !line.starts_with('#'))
            .filter_map(|line| match SshPublicKey::try_from(line) {
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
            key_base64: parts.next().ok_or(KeyParseError::Malformed)?.to_string(),
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
            Self::DatabaseError(t) => write!(f, "{}", t),
            Self::SshError(t) => write!(f, "{}", t),
            Self::ExecutionError(t) => write!(f, "{}", t),
            Self::NoSuchHost => write!(f, "The host doesn't exist in the database."),
        }
    }
}

fn to_connection_err(error: async_ssh2_tokio::Error) -> SshClientError {
    SshClientError::SshError(error.to_string())
}

impl SshClient {
    pub fn new(conn: ConnectionPool, auth: AuthMethod) -> Self {
        SshClient { auth, conn }
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
            return Err(SshClientError::DatabaseError(
                "Failed to query host key from database.".to_owned(),
            ));
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
    pub async fn get_hostkeys(&self, client: &Client) -> Result<Vec<SshPublicKey>, SshClientError> {
        let keys = Self::run_command(client, "cat /etc/ssh/ssh_host_*_key.pub").await?;

        Ok(SshPublicKey::from_lines(keys))
    }
    pub async fn get_authorized_keys(
        &self,
        host: ShortHost,
    ) -> Result<Vec<SshPublicKey>, SshClientError> {
        let maybe_host = Host::get_host(&mut self.conn.get().unwrap(), host.name.clone());
        let Some(db_host) = maybe_host else {
            return Err(SshClientError::NoSuchHost);
        };

        let client = self.try_connect(&db_host).await?;

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

        client.disconnect();

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
        match db_host.insert_authorized_keys(&mut self.conn.get().unwrap(), authorized_keys.clone())
        {
            Ok(_) => {}
            Err(e) => {
                error!("{}", e.to_string())
            }
        };
        Ok(authorized_keys)
    }
    pub async fn add_key(host: String, public_key: SshPublicKey) -> Result<(), SshClientError> {
        todo!()
    }
    pub async fn remove_key(
        host: String,
        key_base64: String,
    ) -> Result<SshPublicKey, SshClientError> {
        todo!()
    }
}

// pub fn get_authorized_keys(host: String) -> Result<Vec<SshPublicKey>, SshClientError> {
//     let tcp = TcpStream::connect(host).unwrap();
//     let mut sess = Session::new().unwrap();
//     sess.set_tcp_stream(tcp);
//     sess.handshake().unwrap();

//     if sess.userauth_agent("root").is_err() {
//         return Err(SshClientError::FailedAuth);
//     }

//     let mut channel = sess.channel_session().unwrap();
//     channel.exec("cat ~/.ssh/authorized_keys").unwrap();
//     let mut s = String::new();
//     channel.read_to_string(&mut s).unwrap();

//     if channel.wait_close().is_err() {
//         return Err(SshClientError::FailedExec);
//     }

//     let keys = s.lines().map(|key| key.try_into().unwrap()).collect();

//     match channel.exit_status() {
//         Err(e) => Err(SshClientError::FailedGetExitCode),
//         Ok(exit_code) => match exit_code {
//             0 => Ok(keys),
//             _ => Err(SshClientError::FailedExec),
//         },
//     }
// }

// pub fn list_agent_keys() -> Result<String, ()> {
//     // Almost all APIs require a `Session` to be available
//     let sess = Session::new().unwrap();
//     let mut agent = sess.agent().unwrap();

//     // Connect the agent and request a list of identities
//     agent.connect().unwrap();
//     agent.list_identities().unwrap();

//     Ok(agent
//         .identities()
//         .unwrap()
//         .iter()
//         .map(|identity| {
//             String::from(format!(
//                 "Comment: {}, Key: {:?}",
//                 identity.comment(),
//                 identity.blob()
//             ))
//         })
//         .collect())
// }
