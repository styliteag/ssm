use log::debug;
use russh::keys::ssh_encoding::{Base64Writer, Encode};
use russh::keys::{ssh_key::authorized_keys::ConfigOpts, Algorithm};
use serde::Deserialize;
use std::{collections::HashMap, net::SocketAddr, str::FromStr};
use time::OffsetDateTime;
use tokio::net::lookup_host;

mod caching_client;
mod init;
mod sshclient;

pub use caching_client::CachingSshClient;
pub use init::SshFirstConnectionHandler;
pub use sshclient::{SshClient, SshClientError};

#[derive(Debug, Clone, serde::Deserialize, serde::Serialize)]
pub struct SshPublicKey {
    pub key_type: String,
    pub key_base64: String,
    pub comment: Option<String>,
}

#[derive(Debug, Clone)]
pub struct AuthorizedKey {
    pub options: ConfigOpts,
    #[allow(dead_code)]
    pub algorithm: Algorithm,
    pub base64: String,
    #[allow(dead_code)]
    pub comment: Option<String>,
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

#[derive(Debug, Clone)]
pub struct ConnectionDetails {
    pub host_name: String,
    pub address: SocketAddr,
    pub login: String,
    //TODO: this should be a plain name
    pub jump_via: Option<i32>,
    pub key_fingerprint: String,
}

impl ConnectionDetails {
    pub async fn new(
        host_name: String,
        address: String,
        port: u16,
        login: String,
        jump_via: Option<i32>,
        key_fingerprint: String,
    ) -> Result<Self, SshClientError> {
        let lookup = format!("{address}:{port}");
        debug!("{host_name}: Trying to resolve address {lookup}");
        match lookup_host(lookup.clone()).await {
            Ok(mut socket) => {
                let resolved_addr = socket.next().ok_or(SshClientError::LookupFailure)?;
                debug!("{host_name}: Resolved {lookup} to {resolved_addr}");

                Ok(Self {
                    host_name,
                    address: resolved_addr,
                    login,
                    jump_via,
                    key_fingerprint,
                })
            }
            Err(e) => {
                debug!("{host_name}: Lookup failed: {}", e.to_string());
                Err(SshClientError::LookupFailure)
            }
        }
    }

    pub fn log_connection(&self) {
        let &Self {
            ref host_name,
            ref address,
            ref login,
            ref jump_via,
            key_fingerprint: _,
        } = self;
        match jump_via {
            Some(jumphost) => {
                debug!("{host_name}: Connection attempt to {address} via {jumphost} as {login}");
            }
            None => debug!("{host_name}: Connection attempt to {address} as {login}"),
        }
    }

    pub fn log_channel_open(&self, target: &SocketAddr) {
        let &Self {
            ref host_name,
            address: _,
            login: _,
            jump_via: _,
            key_fingerprint: _,
        } = self;

        debug!("{host_name}: Trying to open jump channel to {target}")
    }
}

#[derive(Debug, Clone)]
pub enum KeyDiffItem {
    #[allow(dead_code)]
    Added(String),
    #[allow(dead_code)]
    Removed(String),
}

type Expected = ConfigOpts;

type Login = String;
type ReadonlyCondition = Option<String>;
pub type HostDiff = (
    OffsetDateTime,
    Result<Vec<(Login, ReadonlyCondition, Vec<DiffItem>)>, SshClientError>,
);

#[derive(Clone, Debug)]
#[allow(dead_code)]
pub enum DiffItem {
    /// A key that is authorized is missing with the Username
    KeyMissing(AuthorizedKey, String),
    /// A key that is not authorized is present.
    UnknownKey(AuthorizedKey),
    /// An unauthorized key belonging to a known user is present.
    UnauthorizedKey(AuthorizedKey, String),
    /// There is a duplicate key
    DuplicateKey(AuthorizedKey),
    /// There are incorrect options set
    IncorrectOptions(AuthorizedKey, Expected),
    /// There was an error Parsing this entry,
    FaultyKey(ErrorMsg, Line),
    /// The Pragma is missing, meaning this file is not yet managed
    PragmaMissing,
}

pub type SshKeyfiles = Vec<SshKeyfileResponse>;

#[derive(Debug, Clone)]
pub struct SshKeyfileResponse {
    login: String,
    has_pragma: bool,
    readonly_condition: ReadonlyCondition,
    keyfile: Vec<AuthorizedKeyEntry>,
}

/// Parser error
type ErrorMsg = String;
/// The entire line containing the Error
type Line = String;

#[derive(Debug, Clone)]
pub enum AuthorizedKeyEntry {
    Authorization(AuthorizedKey),
    Error(ErrorMsg, Line),
}

#[derive(Deserialize, Debug)]
struct PlainSshKeyfileResponse {
    login: String,
    has_pragma: bool,
    readonly_condition: String,
    keyfile: String,
}

impl<'de> Deserialize<'de> for SshKeyfileResponse {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let plain = PlainSshKeyfileResponse::deserialize(deserializer)?;

        let entries: Vec<AuthorizedKeyEntry> = plain
            .keyfile
            .lines()
            .filter(|line| !(line.is_empty() || line.trim_start().starts_with('#')))
            .map(AuthorizedKeyEntry::from)
            .collect();

        Ok(Self {
            login: plain.login,
            has_pragma: plain.has_pragma,
            readonly_condition: if plain.readonly_condition.is_empty() {
                None
            } else {
                Some(plain.readonly_condition)
            },
            keyfile: entries,
        })
    }
}

impl From<&str> for AuthorizedKeyEntry {
    fn from(value: &str) -> Self {
        match russh::keys::ssh_key::authorized_keys::Entry::from_str(value) {
            Ok(entry) => {
                //TODO: algorithm to estimate size
                let mut buf = vec![0u8; 1024];
                let mut writer = Base64Writer::new(&mut buf).expect("buf is non-zero");

                let pkey = entry.public_key();
                let comment = pkey.comment();

                pkey.key_data().encode(&mut writer).expect("Buffer overrun");
                let b64 = writer.finish().expect("Buffer overrun");

                Self::Authorization(AuthorizedKey {
                    options: entry.config_opts().clone(),
                    algorithm: pkey.algorithm(),
                    base64: b64.to_owned(),
                    comment: if comment.is_empty() {
                        None
                    } else {
                        Some(comment.to_owned())
                    },
                })
            }
            Err(e) => Self::Error(e.to_string(), value.to_owned()),
        }
    }
}

type HostName = String;
type CacheValue = (OffsetDateTime, Result<SshKeyfiles, SshClientError>);
type Cache = HashMap<HostName, CacheValue>;
