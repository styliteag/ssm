use async_trait::async_trait;
use core::fmt;
use futures::future::BoxFuture;
use futures::AsyncWriteExt;
use futures::FutureExt;
use log::debug;
use log::error;
use russh::keys::key::{KeyPair, PublicKey};
use std::sync::mpsc;
use std::sync::Arc;

use crate::{
    models::{Host, PublicUserKey},
    ConnectionPool,
};

#[derive(Debug, Clone)]
pub struct SshPublicKey {
    pub key_type: String,
    pub key_base64: String,
    pub comment: Option<String>,
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
        })
    }
}

#[derive(Debug, Clone)]
pub struct SshClient {
    conn: ConnectionPool,
    key: Arc<KeyPair>,
    config: Arc<russh::client::Config>,
}

#[derive(Debug)]
pub enum SshClientError {
    DatabaseError(String),
    SshError(russh::Error),
    ExecutionError(String),
    NoSuchHost,
    PortCastFailed,
}

impl fmt::Display for SshClientError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::DatabaseError(t) | Self::ExecutionError(t) => {
                write!(f, "{t}")
            }
            Self::SshError(e) => write!(f, "{e}"),
            Self::NoSuchHost => write!(f, "The host doesn't exist in the database."),
            Self::PortCastFailed => write!(f, "Couldn't convert an i32 to u32"),
        }
    }
}

impl From<russh::Error> for SshClientError {
    fn from(value: russh::Error) -> Self {
        Self::SshError(value)
    }
}

#[derive(Debug)]
struct SshHandler {
    hostkey_fingerprint: String,
}

#[async_trait]
impl russh::client::Handler for SshHandler {
    type Error = SshClientError;

    async fn check_server_key(
        &mut self,
        server_public_key: &PublicKey,
    ) -> Result<bool, Self::Error> {
        Ok(server_public_key
            .fingerprint()
            .eq(&self.hostkey_fingerprint))
    }
}

enum FirstConnectionState {
    KeySender(mpsc::Sender<String>),
    Hostkey(String),
}
struct SshFirstConnectionHandler {
    state: FirstConnectionState,
}

#[async_trait]
impl russh::client::Handler for SshFirstConnectionHandler {
    type Error = SshClientError;

    async fn check_server_key(
        &mut self,
        server_public_key: &PublicKey,
    ) -> Result<bool, Self::Error> {
        Ok(match &self.state {
            FirstConnectionState::KeySender(tx) => {
                tx.send(server_public_key.fingerprint()).map_err(|_| {
                    SshClientError::ExecutionError(String::from("Failed to send data over mpsc"))
                })?;
                false
            }
            FirstConnectionState::Hostkey(known_fingerprint) => {
                server_public_key.fingerprint().eq(known_fingerprint)
            }
        })
    }
}

#[derive(Debug, Clone)]
pub struct ConnectionDetails {
    pub hostname: String,
    pub port: u32,
}

impl ConnectionDetails {
    pub fn new(hostname: String, port: u32) -> Self {
        Self { hostname, port }
    }
    pub fn new_from_signed(hostname: String, port: i32) -> Result<Self, SshClientError> {
        Ok(Self {
            hostname,
            port: port
                .try_into()
                .map_err(|_| SshClientError::PortCastFailed)?,
        })
    }
    pub fn into_addr(self) -> String {
        format!("{}:{}", self.hostname, self.port)
    }
}

impl SshClient {
    pub fn new(conn: ConnectionPool, key: KeyPair) -> Self {
        Self {
            conn,
            key: Arc::new(key),
            config: Arc::new(russh::client::Config::default()),
        }
    }

    /// Tries to connect to a host and returns hostkeys to validate
    pub async fn get_hostkey(
        &self,
        target: ConnectionDetails,
    ) -> Result<mpsc::Receiver<String>, SshClientError> {
        let (tx, rx) = mpsc::channel();

        let handler = SshFirstConnectionHandler {
            state: FirstConnectionState::KeySender(tx),
        };
        match russh::client::connect(
            Arc::new(russh::client::Config::default()),
            target.into_addr(),
            handler,
        )
        .await
        {
            Ok(_) | Err(SshClientError::SshError(russh::Error::UnknownKey)) => Ok(rx),
            Err(e) => Err(e),
        }
    }

    /// Tries to connect to a host via a jumphost and returns hostkeys to validate
    pub async fn get_hostkey_via(
        &self,
        host: Host,
        target: ConnectionDetails,
    ) -> Result<mpsc::Receiver<String>, SshClientError> {
        let stream = self.connect_via(host, target).await?;

        let (tx, rx) = mpsc::channel();

        let handler = SshFirstConnectionHandler {
            state: FirstConnectionState::KeySender(tx),
        };
        match russh::client::connect_stream(
            Arc::new(russh::client::Config::default()),
            stream,
            handler,
        )
        .await
        {
            Ok(_) | Err(SshClientError::SshError(russh::Error::UnknownKey)) => Ok(rx),
            Err(e) => Err(e),
        }
    }

    pub async fn try_authenticate(
        &self,
        address: ConnectionDetails,
        hostkey: String,
        user: String,
    ) -> Result<(), SshClientError> {
        let handler = SshFirstConnectionHandler {
            state: FirstConnectionState::Hostkey(hostkey),
        };

        let mut handle =
            russh::client::connect(self.config.clone(), address.into_addr(), handler).await?;

        if handle
            .authenticate_publickey(user, self.key.clone())
            .await?
        {
            Ok(())
        } else {
            Err(SshClientError::SshError(russh::Error::NotAuthenticated))
        }
    }

    pub async fn try_authenticate_via(
        &self,
        host: Host,
        address: ConnectionDetails,
        hostkey: String,
        user: String,
    ) -> Result<(), SshClientError> {
        let stream = self.connect_via(host, address).await?;

        let handler = SshFirstConnectionHandler {
            state: FirstConnectionState::Hostkey(hostkey),
        };

        let mut handle =
            russh::client::connect_stream(self.config.clone(), stream, handler).await?;

        if handle
            .authenticate_publickey(user, self.key.clone())
            .await?
        {
            Ok(())
        } else {
            Err(SshClientError::SshError(russh::Error::NotAuthenticated))
        }
    }

    async fn get_host_from_id(&self, host_id: i32) -> Result<Host, SshClientError> {
        // TODO: this is blocking the thread
        Host::get_host_id(&mut self.conn.get().unwrap(), host_id)
            .map_err(SshClientError::DatabaseError)?
            .ok_or(SshClientError::NoSuchHost)
    }

    fn connect(
        self,
        host: Host,
    ) -> BoxFuture<'static, Result<russh::client::Handle<SshHandler>, SshClientError>> {
        let handler = SshHandler {
            hostkey_fingerprint: host.key_fingerprint.clone(),
        };

        async move {
            let mut handle = match host.jump_via {
                Some(via) => {
                    let jump_host = self.get_host_from_id(via).await?;
                    let stream = self.connect_via(jump_host, host.to_connection()?).await?;

                    russh::client::connect_stream(self.config.clone(), stream, handler).await
                }
                None => {
                    russh::client::connect(
                        self.config.clone(),
                        host.to_connection()?.into_addr(),
                        handler,
                    )
                    .await
                }
            }?;

            if !handle
                .authenticate_publickey(host.username.clone(), self.key.clone())
                .await?
            {
                return Err(SshClientError::SshError(russh::Error::NotAuthenticated));
            };

            Ok(handle)
        }
        .boxed()
    }

    async fn connect_via(
        &self,
        via: Host,
        to: ConnectionDetails,
    ) -> Result<russh::ChannelStream<russh::client::Msg>, SshClientError> {
        let jump_handle = self.clone().connect(via).await?;

        debug!("Got handle for jump host targeting {}", to.hostname);

        Ok(jump_handle
            .channel_open_direct_tcpip(to.hostname, to.port, "127.0.0.1", 0)
            .await?
            .into_stream())
    }

    async fn execute(
        &self,
        handle: russh::client::Handle<SshHandler>,
        command: &str,
    ) -> Result<(u32, String), SshClientError> {
        let mut channel = handle.channel_open_session().await?;

        channel.exec(true, command).await?;

        let mut exit_code: Option<u32> = None;
        let mut out_buf = Vec::new();
        // let mut err_buf = Vec::new();

        loop {
            let Some(msg) = channel.wait().await else {
                break;
            };
            match msg {
                russh::ChannelMsg::Data { ref data } => {
                    out_buf
                        .write_all(data)
                        .await
                        .expect("couldnt write to out_buf");
                }
                russh::ChannelMsg::ExitStatus { exit_status } => {
                    exit_code = Some(exit_status);
                }
                _ => {}
            }
        }

        match exit_code {
            Some(code) => {
                if code == 0 {
                    String::from_utf8(out_buf).map_or(
                        Err(SshClientError::ExecutionError(String::from(
                            "Couldn't convert command output to utf-8",
                        ))),
                        |out_str| Ok((code, out_str)),
                    )
                } else {
                    Err(SshClientError::ExecutionError(String::from(
                        "Program didn't exit succesfully",
                    )))
                }
            }
            None => Err(SshClientError::ExecutionError(String::from(
                "Program didn't exit cleanly",
            ))),
        }
    }

    pub async fn get_authorized_keys(
        &self,
        host: Host,
    ) -> Result<Vec<SshPublicKey>, SshClientError> {
        let handle = self.clone().connect(host).await?;

        // TODO: improve this
        let command_str = "cat ~/.ssh/authorized_keys";
        let (_exit_code, output) = self.execute(handle, command_str).await?;

        let authorized_keys: Vec<SshPublicKey> = output
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
    pub async fn get_host_diff(&self, host: Host) -> HostDiff {
        let Ok(actual_authorized_keys) = self.get_authorized_keys(host.clone()).await else {
            return HostDiff {
                host: host.clone(),
                diff: Err(SshClientError::DatabaseError(String::from(
                    "Couldn't get keys for this host from the database",
                ))),
            };
        };

        let mut connection = self.conn.get().unwrap();

        let db_all_keys = match PublicUserKey::get_all_keys_with_username(&mut connection) {
            Ok(keys) => keys,
            Err(e) => {
                return HostDiff {
                    host: host.clone(),
                    diff: Err(SshClientError::DatabaseError(e)),
                }
            }
        };

        let db_authorized_keys: Vec<(String, Option<String>)> =
            match host.get_authorized_keys(&mut connection) {
                Ok(keys) => keys
                    .into_iter()
                    .map(|(key, options)| (key.key_base64, options))
                    .collect(),
                Err(e) => {
                    return HostDiff {
                        host: host.clone(),
                        diff: Err(SshClientError::DatabaseError(e)),
                    }
                }
            };

        let mut diff_items = Vec::new();

        for key in actual_authorized_keys {
            // TODO: also check if options are set correct

            let key_matches = db_authorized_keys
                .iter()
                .any(|(db_key, _opts)| key.key_base64.eq(db_key));

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

        HostDiff {
            host: host.clone(),
            diff: Ok(diff_items),
        }
    }
}

// #[derive(Clone)]
pub struct HostDiff {
    pub host: Host,
    pub diff: Result<Vec<DiffItem>, SshClientError>,
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
