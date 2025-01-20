use core::fmt;
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
