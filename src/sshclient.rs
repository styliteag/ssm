use async_trait::async_trait;
use core::fmt;
use futures::future::BoxFuture;
use futures::AsyncWriteExt;
use futures::FutureExt;
use log::debug;
use log::info;
use log::warn;
use russh::keys::key::{KeyPair, PublicKey};
use russh::keys::PublicKeyBase64;
use ssh_encoding::Base64Writer;
use ssh_encoding::Encode;
use ssh_key::authorized_keys::ConfigOpts;
use ssh_key::authorized_keys::Entry;
use ssh_key::Algorithm;
use std::io::Cursor;
use std::str::FromStr;
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

/// Parser error
type ErrorMsg = String;
/// The entire line containing the Error
type Line = String;
pub type AuthorizedKeyEntry = Result<AuthorizedKey, (ErrorMsg, Line)>;

#[derive(Debug, Clone)]
pub struct AuthorizedKey {
    pub options: ConfigOpts,
    pub algorithm: Algorithm,
    pub base64: String,
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

    pub fn get_own_key_openssh(&self) -> String {
        let b64 = self.key.public_key_base64();
        let algo = self.key.name();
        format!("{algo} {b64} ssm")
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
    async fn get_host_from_name(&self, host_name: String) -> Result<Host, SshClientError> {
        // TODO: this is blocking the thread
        Host::get_host_name(&mut self.conn.get().unwrap(), host_name)
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
    ) -> Result<Vec<(String, bool, Vec<AuthorizedKeyEntry>)>, SshClientError> {
        let handle = self.clone().connect(host).await?;

        let users = self.get_ssh_users(&handle).await?;

        let mut user_vec = Vec::with_capacity(users.len());

        for user in users {
            info!("Loading authorized keys for user: {user}");
            let (has_pragma, keys) = self.get_authorized_keys_for(&handle, user.clone()).await?;
            // info!("Loaded Entries: {:?}", keys);
            user_vec.push((user, has_pragma, keys));
        }

        Ok(user_vec)
    }

    async fn get_authorized_keys_for(
        &self,
        handle: &russh::client::Handle<SshHandler>,
        user: String,
    ) -> Result<(bool, Vec<AuthorizedKeyEntry>), SshClientError> {
        let res = self
            .execute_bash(handle, BashCommand::GetAuthorizedKeyfile(user))
            .await??;

        let mut iter = res.trim().lines().peekable();
        let has_pragma = iter
            .peek()
            .map(|first| {
                "# Auto-generated by Secure SSH Manager. DO NOT EDIT!"
                    .to_owned()
                    .eq(first)
            })
            .unwrap_or(false);
        Ok((
            has_pragma,
            iter.filter(|line| !line.trim_start().starts_with('#'))
                .map(|line| {
                    Entry::from_str(line)
                        .map_err(|e| (e.to_string(), line.to_owned()))
                        .map(|key| {
                            //TODO: algorithm to estimate size
                            let mut buf = vec![0u8; 1024];
                            let mut writer = Base64Writer::new(&mut buf).expect("buf is non-zero");

                            let pkey = key.public_key();
                            let comment = pkey.comment();

                            pkey.key_data().encode(&mut writer).expect("Buffer overrun");
                            let b64 = writer.finish().expect("Buffer overrun");

                            AuthorizedKey {
                                options: key.config_opts().clone(),
                                algorithm: pkey.algorithm(),
                                base64: b64.to_owned(),
                                comment: if comment.is_empty() {
                                    None
                                } else {
                                    Some(comment.to_owned())
                                },
                            }
                        })
                })
                .collect(),
        ))
    }

    pub async fn set_authorized_keys(
        &self,
        host_name: String,
        user_on_host: String,
        authorized_keys: String,
    ) -> Result<(), SshClientError> {
        let host = self.get_host_from_name(host_name).await?;
        let handle = self.clone().connect(host).await?;
        self.execute_bash(
            &handle,
            BashCommand::SetAuthorizedKeyfile(user_on_host, authorized_keys),
        )
        .await??;
        Ok(())
    }

    pub async fn get_users_on_host(&self, host: Host) -> Result<Vec<String>, SshClientError> {
        let handle = self.clone().connect(host).await?;

        self.get_ssh_users(&handle).await
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
                "cat - > .ssh/ssm.sh; chmod +x .ssh/ssm.sh",
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
        // TODO: checksums
        if exit_code != 0 || !result.contains("Secure SSH Manager") {
            warn!("Script on host seems to be invalid. Trying to install");
            match self.install_script(handle).await {
                Ok(()) => {
                    debug!("Succesfully installed script");
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
                let output = String::from_utf8(out_buf).map_err(|_e| {
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

    /// Get the difference between the supposed and actual state of the authorized keys
    pub async fn get_host_diff(&self, host: Host) -> HostDiff {
        let host_authorized_entries = self.to_owned().get_authorized_keys(host.clone()).await?;

        // This blocks
        let mut connection = self.conn.get().unwrap();

        let db_authorized_entries = host.get_authorized_keys(&mut connection)?;

        let all_user_keys = PublicUserKey::get_all_keys_with_username(&mut connection)?;
        let own_key_base64 = PublicKeyBase64::public_key_base64(self.key.as_ref());

        let mut diff_items = Vec::new();
        let mut used_indecies = Vec::new();

        for (user_on_host, has_pragma, host_entries) in host_authorized_entries {
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
                    if host_entry.base64.eq(&db_entry.key.key_base64)
                        && user_on_host.eq(&db_entry.user_on_host)
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
                if !used_indecies.contains(&i) && unused_entry.user_on_host.eq(&user_on_host) {
                    this_user_diff.push(DiffItem::KeyMissing(
                        unused_entry.clone().into(),
                        unused_entry.username.clone(),
                    ));
                }
            }
            diff_items.push((user_on_host, this_user_diff));
        }
        diff_items.retain(|(_, user_diff)| !user_diff.is_empty());
        Ok(diff_items)
    }
}

type Username = String;
pub type HostDiff = Result<Vec<(Username, Vec<DiffItem>)>, SshClientError>;

#[derive(Clone)]
pub enum DiffItem {
    /// A key that is authorized is missing with the Username
    KeyMissing(AuthorizedKey, String),
    /// A key that is not authorized is present.
    UnknownKey(AuthorizedKey),
    /// An unauthorized key belonging to a known user is present.
    UnauthorizedKey(AuthorizedKey, String),
    /// There is a duplicate key
    DuplicateKey(AuthorizedKey),
    /// There was an error Parsing this entry,
    FaultyKey(ErrorMsg, Line),
    /// The Pragma is missing, meaning this file is not yet managed
    PragmaMissing,
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
    #[allow(dead_code)]
    Update(String),

    /// Check the script version
    Version,
}

impl std::fmt::Display for BashCommand {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, ".ssh/ssm.sh ")?;
        match self {
            Self::GetAuthorizedKeyfile(user) => write!(f, "get_authorized_keyfile {user}"),
            Self::SetAuthorizedKeyfile(user, _new_keyfile) => {
                write!(f, "set_authorized_keyfile {user}")
            }
            Self::GetSshUsers => write!(f, "get_ssh_users"),
            Self::Update(_script) => write!(f, "update_script"),
            Self::Version => write!(f, "version"),
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

impl TryFrom<&ssh_key::PublicKey> for SshPublicKey {
    type Error = String;

    fn try_from(value: &ssh_key::PublicKey) -> Result<Self, Self::Error> {
        let Ok(key) = value.to_openssh() else {
            return Err(String::from("Couldn't convert to openssh"));
        };
        Self::try_from(key.as_str()).map_err(|e| e.to_string())
    }
}
