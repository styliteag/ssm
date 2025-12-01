use std::{mem, sync::Arc};

use log::{error, warn};
use russh::keys::PublicKey;
use tokio::sync::oneshot;

use crate::{models::Host, ConnectionPool};

use super::{ConnectionDetails, SshClientError};

#[derive(Debug)]
enum FirstConnectionState {
    None,
    KeySender(oneshot::Sender<String>),
    Hostkey(String),
}

impl Clone for FirstConnectionState {
    fn clone(&self) -> Self {
        match self {
            FirstConnectionState::None => FirstConnectionState::None,
            FirstConnectionState::KeySender(_) => {
                panic!("Tried to clone a KeySender. This should never happen");
            }
            FirstConnectionState::Hostkey(key) => FirstConnectionState::Hostkey(key.to_owned()),
        }
    }
}

#[derive(Clone, Debug)]
pub struct SshFirstConnectionHandler {
    conn: Arc<ConnectionPool>,
    data: ConnectionDetails,
    state: FirstConnectionState,
}

impl russh::client::Handler for SshFirstConnectionHandler {
    type Error = SshClientError;

    async fn check_server_key(
        &mut self,
        server_public_key: &PublicKey,
    ) -> Result<bool, Self::Error> {
        Ok(match &self.state {
            FirstConnectionState::KeySender(_) => {
                let key_fingerprint = server_public_key
                    .fingerprint(russh::keys::HashAlg::default())
                    .to_string();
                let new_state = FirstConnectionState::Hostkey(key_fingerprint.to_owned());

                let old_state = mem::replace(&mut self.state, new_state);
                match old_state {
                    FirstConnectionState::Hostkey(_) | FirstConnectionState::None => {
                        panic!("This should never happen");
                    }
                    FirstConnectionState::KeySender(sender) => {
                        sender
                            .send(
                                server_public_key
                                    .fingerprint(russh::keys::HashAlg::default())
                                    .to_string(),
                            )
                            .map_err(|e| {
                                let error = format!("IPC error sending hostkey: {e}",);
                                error!("{error}");
                                SshClientError::ExecutionError(error)
                            })?;
                    }
                }
                false
            }
            FirstConnectionState::Hostkey(known_key) => server_public_key
                .fingerprint(russh::keys::HashAlg::default())
                .to_string()
                .eq(known_key),
            FirstConnectionState::None => {
                warn!(
                    "Tried connecting before key sender was initialized. This should never happen"
                );
                false
            }
        })
    }
}

impl SshFirstConnectionHandler {
    pub async fn new(
        conn: Arc<ConnectionPool>,
        host_name: String,
        login: String,
        address: String,
        port: u16,
        jump_via: Option<i32>,
    ) -> Result<Self, SshClientError> {
        let data = ConnectionDetails::new(
            host_name,
            address,
            port,
            login,
            jump_via,
            "First connection, no hostkey".to_owned(),
        )
        .await?;

        Ok(Self {
            conn,
            data,
            state: FirstConnectionState::None,
        })
    }
    pub fn set_hostkey(mut self, hostkey: String) -> Self {
        self.state = FirstConnectionState::Hostkey(hostkey);
        self
    }

    /// Tries to connect to a host and returns hostkeys to validate
    pub async fn get_hostkey(
        mut self,
        ssh_client: Arc<super::SshClient>,
    ) -> Result<oneshot::Receiver<String>, SshClientError> {
        let (tx, rx) = oneshot::channel();
        self.state = FirstConnectionState::KeySender(tx);

        let connection_result = match self.data.jump_via {
            Some(via) => {
                let conn = self.conn.get().map_err(|e| {
                    error!("Failed to get database connection: {}", e);
                    SshClientError::ExecutionError(format!("Database connection error: {}", e))
                })?;
                let jump_host = Host::get_from_id(conn, via)
                    .await?
                    .ok_or(SshClientError::NoSuchHost)?;
                let stream = ssh_client
                    .connect_via(jump_host.to_connection().await?, self.data.address)
                    .await?;

                russh::client::connect_stream(ssh_client.connection_config.clone(), stream, self)
                    .await
            }
            None => tokio::time::timeout(
                ssh_client.config.timeout,
                russh::client::connect(
                    ssh_client.connection_config.clone(),
                    self.data.address,
                    self,
                ),
            )
            .await
            .map_err(|_| SshClientError::Timeout)?,
        };

        match connection_result {
            Ok(_) | Err(SshClientError::UnknownKey) => Ok(rx),
            Err(e) => Err(e),
        }
    }

    pub async fn try_authenticate(
        mut self,
        ssh_client: &super::SshClient,
    ) -> Result<(), SshClientError> {
        let login = self.data.login.to_owned();

        match &self.state {
            FirstConnectionState::None | FirstConnectionState::KeySender(_) => {
                error!("Tried to authenticate without hostkey");
                return Err(SshClientError::NoHostkey);
            }
            FirstConnectionState::Hostkey(hostkey) => {
                // self.data.key_fingerprint = hostkey.to_owned();
                let old_data = self.data;
                self.data = ConnectionDetails {
                    key_fingerprint: hostkey.to_owned(),
                    ..old_data
                }
            }
        };

        let handle = super::SshClient::connect(ssh_client.to_owned(), self.data).await?;
        let (exit_code, out) = super::SshClient::execute(ssh_client, &handle, "whoami").await?;

        match exit_code {
            0 if !login.eq(&out.trim()) => {
                warn!("Logged in as another user?");

                Err(SshClientError::CommandFailed(
                    out,
                    format!("the login used to connect ({})", login),
                ))
            }
            0 => Ok(()),
            _ => {
                warn!("Failed to execute: {out}");
                Err(SshClientError::ExecutionError(out))
            }
        }
    }
}
