use actix_web::error::BlockingError;
use async_trait::async_trait;
use core::fmt;
use futures::future::BoxFuture;
use futures::AsyncWriteExt;
use futures::FutureExt;
use log::debug;
use log::error;
use log::warn;
use russh::keys::key::PrivateKeyWithHashAlg;
use russh::keys::PublicKeyBase64;
use ssh_key::PublicKey;
use std::io::Cursor;
use std::ops::Deref;
use std::sync::mpsc;
use std::sync::Arc;
use tokio::io::AsyncRead;

use crate::ssh::SshKeyfiles;
use crate::SshConfig;
use crate::{models::Host, ConnectionPool};

use super::ConnectionDetails;
use super::KeyDiffItem;
use super::PlainSshKeyfileResponse;
const SCRIPT_SRC: &[u8] = include_bytes!("./script.sh");

#[derive(Debug, Clone)]
pub struct SshClient {
    conn: ConnectionPool,
    key: Arc<PrivateKeyWithHashAlg>,
    config: Arc<SshConfig>,
    connection_config: Arc<russh::client::Config>,
}

#[derive(Debug, Clone)]
pub enum SshClientError {
    ExecutionError(String),
    NoSuchHost,
    PortCastFailed,
    NoHostkey,
    Timeout,

    // Because russh::Error doesn't impl Clone we copy all Errors we care about
    // from russh, the rest gets converted to Strings
    UnknownKey,
    NotAuthenticated,

    SshError(String),
}

impl fmt::Display for SshClientError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NoSuchHost => write!(f, "The host doesn't exist in the database."),
            Self::PortCastFailed => write!(f, "Couldn't convert an i32 to u32."),
            Self::NoHostkey => write!(f, "No hostkey available for this host."),
            Self::Timeout => write!(f, "Connection to this host timed out."),
            Self::UnknownKey => write!(f, "Host responded with an unknown hostkey."),
            Self::NotAuthenticated => write!(f, "Couldn't authenticate on the host."),
            Self::ExecutionError(t) | Self::SshError(t) => {
                write!(f, "{t}")
            }
        }
    }
}

impl From<russh::Error> for SshClientError {
    fn from(value: russh::Error) -> Self {
        match value {
            russh::Error::UnknownKey => Self::UnknownKey,
            russh::Error::NotAuthenticated => Self::NotAuthenticated,
            _ => Self::SshError(value.to_string()),
        }
    }
}

impl From<BlockingError> for SshClientError {
    fn from(_value: BlockingError) -> Self {
        Self::ExecutionError("Blocking thread pool is shut down unexpectedly".to_owned())
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
        let fingerprint = server_public_key.fingerprint(ssh_key::HashAlg::default());

        Ok(fingerprint.to_string().eq(&self.hostkey_fingerprint))
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
                tx.send(
                    server_public_key
                        .fingerprint(ssh_key::HashAlg::default())
                        .to_string(),
                )
                .map_err(|_| {
                    SshClientError::ExecutionError(String::from("Failed to send data over mpsc"))
                })?;
                false
            }
            FirstConnectionState::Hostkey(known_fingerprint) => server_public_key
                .fingerprint(ssh_key::HashAlg::default())
                .to_string()
                .eq(known_fingerprint),
        })
    }
}

// #[derive(Deserialize)]
// struct ScriptVersion {
//     version: String,
//     sha256: String,
// }

impl SshClient {
    pub fn new(conn: ConnectionPool, key: PrivateKeyWithHashAlg, config: SshConfig) -> Self {
        Self {
            conn,
            key: key.into(),
            config: config.into(),
            connection_config: russh::client::Config::default().into(),
        }
    }

    fn get_key(&self) -> PrivateKeyWithHashAlg {
        Arc::clone(&self.key).deref().to_owned()
    }
    pub fn get_own_key_openssh(&self) -> String {
        let b64 = self.key.public_key_base64();
        let algo = self.key.algorithm();
        format!("{algo} {b64} ssm")
    }
    pub fn get_own_key_b64(&self) -> String {
        self.key.public_key_base64()
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
            Ok(_) | Err(SshClientError::UnknownKey) => Ok(rx),
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
            Ok(_) | Err(SshClientError::UnknownKey) => Ok(rx),
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
            russh::client::connect(self.connection_config.clone(), address.into_addr(), handler)
                .await?;

        if handle.authenticate_publickey(user, self.get_key()).await? {
            Ok(())
        } else {
            Err(SshClientError::NotAuthenticated)
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
            russh::client::connect_stream(self.connection_config.clone(), stream, handler).await?;

        if handle.authenticate_publickey(user, self.get_key()).await? {
            Ok(())
        } else {
            Err(SshClientError::NotAuthenticated)
        }
    }

    fn connect(
        self,
        host: Host,
    ) -> BoxFuture<'static, Result<russh::client::Handle<SshHandler>, SshClientError>> {
        let Some(ref key_fingerprint) = host.key_fingerprint else {
            return Box::pin(async { Err(SshClientError::NoHostkey) });
        };
        let handler = SshHandler {
            hostkey_fingerprint: key_fingerprint.clone(),
        };

        async move {
            let mut handle = match host.jump_via {
                Some(via) => {
                    let jump_host = Host::get_from_id(self.conn.get().unwrap(), via)
                        .await?
                        .ok_or(SshClientError::NoSuchHost)?;
                    let stream = self.connect_via(jump_host, host.to_connection()?).await?;

                    russh::client::connect_stream(self.connection_config.clone(), stream, handler)
                        .await
                }
                None => tokio::time::timeout(
                    self.config.timeout,
                    russh::client::connect(
                        self.connection_config.clone(),
                        host.to_connection()?.into_addr(),
                        handler,
                    ),
                )
                .await
                .map_err(|_| SshClientError::Timeout)?,
            }?;

            if !handle
                .authenticate_publickey(host.username.clone(), self.get_key())
                .await?
            {
                return Err(SshClientError::NotAuthenticated);
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

        tokio::time::timeout(
            self.config.timeout,
            jump_handle.channel_open_direct_tcpip(to.hostname, to.port, "127.0.0.1", 0),
        )
        .await
        .map_err(|_| SshClientError::Timeout)?
        .map(|e| e.into_stream())
        .map_err(SshClientError::from)
    }

    pub async fn set_authorized_keys(
        &self,
        host_name: String,
        login: String,
        authorized_keys: String,
    ) -> Result<(), SshClientError> {
        let host = Host::get_from_name(self.conn.get().unwrap(), host_name)
            .await?
            .ok_or(SshClientError::NoSuchHost)?;
        let handle = self.clone().connect(host.clone()).await?;
        self.execute_bash(
            &handle,
            BashCommand::SetAuthorizedKeyfile(login, authorized_keys),
        )
        .await??;

        Ok(())
    }

    pub async fn install_script_on_host(&self, host: i32) -> Result<(), SshClientError> {
        let host = Host::get_from_id(self.conn.get().unwrap(), host)
            .await?
            .ok_or(SshClientError::NoSuchHost)?;
        let handle = self.clone().connect(host).await?;

        self.install_script(&handle).await
    }

    async fn install_script(
        &self,
        handle: &russh::client::Handle<SshHandler>,
    ) -> Result<(), SshClientError> {
        let push_new = self
            .execute_with_data(
                handle,
                SCRIPT_SRC,
                "cat - > .ssh/ssm.sh.new; chmod u-w,u+rx,go-rwx .ssh/ssm.sh.new",
            )
            .await?;

        if push_new.0 != 0 {
            error!(
                "Failed to push new script on to host: Errno {}: {}",
                push_new.0, push_new.1
            );
            return Err(SshClientError::ExecutionError(
                "Failed to install/update script.".to_owned(),
            ));
        }

        let is_correct_version = self.check_version(handle, ".ssh/ssm.sh.new").await?;

        if !is_correct_version {
            return Err(SshClientError::ExecutionError(
                "Couldn't install correct script version".to_owned(),
            ));
        }

        let (move_exit_code, move_out) = self
            .execute(handle, "mv .ssh/ssm.sh.new .ssh/ssm.sh")
            .await?;
        if move_exit_code != 0 {
            warn!("Failed to move script into position ({move_exit_code}): {move_out}");
            return Err(SshClientError::ExecutionError(
                "Couldnt install script to original location".to_owned(),
            ));
        }

        Ok(())
    }

    pub async fn get_authorized_keys(&self, host: Host) -> Result<SshKeyfiles, SshClientError> {
        let handle = self.clone().connect(host).await?;
        let keyfiles_response = self
            .execute_bash(&handle, BashCommand::GetSshKeyfiles)
            .await?
            .map_err(|e| SshClientError::ExecutionError(e))?;

        let parsed = serde_json::from_str::<SshKeyfiles>(&keyfiles_response)
            .map_err(|e| SshClientError::ExecutionError(e.to_string()))?;

        Ok(parsed)
    }

    async fn check_version(
        &self,
        handle: &russh::client::Handle<SshHandler>,
        script_path: &str,
    ) -> Result<bool, SshClientError> {
        debug!("Checking script version at '{script_path}'");
        let (exit_code, cmd_out) = self
            .execute(handle, format!("cat {script_path}").as_ref())
            .await?;

        if exit_code != 0 {
            warn!("Failed to check script version ({exit_code}): {cmd_out}");
            return Ok(false);
        }

        // let version = match serde_json::from_str::<ScriptVersion>(&cmd_out) {
        //     Ok(version) => version,
        //     Err(e) => {
        //         warn!("Failed to deserialize version response: {e}");
        //         return Ok(false);
        //     }
        // };

        use sha2::{Digest, Sha256};
        // TODO: i would like to precompute this, but sha2 doesn't seem to work in const context
        let own_script_hash = Sha256::digest(SCRIPT_SRC);

        let is_script_hash = Sha256::digest(cmd_out);
        let script_is_correct = own_script_hash.eq(&is_script_hash);
        if !script_is_correct {
            debug!("Invalid script found.");
            return Ok(false);
        }
        Ok(true)
    }

    async fn execute_bash(
        &self,
        handle: &russh::client::Handle<SshHandler>,
        command: BashCommand,
    ) -> Result<BashResult, SshClientError> {
        let is_correct_version = self.check_version(handle, ".ssh/ssm.sh").await?;

        if !is_correct_version {
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

        use BashCommand as BC;
        let stdin: Option<String> = match command {
            BC::SetAuthorizedKeyfile(_, new_keyfile) => Some(new_keyfile),
            BC::GetSshKeyfiles | BC::_Update(_) | BC::_Version => None,
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
            _ => {
                warn!("Failed to execute bash command ({exit_code}): {result}");
                BashResult::Err(result)
            }
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

    pub async fn key_diff(
        &self,
        new_keyfile: &str,
        host_name: String,
        login: String,
    ) -> Result<Vec<KeyDiffItem>, SshClientError> {
        let Some(host) = Host::get_from_name(self.conn.get().unwrap(), host_name).await? else {
            return Err(SshClientError::NoSuchHost);
        };

        let handle = self.clone().connect(host).await?;

        let keyfiles_response = self
            .execute_bash(&handle, BashCommand::GetSshKeyfiles)
            .await?
            .map_err(SshClientError::ExecutionError)?;

        let keyfile = serde_json::from_str::<Vec<PlainSshKeyfileResponse>>(&keyfiles_response)
            .map_err(|e| SshClientError::ExecutionError(e.to_string()))?
            .into_iter()
            .find(|keyfile| keyfile.login.eq(&login))
            .ok_or_else(|| SshClientError::ExecutionError("Login not found".to_owned()))?;

        let new_keys = new_keyfile.to_owned();
        let diff = similar::TextDiff::from_lines(&keyfile.keyfile, &new_keys);

        Ok(diff
            .iter_all_changes()
            .filter_map(|e| match e.tag() {
                similar::ChangeTag::Delete => Some(KeyDiffItem::Removed(e.value().to_owned())),
                similar::ChangeTag::Insert => Some(KeyDiffItem::Added(e.value().to_owned())),
                similar::ChangeTag::Equal => None,
            })
            .collect())
    }
}

type User = String;
pub enum BashCommand {
    /// Get all data
    GetSshKeyfiles,

    /// Set authorized keys for a user
    SetAuthorizedKeyfile(User, String),

    // NOTE: these are currently unused since we can do this from the rust side.
    // In the future we may want to use 2fa when executing script commands, then
    // this will be needed.
    /// Update the bash script on the server
    _Update(String),
    /// Check the script version
    _Version,
}

impl std::fmt::Display for BashCommand {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, ".ssh/ssm.sh ")?;
        match self {
            Self::SetAuthorizedKeyfile(user, _new_keyfile) => {
                write!(f, "set_authorized_keyfile {user}")
            }
            Self::GetSshKeyfiles => write!(f, "get_ssh_keyfiles"),
            Self::_Update(_script) => write!(f, "update_script"),
            Self::_Version => write!(f, "version"),
        }
    }
}

impl From<BashExecError> for SshClientError {
    fn from(value: BashExecError) -> Self {
        Self::ExecutionError(value)
    }
}

type BashExecError = String;
type BashExecResponse = String;
pub type BashResult = Result<BashExecResponse, BashExecError>;
