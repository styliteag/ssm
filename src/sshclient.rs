use async_trait::async_trait;
use core::fmt;
use futures::future::BoxFuture;
use futures::AsyncWriteExt;
use futures::FutureExt;
use futures::TryFutureExt;
use log::debug;
use log::error;
use log::warn;
use russh::keys::key::{KeyPair, PublicKey};
use russh::keys::PublicKeyBase64;
use ssh_key::AuthorizedKeys;
use std::io::Cursor;
use std::sync::mpsc;
use std::sync::Arc;
use tokio::io::AsyncRead;

use crate::{
    models::{Host, PublicUserKey},
    ConnectionPool,
};

#[derive(Debug, Clone, serde::Deserialize)]
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

    pub async fn get_authorized_keys(
        self,
        host: Host,
    ) -> Result<Vec<(String, Vec<ssh_key::PublicKey>)>, SshClientError> {
        let handle = self.clone().connect(host).await?;

        let users = self.get_ssh_users(&handle).await?;

        let mut user_vec = Vec::with_capacity(users.len());

        for user in users {
            let keys = self.get_authorized_keys_for(&handle, user.clone()).await?;
            user_vec.push((user, keys));
        }

        Ok(user_vec)
    }

    async fn get_authorized_keys_for(
        &self,
        handle: &russh::client::Handle<SshHandler>,
        user: String,
    ) -> Result<Vec<ssh_key::PublicKey>, SshClientError> {
        let res = self
            .execute_bash(handle, BashCommand::GetAuthorizedKeyfile(user))
            .await??;

        let authorized_keys = AuthorizedKeys::new(res.as_str());
        Ok(authorized_keys
            .filter_map(|e| match e {
                Ok(e) => Some(e.public_key().clone()),
                Err(error) => {
                    error!("Error parsing authorized_keys: {}", error);
                    None
                }
            })
            .collect())
    }

    async fn set_authorized_keys_for(
        &self,
        handle: &russh::client::Handle<SshHandler>,
        user: String,
        authorized_keys: String,
    ) -> Result<String, SshClientError> {
        let res = self
            .execute_bash(
                handle,
                BashCommand::SetAuthorizedKeyfile(user, authorized_keys),
            )
            .await??;
        Ok(res)
    }

    async fn get_ssh_users(
        &self,
        handle: &russh::client::Handle<SshHandler>,
    ) -> Result<Vec<String>, SshClientError> {
        let res = self
            .execute_bash(handle, BashCommand::GetSshUsers)
            .await??;

        Ok(res.lines().map(std::borrow::ToOwned::to_owned).collect())
    }

    pub async fn install_script_on_host(&self, host: i32) -> Result<(), SshClientError> {
        let host = self.get_host_from_id(host).await?;
        let handle = self.clone().connect(host).await?;

        self.install_script(&handle).await
    }

    async fn install_script(
        &self,
        handle: &russh::client::Handle<SshHandler>,
    ) -> Result<(), SshClientError> {
        let script = include_bytes!("./script.sh");

        match self
            .execute_with_data(
                handle,
                &script[..],
                "cat - > .ssh/ssh-keymanager.sh; chmod +x .ssh/ssh-keymanager.sh",
            )
            .await
        {
            Ok((code, _)) => {
                if code != 0 {
                    Err(SshClientError::ExecutionError(String::from(
                        "Failed to install script.",
                    )))
                } else {
                    Ok(())
                }
            }
            Err(error) => Err(error),
        }
    }

    async fn execute_bash(
        &self,
        handle: &russh::client::Handle<SshHandler>,
        command: BashCommand,
    ) -> Result<BashResult, SshClientError> {
        let (exit_code, result) = self
            .execute(handle, BashCommand::Version.to_string().as_str())
            .await?;
        if exit_code != 0 || !result.contains("ssh-key-manager") {
            warn!("Script on host seems to be invalid. Trying to install");
            match self.install_script(handle).await {
                Ok(()) => {
                    debug!("Succesfully installed script")
                }
                Err(error) => {
                    warn!("Failed to install script on host: {}", error);
                    return Err(SshClientError::ExecutionError(String::from(
                        "Script not valid",
                    )));
                }
            };
        }

        let command_str = command.to_string();
        debug!("Executing bash command {}", &command_str);

        let stdin: Option<String> = match command {
            BashCommand::SetAuthorizedKeyfile(_, new_keyfile) => Some(new_keyfile),
            BashCommand::Update(new_script) => Some(new_script),

            BashCommand::GetAuthorizedKeyfile(_)
            | BashCommand::GetSshUsers
            | BashCommand::Version => None,
        };

        let (exit_code, result) = match stdin {
            Some(stdin) => {
                self.execute_with_data(
                    handle,
                    Cursor::new(stdin.into_bytes()),
                    command_str.as_str(),
                )
                .await
            }
            None => self.execute(handle, command_str.as_str()).await,
        }?;

        Ok(match exit_code {
            0 => BashResult::Ok(result),
            _ => BashResult::Err(result),
        })
    }

    async fn execute(
        &self,
        handle: &russh::client::Handle<SshHandler>,
        command: &str,
    ) -> Result<(u32, String), SshClientError> {
        self.execute_with_data(handle, tokio::io::empty(), command)
            .await
    }

    /// Runs a command and returns exit code and std{out/err} merged as a touple
    async fn execute_with_data<R>(
        &self,
        handle: &russh::client::Handle<SshHandler>,
        data: R,
        command: &str,
    ) -> Result<(u32, String), SshClientError>
    where
        R: AsyncRead + Unpin,
    {
        let mut channel = handle.channel_open_session().await?;

        channel.exec(true, command).await?;

        channel.data(data).await?;
        channel.eof().await?;

        let mut exit_code: Option<u32> = None;
        let mut out_buf = Vec::new();

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
                _ => {
                    debug!("Received extra message: {:?}", msg);
                }
            }
        }

        match exit_code {
            Some(code) => {
                let output = String::from_utf8(out_buf).map_err(|e| {
                    SshClientError::ExecutionError(String::from(
                        "Couldn't convert command output to utf-8",
                    ))
                })?;

                Ok((code, output))
            }
            None => Err(SshClientError::ExecutionError(String::from(
                "Program didn't exit cleanly",
            ))),
        }
    }

    /// Check if the host state matches the supposed database state.
    pub async fn get_host_diff(&self, host: Host) -> HostDiff {
        let actual_authorized_keys = self.to_owned().get_authorized_keys(host.clone()).await?;

        //This blocks
        let mut connection = self.conn.get().unwrap();
        let db_authorized_keys = host.get_authorized_keys(&mut connection)?;

        let db_all_keys = PublicUserKey::get_all_keys_with_username(&mut connection)
            .map_err(SshClientError::DatabaseError)?;

        let mut diff_items = Vec::new();

        // TODO: implement with users
        for (_user, keys) in actual_authorized_keys {
            for key in keys {
                let key = match SshPublicKey::try_from(key) {
                    Ok(k) => k,
                    Err(error) => {
                        error!("Error converting keys: {}", error);
                        continue;
                    }
                };
                // TODO: also check if options are set correct
                let is_own_key = key
                    .key_base64
                    .eq(&PublicKeyBase64::public_key_base64(self.key.as_ref()));

                if is_own_key {
                    continue;
                };

                let key_matches = db_authorized_keys
                    .iter()
                    .any(|(db_key, _opts)| key.key_base64.eq(&db_key.key_base64));

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
        }

        Ok(diff_items)
    }
}

pub type HostDiff = Result<Vec<DiffItem>, SshClientError>;

#[derive(Clone)]
pub enum DiffItem {
    /// A key that is authorized is missing with the Username
    KeyMissing(PublicUserKey, String),
    /// A key that is not authorized is present.
    UnknownKey(SshPublicKey),
    /// An unauthorized key belonging to a known user is present.
    UnauthorizedKey(PublicUserKey, String),
    /// There is a duplicate key
    DuplicateKey(SshPublicKey),
}

type User = String;
pub enum BashCommand {
    /// Read the authorized keys for a user
    GetAuthorizedKeyfile(User),

    /// Set authorized keys for a user
    SetAuthorizedKeyfile(User, String),

    /// Get all users that are allowed to login via SSH
    GetSshUsers,

    /// Update the bash script on the server
    Update(String),

    /// Check the script version
    Version,
}

impl std::fmt::Display for BashCommand {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, ".ssh/ssh-keymanager.sh ")?;
        //TODO: some of these should probably be piped in instead of passed as arguments
        match self {
            BashCommand::GetAuthorizedKeyfile(user) => write!(f, "get_authorized_keyfile {user}"),
            BashCommand::SetAuthorizedKeyfile(user, new_keyfile) => {
                write!(f, "set_authorized_keyfile {user} {new_keyfile}")
            }
            BashCommand::GetSshUsers => write!(f, "get_ssh_users"),
            BashCommand::Update(script) => write!(f, "update_script {script}"),
            BashCommand::Version => write!(f, "version"),
        }
    }
}

impl From<BashExecError> for SshClientError {
    fn from(value: BashExecError) -> Self {
        SshClientError::ExecutionError(value)
    }
}

type BashExecError = String;
type BashExecResponse = String;
pub type BashResult = Result<BashExecResponse, BashExecError>;

impl TryFrom<ssh_key::PublicKey> for SshPublicKey {
    type Error = String;

    fn try_from(value: ssh_key::PublicKey) -> Result<Self, Self::Error> {
        let Ok(key) = value.to_openssh() else {
            return Err(String::from("Couldn't convert to openssh"));
        };
        Self::try_from(key.as_str()).map_err(|e| e.to_string())
    }
}
