use serde::Deserialize;
use ssh_encoding::{Base64Writer, Encode};
use ssh_key::{authorized_keys::ConfigOpts, Algorithm};
use std::{collections::HashMap, str::FromStr};
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

pub type SshKeyfiles = Vec<SshKeyfileResponse>;

#[derive(Debug, Clone)]
pub struct SshKeyfileResponse {
    login: String,
    has_pragma: bool,
    read_only: bool,
    keyfile: Vec<AuthorizedKeyEntry>,
}

/// Parser error
type ErrorMsg = String;
/// The entire line containing the Error
type Line = String;

// pub type AuthorizedKeyEntry = Result<AuthorizedKey, (ErrorMsg, Line)>;
#[derive(Debug, Clone)]
pub enum AuthorizedKeyEntry {
    Authorization(AuthorizedKey),
    Error(ErrorMsg, Line),
}

#[derive(Deserialize)]
struct PlainSshKeyfileResponse {
    login: String,
    has_pragma: bool,
    read_only: bool,
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
            .filter(|line| !line.trim_start().starts_with('#'))
            .map(AuthorizedKeyEntry::from)
            .collect();

        Ok(Self {
            login: plain.login,
            has_pragma: plain.has_pragma,
            read_only: plain.read_only,
            keyfile: entries,
        })
    }
}

impl From<&str> for AuthorizedKeyEntry {
    fn from(value: &str) -> Self {
        match ssh_key::authorized_keys::Entry::from_str(value) {
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
