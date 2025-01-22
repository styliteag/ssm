use ssh_key::{authorized_keys::ConfigOpts, Algorithm};
use std::collections::HashMap;
use time::OffsetDateTime;

mod caching_client;
mod sshclient;

pub use caching_client::CachingSshClient;
pub use sshclient::{SshClient, SshClientError};

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
    pub hostname: String,
    pub port: u32,
}

impl ConnectionDetails {
    pub const fn new(hostname: String, port: u32) -> Self {
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

#[derive(Debug, Clone)]
pub enum KeyDiffItem {
    Added(String),
    Removed(String),
}

type Login = String;
pub type HostDiff = (
    OffsetDateTime,
    Result<Vec<(Login, Vec<DiffItem>)>, SshClientError>,
);

#[derive(Clone, Debug)]
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
type HostName = String;
type AuthorizedKeys = Result<Vec<(Login, bool, Vec<AuthorizedKeyEntry>)>, SshClientError>;
type CacheValue = (OffsetDateTime, AuthorizedKeys);
type Cache = HashMap<HostName, CacheValue>;
